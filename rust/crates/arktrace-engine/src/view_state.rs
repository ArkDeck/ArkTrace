//! Existing format-1 user sidecar, independent of IO and Ready authority.
//! Unknown/corrupt documents are preserved. Bounds reuse the annotation input
//! and record budgets; no lossy truncation or new annotation semantics.
use arktrace_viewer::{AnnotationFlag, AnnotationMark};
use serde::{Deserialize, Deserializer, Serialize, de};
use std::{fmt, marker::PhantomData};

pub const MAXIMUM_VIEW_STATE_BYTES: usize =
    arktrace_viewer::MAXIMUM_ANNOTATION_INPUT_BYTES as usize;
pub const MAXIMUM_VIEW_STATE_RECORDS: usize = arktrace_viewer::MAXIMUM_ANNOTATION_RECORDS as usize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ViewStateDocument {
    pub format_version: u32,
    #[serde(rename = "traceSHA256")]
    pub trace_sha256: String,
    #[serde(deserialize_with = "records")]
    pub flags: Vec<AnnotationFlag>,
    #[serde(deserialize_with = "records")]
    pub marks: Vec<AnnotationMark>,
    #[serde(
        default,
        rename = "favoriteTrackIDs",
        deserialize_with = "optional_records"
    )]
    pub favorite_track_ids: Option<Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "status", content = "document", rename_all = "camelCase")]
pub enum ViewStateRead {
    SessionScoped,
    Missing,
    Restored(ViewStateDocument),
    Preserved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ViewStateWrite {
    SessionScoped,
    Saved,
    Removed,
    Preserved,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ViewStateEncodeError {
    InvalidDocument,
    InputBudgetExceeded,
}
struct BoundedBytes(Vec<u8>);
impl std::io::Write for BoundedBytes {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > MAXIMUM_VIEW_STATE_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::other("view-state byte budget exceeded"));
        }
        self.0
            .try_reserve(bytes.len())
            .map_err(std::io::Error::other)?;
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn records<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Vec<T>, D::Error> {
    struct Visitor<T>(PhantomData<T>);
    impl<'de, T: Deserialize<'de>> de::Visitor<'de> for Visitor<T> {
        type Value = Vec<T>;
        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("bounded view-state records")
        }
        fn visit_seq<A: de::SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
            let mut result = Vec::new();
            while let Some(value) = seq.next_element()? {
                if result.len() == MAXIMUM_VIEW_STATE_RECORDS {
                    return Err(de::Error::custom("view-state record budget exceeded"));
                }
                result
                    .try_reserve(1)
                    .map_err(|_| de::Error::custom("view-state capacity exceeded"))?;
                result.push(value);
            }
            Ok(result)
        }
    }
    deserializer.deserialize_seq(Visitor(PhantomData))
}
fn optional_records<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Option<Vec<T>>, D::Error> {
    struct Visitor<T>(PhantomData<T>);
    impl<'de, T: Deserialize<'de>> de::Visitor<'de> for Visitor<T> {
        type Value = Option<Vec<T>>;
        fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("null or bounded view-state records")
        }
        fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
            Ok(None)
        }
        fn visit_some<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
            records(d).map(Some)
        }
    }
    deserializer.deserialize_option(Visitor(PhantomData))
}

impl ViewStateDocument {
    /// Borrow the existing arrays and filter transient marks while encoding.
    /// The IO owner supplies the bounded, cancellable writer; this does not
    /// clone labels/favorites or normalize their order or optional presence.
    #[cfg(target_os = "macos")]
    pub(crate) fn write_persisted<W: std::io::Write>(
        &self,
        trace_sha256: &str,
        writer: &mut W,
    ) -> Result<(), ViewStateEncodeError> {
        use serde::ser::{SerializeSeq, SerializeStruct};
        struct Marks<'a>(&'a [AnnotationMark]);
        impl Serialize for Marks<'_> {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                let mut seq = serializer.serialize_seq(None)?;
                for mark in self.0.iter().filter(|mark| mark.is_persistent) {
                    seq.serialize_element(mark)?;
                }
                seq.end()
            }
        }
        struct Persisted<'a>(&'a ViewStateDocument);
        impl Serialize for Persisted<'_> {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                let mut value = serializer.serialize_struct("ViewStateDocument", 5)?;
                value.serialize_field("formatVersion", &self.0.format_version)?;
                value.serialize_field("traceSHA256", &self.0.trace_sha256)?;
                value.serialize_field("flags", &self.0.flags)?;
                value.serialize_field("marks", &Marks(&self.0.marks))?;
                value.serialize_field("favoriteTrackIDs", &self.0.favorite_track_ids)?;
                value.end()
            }
        }
        if !self.valid(trace_sha256) {
            return Err(ViewStateEncodeError::InvalidDocument);
        }
        serde_json::to_writer(writer, &Persisted(self))
            .map_err(|_| ViewStateEncodeError::InputBudgetExceeded)
    }
    fn valid(&self, trace_sha256: &str) -> bool {
        self.format_version == 1
            && self.trace_sha256 == trace_sha256
            && trace_sha256.len() == 64
            && trace_sha256
                .bytes()
                .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
            && self.flags.len() <= MAXIMUM_VIEW_STATE_RECORDS
            && self.marks.len() <= MAXIMUM_VIEW_STATE_RECORDS - self.flags.len()
            && self
                .favorite_track_ids
                .as_ref()
                .is_none_or(|v| v.len() <= MAXIMUM_VIEW_STATE_RECORDS)
            && self
                .flags
                .iter()
                .map(|v| v.label.len())
                .chain(self.marks.iter().map(|v| v.label.len()))
                .chain(self.favorite_track_ids.iter().flatten().map(String::len))
                .all(|n| n <= arktrace_viewer::MAXIMUM_ANNOTATION_LABEL_BYTES as usize)
    }
    /// Serialization checks shape before allocation and stops at the exact
    /// encoded UTF-8 byte cap, including JSON escaping overhead.
    pub fn encode(&self, trace_sha256: &str) -> Result<Vec<u8>, ViewStateEncodeError> {
        if !self.valid(trace_sha256) {
            return Err(ViewStateEncodeError::InvalidDocument);
        }
        let mut output = BoundedBytes(Vec::new());
        serde_json::to_writer(&mut output, self)
            .map_err(|_| ViewStateEncodeError::InputBudgetExceeded)?;
        Ok(output.0)
    }
    pub(crate) fn persisted(&self) -> Self {
        Self {
            marks: self
                .marks
                .iter()
                .filter(|v| v.is_persistent)
                .cloned()
                .collect(),
            format_version: self.format_version,
            trace_sha256: self.trace_sha256.clone(),
            flags: self.flags.clone(),
            favorite_track_ids: self.favorite_track_ids.clone(),
        }
    }
    pub(crate) fn is_empty(&self) -> bool {
        self.flags.is_empty()
            && self.marks.is_empty()
            && self.favorite_track_ids.as_ref().is_none_or(Vec::is_empty)
    }
    /// Decode the original stream, including duplicate-field rejection. A
    /// caller must retain the original bytes when this returns Preserved.
    pub fn decode(bytes: &[u8], trace_sha256: &str) -> ViewStateRead {
        if bytes.len() > MAXIMUM_VIEW_STATE_BYTES
            || trace_sha256.len() != 64
            || !trace_sha256
                .bytes()
                .all(|v| v.is_ascii_digit() || (b'a'..=b'f').contains(&v))
        {
            return ViewStateRead::Preserved;
        }
        let Ok(value) = serde_json::from_slice::<Self>(bytes) else {
            return ViewStateRead::Preserved;
        };
        if !value.valid(trace_sha256) {
            return ViewStateRead::Preserved;
        }
        ViewStateRead::Restored(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn hash() -> String {
        "a".repeat(64)
    }
    fn input() -> serde_json::Value {
        serde_json::json!({"formatVersion":1,"traceSHA256":hash(),
            "flags":[{"id":-2,"timestampNs":i64::MAX,"label":"保存\u{0000}🦀e\u{301}","colorIndex":i64::MIN}],
            "marks":[{"id":-2,"range":{"startNs":0,"endNs":0},"label":"","colorIndex":-1,"isPersistent":false}],
            "favoriteTrackIDs":["cpu:0","cpu:0","线程 🦀"]})
    }
    fn decode(value: &serde_json::Value) -> ViewStateRead {
        ViewStateDocument::decode(&serde_json::to_vec(value).unwrap(), &hash())
    }
    #[test]
    fn actual_swift_product_sidecar_is_compatible_without_reencoding_the_fixture() {
        let bytes = include_bytes!("../tests/fixtures/swift-view-state-v1.json");
        let ViewStateRead::Restored(document) = ViewStateDocument::decode(
            bytes,
            "eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe",
        ) else {
            panic!("actual Swift product sidecar rejected");
        };
        assert_eq!(document.flags.len(), 1);
        assert_eq!(document.flags[0].label, "保存 🦀");
        assert_eq!(document.marks.len(), 1);
        assert_eq!(document.marks[0].label, "kept");
        assert!(document.marks[0].is_persistent);
        assert_eq!(document.favorite_track_ids.unwrap().len(), 1);
    }
    #[test]
    fn existing_layout_keeps_order_duplicates_signed_extrema_and_utf8() {
        let ViewStateRead::Restored(document) = decode(&input()) else {
            panic!("existing layout rejected");
        };
        assert_eq!(document.flags[0].id, -2);
        assert_eq!(document.flags[0].timestamp_ns, i64::MAX);
        assert_eq!(document.flags[0].color_index, i64::MIN);
        assert_eq!(document.flags[0].label, "保存\0🦀e\u{301}");
        assert!(document.marks[0].range.is_instant());
        assert!(!document.marks[0].is_persistent);
        assert_eq!(
            document.favorite_track_ids.unwrap(),
            ["cpu:0", "cpu:0", "线程 🦀"]
        );
    }
    #[test]
    fn favorites_before_the_field_existed_and_null_remain_compatible() {
        for value in [None, Some(serde_json::Value::Null)] {
            let mut data = input();
            data.as_object_mut().unwrap().remove("favoriteTrackIDs");
            if let Some(value) = value {
                data["favoriteTrackIDs"] = value;
            }
            let ViewStateRead::Restored(document) = decode(&data) else {
                panic!("optional favorites rejected");
            };
            assert_eq!(document.favorite_track_ids, None);
        }
    }
    #[test]
    fn duplicate_keys_unknown_fields_future_hash_mismatch_and_corruption_preserve() {
        let bytes = serde_json::to_string(&input()).unwrap();
        for data in [
            format!("{{\"formatVersion\":1,{}", &bytes[1..]),
            "{".into(),
            "null".into(),
        ] {
            assert_eq!(
                ViewStateDocument::decode(data.as_bytes(), &hash()),
                ViewStateRead::Preserved
            );
        }
        for (key, value) in [
            ("formatVersion", serde_json::json!(999)),
            ("traceSHA256", serde_json::json!("b".repeat(64))),
            ("path", serde_json::json!("foreign")),
        ] {
            let mut data = input();
            data[key] = value;
            assert_eq!(decode(&data), ViewStateRead::Preserved);
        }
        assert_eq!(
            ViewStateDocument::decode(bytes.as_bytes(), "invalid"),
            ViewStateRead::Preserved
        );
    }
    #[test]
    fn exact_integers_and_closed_ranges_are_required() {
        for (field, value) in [
            ("id", serde_json::json!(1.0)),
            ("timestampNs", serde_json::json!(u64::MAX)),
            ("colorIndex", serde_json::json!(false)),
        ] {
            let mut data = input();
            data["flags"][0][field] = value;
            assert_eq!(decode(&data), ViewStateRead::Preserved);
        }
        let mut data = input();
        data["marks"][0]["range"]["startNs"] = serde_json::json!(-1);
        assert_eq!(decode(&data), ViewStateRead::Preserved);
    }
    #[test]
    fn whole_record_and_text_budgets_never_truncate() {
        let mut data = input();
        data["marks"] = serde_json::json!([]);
        let flag = data["flags"][0].clone();
        data["flags"] = serde_json::json!(vec![flag.clone(); MAXIMUM_VIEW_STATE_RECORDS]);
        assert!(matches!(decode(&data), ViewStateRead::Restored(_)));
        data["flags"].as_array_mut().unwrap().push(flag);
        assert_eq!(decode(&data), ViewStateRead::Preserved);
        let mut data = input();
        data["flags"][0]["label"] = serde_json::json!("x".repeat(4097));
        assert_eq!(decode(&data), ViewStateRead::Preserved);
        assert_eq!(
            ViewStateDocument::decode(&vec![b' '; MAXIMUM_VIEW_STATE_BYTES + 1], &hash()),
            ViewStateRead::Preserved
        );
    }
    #[test]
    fn bounded_encoding_checks_typed_counts_and_actual_json_escape_expansion() {
        let ViewStateRead::Restored(mut document) = decode(&input()) else {
            panic!("fixture");
        };
        let encoded = document.encode(&hash()).unwrap();
        assert_eq!(
            ViewStateDocument::decode(&encoded, &hash()),
            ViewStateRead::Restored(document.clone())
        );
        assert_eq!(
            document.encode(&"b".repeat(64)).unwrap_err(),
            ViewStateEncodeError::InvalidDocument
        );
        document.favorite_track_ids = Some(vec!["x".into(); MAXIMUM_VIEW_STATE_RECORDS + 1]);
        assert_eq!(
            document.encode(&hash()).unwrap_err(),
            ViewStateEncodeError::InvalidDocument
        );
        document.favorite_track_ids = None;
        document.marks.clear();
        let flag = document.flags[0].clone();
        document.flags = vec![flag; MAXIMUM_VIEW_STATE_RECORDS];
        for f in &mut document.flags {
            f.label = "\0".repeat(4096);
        }
        assert_eq!(
            document.encode(&hash()).unwrap_err(),
            ViewStateEncodeError::InputBudgetExceeded
        );
        let mut output = BoundedBytes(vec![0; MAXIMUM_VIEW_STATE_BYTES - 1]);
        use std::io::Write;
        assert_eq!(output.write(&[1]).unwrap(), 1);
        assert!(output.write(&[2]).is_err());
        assert_eq!(output.0.len(), MAXIMUM_VIEW_STATE_BYTES);
    }
    #[test]
    fn persistence_uses_existing_transient_mark_and_empty_state_policy() {
        let ViewStateRead::Restored(document) = decode(&input()) else {
            panic!("fixture");
        };
        let mut kept = document.marks[0].clone();
        kept.is_persistent = true;
        let mut mixed = document.clone();
        mixed.marks.push(kept.clone());
        let saved = mixed.persisted();
        assert_eq!(saved.marks, [kept]);
        assert_eq!(saved.flags, document.flags);
        assert_eq!(saved.favorite_track_ids, document.favorite_track_ids);
        mixed.flags.clear();
        mixed.marks.retain(|v| !v.is_persistent);
        mixed.favorite_track_ids = Some(vec![]);
        assert!(mixed.persisted().is_empty());
        assert!(!document.persisted().is_empty());
    }
}
