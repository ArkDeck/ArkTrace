use crate::database::{DEFAULT_VM_BUDGET, Database, integer, text};
use crate::{DatabaseInspection, StoreError};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::OnceLock,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Definition {
    name: String,
    table: String,
    columns: Vec<String>,
    bootstrap: bool,
    required: bool,
    unique: bool,
    partial: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Definitions {
    version: u32,
    index_schema_version: u32,
    definitions: Vec<Definition>,
}
fn definitions() -> Result<&'static [Definition], StoreError> {
    static DEFS: OnceLock<Result<Vec<Definition>, StoreError>> = OnceLock::new();
    DEFS.get_or_init(|| {
        let data = include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../contracts/index-definitions.json"
        ));
        let corpus: Definitions =
            serde_json::from_slice(data).map_err(|_| StoreError::InvalidIndexContract)?;
        let safe = |s: &str| {
            !s.is_empty()
                && s.len() <= 128
                && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        };
        if corpus.version != 1
            || corpus.index_schema_version != arktrace_contract::INDEX_SCHEMA_VERSION
            || corpus.definitions.len() != 28
            || corpus.definitions.iter().any(|d| {
                !safe(&d.name)
                    || !safe(&d.table)
                    || d.columns.is_empty()
                    || d.columns.len() > 16
                    || d.columns.iter().any(|c| !safe(c))
                    || d.unique
                    || d.partial
            })
        {
            return Err(StoreError::InvalidIndexContract);
        }
        let names = corpus
            .definitions
            .iter()
            .map(|d| &d.name)
            .collect::<BTreeSet<_>>();
        if names.len() != corpus.definitions.len() {
            return Err(StoreError::InvalidIndexContract);
        }
        Ok(corpus.definitions)
    })
    .as_ref()
    .map(Vec::as_slice)
    .map_err(|error| *error)
}
fn applicable(db: &Database<'_>) -> Result<Vec<&'static Definition>, StoreError> {
    let defs = definitions()?;
    let mut columns = BTreeMap::new();
    for table in defs.iter().map(|d| &d.table).collect::<BTreeSet<_>>() {
        let sql = format!("PRAGMA table_xinfo(\"{table}\")");
        let names = db.query(&sql, [], 2000, DEFAULT_VM_BUDGET, |row| text(row, 1))?;
        columns.insert(table, names.into_iter().collect::<BTreeSet<_>>());
    }
    let result = defs
        .iter()
        .filter(|d| {
            columns
                .get(&d.table)
                .is_some_and(|columns| d.columns.iter().all(|c| columns.contains(c)))
        })
        .collect::<Vec<_>>();
    if defs
        .iter()
        .any(|d| d.required && !result.iter().any(|app| app.name == d.name))
    {
        return Err(StoreError::SchemaUnsupported);
    }
    Ok(result)
}
pub(crate) fn validate(db: &Database<'_>) -> Result<Vec<String>, StoreError> {
    let defs = applicable(db)?;
    for def in &defs {
        let rows = db.query(
            "SELECT name,\"unique\",partial FROM pragma_index_list(?) WHERE name=? LIMIT 2",
            [&def.table, &def.name],
            2,
            25_000,
            |row| Ok((text(row, 0)?, integer(row, 1)?, integer(row, 2)?)),
        )?;
        if rows != [(def.name.clone(), 0, 0)] {
            return Err(StoreError::InvalidReadyIndexes);
        }
        let rows=db.query("SELECT seqno,cid,name,desc,coll,key FROM pragma_index_xinfo(?) WHERE key=1 ORDER BY seqno LIMIT ?",
            rusqlite::params![&def.name,(def.columns.len()+1) as i64],def.columns.len()+1,25_000,
            |row| {
                let column = integer(row, 1)?;
                // SQLite reports expression keys with cid=-2 and name=NULL.
                // They are a valid index shape, but never a Ready definition.
                let name = if column >= 0 { text(row, 2)? } else { String::new() };
                Ok((integer(row,0)?,column,name,integer(row,3)?,text(row,4)?,integer(row,5)?))
            })?;
        if rows.len() != def.columns.len()
            || rows.iter().enumerate().any(|(index, row)| {
                row.0 != index as i64
                    || row.1 < 0
                    || row.2 != def.columns[index]
                    || row.3 != 0
                    || !row.4.eq_ignore_ascii_case("BINARY")
                    || row.5 != 1
            })
        {
            return Err(StoreError::InvalidReadyIndexes);
        }
    }
    let mut names = defs.iter().map(|def| def.name.clone()).collect::<Vec<_>>();
    names.sort_unstable();
    Ok(names)
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
pub enum IndexPhase {
    Bootstrap,
    Ready,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize)]
pub struct IndexProgress {
    pub phase: IndexPhase,
    pub completed: u32,
    pub total: u32,
}
fn rebuild(
    db: &Database<'_>,
    defs: &[&Definition],
    phase: IndexPhase,
    report: &mut impl FnMut(IndexProgress),
) -> Result<(), StoreError> {
    if defs.is_empty() {
        return Ok(());
    }
    db.execute("BEGIN IMMEDIATE", DEFAULT_VM_BUDGET)?;
    let result = (|| {
        for (index, def) in defs.iter().enumerate() {
            db.execute(&format!("DROP INDEX IF EXISTS {}", def.name), u64::MAX)?;
            db.execute(
                &format!(
                    "CREATE INDEX {} ON {}({})",
                    def.name,
                    def.table,
                    def.columns.join(",")
                ),
                u64::MAX,
            )?;
            report(IndexProgress {
                phase,
                completed: index as u32 + 1,
                total: defs.len() as u32,
            });
            db.check()?;
        }
        db.execute("COMMIT", u64::MAX)
    })();
    if result.is_err() {
        db.rollback_for_cleanup()?;
    }
    result
}
pub(crate) fn prepare(
    db: &Database<'_>,
    mut report: impl FnMut(IndexProgress),
) -> Result<(DatabaseInspection, Vec<String>), StoreError> {
    db.quick_check()?;
    let defs = applicable(db)?;
    let page_size = db.query("PRAGMA page_size", [], 1, DEFAULT_VM_BUDGET, |row| {
        integer(row, 0)
    })?[0];
    if !(512..=65536).contains(&page_size) || !((page_size as u64).is_power_of_two()) {
        return Err(StoreError::InvalidDatabase);
    }
    let max_pages = db.maximum_database_bytes() / (page_size as u64);
    if max_pages == 0 {
        return Err(StoreError::Host(
            arktrace_platform::HostError::LimitExceeded,
        ));
    }
    let pages = db.query(
        &format!("PRAGMA max_page_count={max_pages}"),
        [],
        1,
        DEFAULT_VM_BUDGET,
        |row| integer(row, 0),
    )?[0];
    if pages < 0 || pages as u64 > max_pages {
        return Err(StoreError::Host(
            arktrace_platform::HostError::LimitExceeded,
        ));
    }
    db.configure_private_indexes()?;
    let result = (|| {
        let bootstrap = defs
            .iter()
            .copied()
            .filter(|d| d.bootstrap)
            .collect::<Vec<_>>();
        rebuild(db, &bootstrap, IndexPhase::Bootstrap, &mut report)?;
        let inspection = crate::schema::validate(db)?;
        let ready = defs
            .iter()
            .copied()
            .filter(|d| !d.bootstrap)
            .collect::<Vec<_>>();
        rebuild(db, &ready, IndexPhase::Ready, &mut report)?;
        db.restore_private_indexes()?;
        db.quick_check()?;
        let names = validate(db)?;
        db.flush()?;
        Ok((inspection, names))
    })();
    if result.is_err() {
        db.rollback_for_cleanup()?;
        db.restore_for_cleanup()?;
    }
    result
}
