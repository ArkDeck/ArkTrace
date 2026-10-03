use crate::{
    CounterSampleTable, DatabaseInspection, StoreError,
    database::{DEFAULT_VM_BUDGET, Database, integer, text},
    directory::name_filter,
    events::{
        EventQuality, bounded_text, filters, intersection, interval, invalid_integer, invalid_text,
        optional_integer, optional_text, relative, unavailable,
    },
};
use arktrace_contract::{
    CounterQuery, CounterSample, CounterScope, CounterSeries, CounterSeriesDescriptor,
    CounterSeriesQuery, DataQuality, EventKey, EventPage, EventTable, ProcessKey, QualityCategory,
    QualityIssue, QualityStatus, TraceTimeRange,
};
use rusqlite::{params_from_iter, types::Value};
use std::collections::{BTreeMap, BTreeSet};

struct SampleSchema {
    duration: bool,
    row_id: Option<&'static str>,
}
pub(crate) struct CounterSchema {
    samples: BTreeMap<CounterSampleTable, SampleSchema>,
    cpu_unit: bool,
    process_unit: bool,
}
impl CounterSchema {
    pub(crate) fn has_duration(&self, table: CounterSampleTable) -> Result<bool, StoreError> {
        self.samples
            .get(&table)
            .map(|v| v.duration)
            .ok_or(StoreError::InvalidDatabase)
    }
    pub(crate) fn read(
        db: &Database<'_>,
        inspection: &DatabaseInspection,
    ) -> Result<Self, StoreError> {
        let mut samples = BTreeMap::new();
        for table in inspection
            .cpu_counter_sample_tables
            .iter()
            .chain(&inspection.process_counter_sample_tables)
            .copied()
            .collect::<BTreeSet<_>>()
        {
            let columns = columns(db, table.name())?;
            let ordinary = db.query("SELECT wr FROM pragma_table_list(?) WHERE schema='main' AND name=? AND type='table' LIMIT 2", [table.name(), table.name()], 2, 10_000, |r| integer(r, 0))? == [0];
            let row_id = ordinary
                .then(|| {
                    ["rowid", "_rowid_", "oid"]
                        .into_iter()
                        .find(|alias| !columns.iter().any(|c| c.eq_ignore_ascii_case(alias)))
                })
                .flatten();
            samples.insert(
                table,
                SampleSchema {
                    duration: columns.iter().any(|c| c == "dur"),
                    row_id,
                },
            );
        }
        Ok(Self {
            samples,
            cpu_unit: columns(db, "cpu_measure_filter")?
                .iter()
                .any(|c| c == "unit"),
            process_unit: columns(db, "process_measure_filter")?
                .iter()
                .any(|c| c == "unit"),
        })
    }
    pub(crate) fn counters(
        &self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &CounterQuery,
    ) -> Result<EventPage<CounterSeries>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        let caps = &inspection.capabilities;
        if (!caps.cpu_counters && !caps.process_counters)
            || (query.cpu.is_some() && !caps.cpu_counters)
            || ((query.process_key.is_some() || query.pid.is_some()) && !caps.process_counters)
        {
            return unavailable();
        }
        // Resolve every participating physical table before any page, including
        // tables excluded by this scope filter. Descriptors do not need rowids.
        intersection(inspection, query.range)?;
        for (table, schema) in &self.samples {
            if schema.row_id.is_none() {
                return Err(StoreError::CounterSampleIdentityUnavailable(*table));
            }
        }
        let mut rows = Vec::new();
        let mut source_truncated = false;
        for (order, tables, filter, scope, unit) in self.sources(inspection) {
            if (order == 0 && (query.process_key.is_some() || query.pid.is_some()))
                || (order == 1 && query.cpu.is_some())
            {
                continue;
            }
            for table in tables {
                let schema = self.samples.get(table).ok_or(StoreError::InvalidDatabase)?;
                let (mut values, truncated) = sample_rows(
                    db,
                    inspection,
                    *table,
                    schema,
                    Source {
                        order,
                        filter,
                        scope,
                        unit,
                    },
                    query,
                )?;
                source_truncated |= truncated;
                rows.append(&mut values);
            }
        }
        db.check()?;
        rows.sort_by_key(|r| (r.timestamp, r.table, r.row_id, r.order, r.filter_id));
        db.check()?;
        let truncated = source_truncated || rows.len() > query.limit;
        let mut groups = BTreeMap::<(i64, i64, i64), CounterSeries>::new();
        let mut seen = BTreeSet::new();
        let mut optional = BTreeMap::new();
        let mut timestamps = BTreeMap::new();
        let mut durations = BTreeMap::new();
        let mut missing = 0;
        for (index, row) in rows.into_iter().take(query.limit).enumerate() {
            if index.is_multiple_of(1024) {
                db.check()?;
            }
            if !seen.insert((row.table, row.row_id)) {
                return Err(StoreError::CounterQueryFailed);
            }
            *optional.entry(row.table).or_insert(0) += row.invalid;
            missing += row.missing;
            let mut quality = EventQuality::default();
            let (timestamp_ns, duration_ns) = match row.duration_state {
                0 | 3 => (relative(row.timestamp, inspection)?, Some(0)),
                1 | 2 => {
                    let (range, open) = interval(
                        Some(row.timestamp),
                        row.duration,
                        row.duration_state == 1,
                        inspection,
                        &mut quality,
                    )?
                    .ok_or(StoreError::CounterQueryFailed)?;
                    (
                        range.start_ns(),
                        if open {
                            None
                        } else {
                            Some(
                                range
                                    .end_ns()
                                    .checked_sub(range.start_ns())
                                    .ok_or(StoreError::CounterQueryFailed)?,
                            )
                        },
                    )
                }
                _ => return Err(StoreError::CounterQueryFailed),
            };
            *timestamps.entry(row.table).or_insert(0) += quality.clamped_timestamp;
            *durations.entry(row.table).or_insert(0) += quality.clamped_duration;
            let key = (row.order, row.scope_id, row.filter_id);
            let series = groups.entry(key).or_insert_with(|| CounterSeries {
                filter_id: row.filter_id,
                name: String::new(),
                scope: if row.order == 0 {
                    CounterScope::Cpu
                } else {
                    CounterScope::Process
                },
                cpu: (row.order == 0).then_some(row.scope_id),
                process_key: (row.order == 1 && row.scope_id != 0)
                    .then_some(ProcessKey { ipid: row.scope_id }),
                pid: None,
                process_name: None,
                unit: None,
                samples: Vec::new(),
            });
            // Swift assigns even nil metadata, so the final selected sample
            // supplies series metadata rather than a first-non-null reduction.
            series.name = row.name;
            series.unit = row.unit;
            series.pid = row.pid;
            series.process_name = row.process_name;
            series.samples.push(CounterSample {
                key: EventKey {
                    table: event_table(row.table),
                    row_id: row.row_id,
                },
                timestamp_ns,
                value: row.value,
                duration_ns,
            });
        }
        db.check()?;
        let dropped = optional.values().any(|count| *count > 0);
        let mut issues = inspection.data_quality.warnings.clone();
        for (suffix, category, counts) in [
            ("optional", QualityCategory::DroppedValue, optional),
            ("ts", QualityCategory::ClampedValue, timestamps),
            ("dur", QualityCategory::ClampedValue, durations),
        ] {
            for (table, count) in counts {
                add_issue(
                    &mut issues,
                    category,
                    format!("{}.{suffix}", table.name()),
                    count,
                );
            }
        }
        add_issue(
            &mut issues,
            QualityCategory::ReferentialIntegrity,
            "process_measure_filter.ipid".into(),
            missing,
        );
        Ok(EventPage {
            items: groups.into_values().collect(),
            truncated: truncated || dropped,
            capability_available: true,
            data_quality: quality(issues)?,
        })
    }
    pub(crate) fn series(
        &self,
        db: &Database<'_>,
        inspection: &DatabaseInspection,
        query: &CounterSeriesQuery,
    ) -> Result<EventPage<CounterSeriesDescriptor>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !inspection.capabilities.cpu_counters && !inspection.capabilities.process_counters {
            return unavailable();
        }
        intersection(inspection, query.range)?;
        let mut items = Vec::new();
        let mut truncated = false;
        let mut invalid = 0;
        let mut missing = 0;
        for (order, tables, filter, scope, unit) in self.sources(inspection) {
            if tables.is_empty() {
                continue;
            }
            let projection = Projection::new(order == 1, unit);
            let mut exists = Vec::new();
            let mut bindings = Vec::new();
            for table in tables {
                let schema = self.samples.get(table).ok_or(StoreError::InvalidDatabase)?;
                let (predicate, values) = time_filter(inspection, query.range, schema.duration)?;
                exists.push(format!("EXISTS(SELECT 1 FROM {} m WHERE m.filter_id=f.id AND typeof(m.filter_id)='integer' AND typeof(m.ts)='integer' AND typeof(m.value)='integer' AND ({predicate}))", table.name()));
                bindings.extend(values);
            }
            bindings.push(Value::Integer(query.limit as i64 + 1));
            let sql = format!(
                "SELECT f.id,f.name,f.{scope},{},{},{},{},{} FROM {filter} f {} WHERE typeof(f.id)='integer' AND typeof(f.{scope})='integer' AND typeof(f.name)='text' AND length(CAST(f.name AS BLOB))<=256 AND ({}) ORDER BY f.id ASC LIMIT ?",
                projection.unit,
                projection.pid,
                projection.process_name,
                projection.missing,
                projection.invalid,
                projection.join,
                exists.join(" OR ")
            );
            let rows = db.query(
                &sql,
                params_from_iter(bindings),
                query.limit + 1,
                DEFAULT_VM_BUDGET,
                |r| {
                    let filter_id =
                        optional_integer(r, 0)?.ok_or(StoreError::CounterQueryFailed)?;
                    let name = optional_text(r, 1)?.ok_or(StoreError::CounterQueryFailed)?;
                    let scope_id = optional_integer(r, 2)?.ok_or(StoreError::CounterQueryFailed)?;
                    Ok((
                        CounterSeriesDescriptor {
                            filter_id,
                            name,
                            scope: if order == 0 {
                                CounterScope::Cpu
                            } else {
                                CounterScope::Process
                            },
                            cpu: (order == 0).then_some(scope_id),
                            process_key: (order == 1 && scope_id != 0)
                                .then_some(ProcessKey { ipid: scope_id }),
                            unit: optional_text(r, 3)?,
                            pid: optional_integer(r, 4)?,
                            process_name: optional_text(r, 5)?,
                        },
                        integer(r, 6)?,
                        integer(r, 7)?,
                    ))
                },
            )?;
            truncated |= rows.len() > query.limit;
            for (index, (descriptor, absent, dropped)) in
                rows.into_iter().take(query.limit).enumerate()
            {
                if index.is_multiple_of(1024) {
                    db.check()?;
                }
                items.push(descriptor);
                missing += absent;
                invalid += dropped;
            }
        }
        // The directory is ordered by scope then filter ID, independently of
        // sample timestamps and the sample page's grouping by scope identity.
        items.sort_by_key(|d| {
            (
                if d.scope == CounterScope::Cpu { 0 } else { 1 },
                d.filter_id,
            )
        });
        db.check()?;
        truncated |= items.len() > query.limit;
        items.truncate(query.limit);
        let mut issues = inspection.data_quality.warnings.clone();
        add_issue(
            &mut issues,
            QualityCategory::DroppedValue,
            "timeline.counter".into(),
            invalid,
        );
        add_issue(
            &mut issues,
            QualityCategory::ReferentialIntegrity,
            "process_measure_filter.ipid".into(),
            missing,
        );
        Ok(EventPage {
            items,
            truncated,
            capability_available: true,
            data_quality: quality(issues)?,
        })
    }
    fn sources<'a>(
        &self,
        inspection: &'a DatabaseInspection,
    ) -> [(
        i64,
        &'a [CounterSampleTable],
        &'static str,
        &'static str,
        bool,
    ); 2] {
        [
            (
                0,
                &inspection.cpu_counter_sample_tables,
                "cpu_measure_filter",
                "cpu",
                self.cpu_unit,
            ),
            (
                1,
                &inspection.process_counter_sample_tables,
                "process_measure_filter",
                "ipid",
                self.process_unit,
            ),
        ]
    }
}
fn columns(db: &Database<'_>, table: &str) -> Result<Vec<String>, StoreError> {
    // table is one of four closed source identifiers, never caller SQL.
    db.query(
        &format!("PRAGMA table_xinfo({table})"),
        [],
        2000,
        DEFAULT_VM_BUDGET,
        |r| text(r, 1),
    )
}
fn event_table(table: CounterSampleTable) -> EventTable {
    match table {
        CounterSampleTable::Measure => EventTable::Measure,
        CounterSampleTable::ProcessMeasure => EventTable::ProcessMeasure,
    }
}
pub(crate) fn time_filter(
    inspection: &DatabaseInspection,
    range: TraceTimeRange,
    duration: bool,
) -> Result<(String, Vec<Value>), StoreError> {
    let (predicate, mut values) = intersection(inspection, range)?;
    let start = inspection
        .trace_start_ts
        .checked_add(range.start_ns())
        .ok_or(StoreError::InvalidQuery)?;
    let end = inspection
        .trace_start_ts
        .checked_add(range.end_ns())
        .ok_or(StoreError::InvalidQuery)?;
    if !duration {
        return Ok((
            "m.ts>=? AND m.ts<?".into(),
            vec![Value::Integer(start), Value::Integer(end)],
        ));
    }
    // Malformed optional durations remain instants, whereas NULL and negative
    // INTEGER durations use the full trace's open-ended interval predicate.
    values.extend([Value::Integer(start), Value::Integer(end)]);
    Ok((
        format!(
            "({}) OR (m.dur IS NOT NULL AND typeof(m.dur)<>'integer' AND m.ts>=? AND m.ts<?)",
            predicate[0].replace("s.", "m.")
        ),
        values,
    ))
}
struct Source {
    order: i64,
    filter: &'static str,
    scope: &'static str,
    unit: bool,
}
struct Projection {
    unit: String,
    pid: String,
    process_name: String,
    missing: &'static str,
    invalid: String,
    join: &'static str,
}
impl Projection {
    fn new(process: bool, unit: bool) -> Self {
        let mut invalid = Vec::new();
        if unit {
            invalid.push(invalid_text("f.unit", 256));
        }
        if process {
            invalid.extend([invalid_integer("p.pid"), invalid_text("p.name", 4096)]);
        }
        Self {
            unit: if unit {
                bounded_text("f.unit", 256)
            } else {
                "NULL".into()
            },
            pid: if process {
                "CASE WHEN typeof(p.pid)='integer' THEN p.pid ELSE NULL END".into()
            } else {
                "NULL".into()
            },
            process_name: if process {
                bounded_text("p.name", 4096)
            } else {
                "NULL".into()
            },
            missing: if process {
                "CASE WHEN f.ipid<>0 AND p.ipid IS NULL THEN 1 ELSE 0 END"
            } else {
                "0"
            },
            invalid: if invalid.is_empty() {
                "0".into()
            } else {
                invalid.join(" + ")
            },
            join: if process {
                "LEFT JOIN process p ON p.ipid=f.ipid"
            } else {
                ""
            },
        }
    }
}
struct SampleRow {
    table: CounterSampleTable,
    row_id: i64,
    timestamp: i64,
    value: i64,
    filter_id: i64,
    name: String,
    scope_id: i64,
    order: i64,
    duration: Option<i64>,
    duration_state: i64,
    unit: Option<String>,
    invalid: i64,
    pid: Option<i64>,
    process_name: Option<String>,
    missing: i64,
}
fn sample_rows(
    db: &Database<'_>,
    inspection: &DatabaseInspection,
    table: CounterSampleTable,
    schema: &SampleSchema,
    source: Source,
    query: &CounterQuery,
) -> Result<(Vec<SampleRow>, bool), StoreError> {
    let (time, mut values) = time_filter(inspection, query.range, schema.duration)?;
    let mut conditions = vec![
        "typeof(m.ts)='integer'".into(),
        "typeof(m.value)='integer'".into(),
        "typeof(m.filter_id)='integer'".into(),
        "typeof(f.id)='integer'".into(),
        format!("typeof(f.{})='integer'", source.scope),
        "typeof(f.name)='text'".into(),
        "length(CAST(f.name AS BLOB))<=256".into(),
        format!("({time})"),
    ];
    let scope_column = format!("f.{}", source.scope);
    filters(
        &mut conditions,
        &mut values,
        [
            ("f.id", query.filter_id),
            (
                &scope_column,
                if source.order == 0 {
                    query.cpu
                } else {
                    query.process_key
                },
            ),
            ("p.pid", if source.order == 1 { query.pid } else { None }),
        ],
    );
    name_filter(
        "f.name",
        query.name.as_deref(),
        query.name_match,
        &mut conditions,
        &mut values,
    );
    values.push(Value::Integer(query.limit as i64 + 1));
    let (duration, state) = if schema.duration {
        (
            "CASE WHEN typeof(m.dur)='integer' THEN m.dur ELSE NULL END",
            "CASE WHEN m.dur IS NULL THEN 1 WHEN typeof(m.dur)='integer' THEN 2 ELSE 3 END",
        )
    } else {
        ("0", "0")
    };
    let projection = Projection::new(source.order == 1, source.unit);
    let invalid = if schema.duration {
        format!("({}) + ({})", projection.invalid, invalid_integer("m.dur"))
    } else {
        projection.invalid
    };
    let row_id = schema
        .row_id
        .ok_or(StoreError::CounterSampleIdentityUnavailable(table))?;
    let sql = format!(
        "SELECT m.{row_id},m.ts,m.value,f.id,f.name,f.{},{duration},{state},{},{invalid},{},{},{} FROM {} m INNER JOIN {} f ON f.id=m.filter_id {} WHERE {} ORDER BY m.ts ASC,m.{row_id} ASC LIMIT ?",
        source.scope,
        projection.unit,
        projection.pid,
        projection.process_name,
        projection.missing,
        table.name(),
        source.filter,
        projection.join,
        conditions.join(" AND ")
    );
    let mut rows = db.query(
        &sql,
        params_from_iter(values),
        query.limit + 1,
        DEFAULT_VM_BUDGET,
        |r| {
            Ok(SampleRow {
                table,
                row_id: optional_integer(r, 0)?.ok_or(StoreError::CounterQueryFailed)?,
                timestamp: optional_integer(r, 1)?.ok_or(StoreError::CounterQueryFailed)?,
                value: optional_integer(r, 2)?.ok_or(StoreError::CounterQueryFailed)?,
                filter_id: optional_integer(r, 3)?.ok_or(StoreError::CounterQueryFailed)?,
                name: optional_text(r, 4)?.ok_or(StoreError::CounterQueryFailed)?,
                scope_id: optional_integer(r, 5)?.ok_or(StoreError::CounterQueryFailed)?,
                order: source.order,
                duration: optional_integer(r, 6)?,
                duration_state: integer(r, 7)?,
                unit: optional_text(r, 8)?,
                invalid: integer(r, 9)?,
                pid: optional_integer(r, 10)?,
                process_name: optional_text(r, 11)?,
                missing: integer(r, 12)?,
            })
        },
    )?;
    let truncated = rows.len() > query.limit;
    rows.truncate(query.limit);
    Ok((rows, truncated))
}
fn add_issue(issues: &mut Vec<QualityIssue>, category: QualityCategory, scope: String, count: i64) {
    if count > 0 {
        issues.push(QualityIssue {
            category,
            scope: Some(scope),
            count: Some(count),
            message: None,
        });
    }
}
fn quality(issues: Vec<QualityIssue>) -> Result<DataQuality, StoreError> {
    DataQuality::machine(
        if issues.is_empty() {
            QualityStatus::Ok
        } else {
            QualityStatus::Warnings
        },
        issues,
    )
    .map_err(|_| StoreError::InvalidQualityContract)
}

#[cfg(test)]
mod tests;
