use crate::{
    StoreError,
    database::{DEFAULT_VM_BUDGET, Database, text},
    events::{optional_integer, optional_text, unavailable},
};
use arktrace_contract::{
    DataQuality, EventPage, QualityStatus, TraceArgumentQuery, TraceEventArgument,
};
use rusqlite::params;

#[derive(Clone, Copy)]
pub(crate) struct ArgumentSchema {
    available: bool,
    id: bool,
}
impl ArgumentSchema {
    pub(crate) fn read(db: &Database<'_>) -> Result<Self, StoreError> {
        let columns = |table: &str| {
            db.query(
                &format!("PRAGMA table_xinfo({table})"),
                [],
                2000,
                DEFAULT_VM_BUDGET,
                |r| text(r, 1),
            )
        };
        let args = columns("args")?;
        let dictionary = columns("data_dict")?;
        let types = columns("data_type")?;
        let callstack = columns("callstack")?;
        Ok(Self {
            available: callstack.iter().any(|c| c == "argsetid")
                && ["key", "datatype", "value", "argset"]
                    .iter()
                    .all(|c| args.iter().any(|v| v == c))
                && ["id", "data"]
                    .iter()
                    .all(|c| dictionary.iter().any(|v| v == c))
                && ["typeId", "desc"]
                    .iter()
                    .all(|c| types.iter().any(|v| v == c)),
            id: args.iter().any(|c| c == "id"),
        })
    }
    pub(crate) fn arguments(
        self,
        db: &Database<'_>,
        query: &TraceArgumentQuery,
    ) -> Result<EventPage<TraceEventArgument>, StoreError> {
        query.validate().map_err(|_| StoreError::InvalidQuery)?;
        if !self.available {
            return unavailable();
        }
        // id is additive, not required by the supported args schema. Preserve
        // upstream ordering when present; otherwise sort the concrete values,
        // including resolved join ties. This also supports WITHOUT ROWID.
        let values =
            "a.key ASC,a.datatype ASC,a.value ASC,keyDict.data ASC,t.desc ASC,valueDict.data ASC";
        let order = if self.id {
            format!("a.id ASC,{values}")
        } else {
            values.into()
        };
        let sql = format!(
            "SELECT keyDict.data,a.datatype,t.desc,valueDict.data,a.value
            FROM args a LEFT JOIN data_dict keyDict ON keyDict.id=a.key
            LEFT JOIN data_type t ON t.typeId=a.datatype
            LEFT JOIN data_dict valueDict ON valueDict.id=a.value
            WHERE typeof(a.argset)='integer' AND a.argset=? ORDER BY {order} LIMIT ?"
        );
        let rows = db.query(
            &sql,
            params![query.arg_set_id, query.limit as i64 + 1],
            query.limit + 1,
            DEFAULT_VM_BUDGET,
            |r| {
                let Some(key) = optional_text(r, 0)?.filter(|s| !s.is_empty()) else {
                    return Ok(None);
                };
                let value = if optional_integer(r, 1)? == Some(1) {
                    optional_text(r, 3)?
                } else {
                    optional_integer(r, 4)?.map(|v| v.to_string())
                };
                let Some(value) = value else {
                    return Ok(None);
                };
                Ok(Some(TraceEventArgument {
                    key,
                    value,
                    type_name: optional_text(r, 2)?,
                }))
            },
        )?;
        // Swift maps all limit+1 rows before compaction. A valid lookahead may
        // fill a dropped row; truncation is still based on raw source count.
        let truncated = rows.len() > query.limit;
        let items = rows.into_iter().flatten().take(query.limit).collect();
        db.check()?;
        Ok(EventPage {
            items,
            truncated,
            capability_available: true,
            data_quality: DataQuality::machine(QualityStatus::Ok, Vec::new())
                .map_err(|_| StoreError::InvalidQualityContract)?,
        })
    }
}

#[cfg(test)]
mod tests;
