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
        if value.format_version != 1
            || value.trace_sha256 != trace_sha256
            || value.flags.len() + value.marks.len() > MAXIMUM_VIEW_STATE_RECORDS
            || value
                .flags
                .iter()
                .map(|v| v.label.len())
                .chain(value.marks.iter().map(|v| v.label.len()))
                .chain(value.favorite_track_ids.iter().flatten().map(String::len))
                .any(|n| n > arktrace_viewer::MAXIMUM_ANNOTATION_LABEL_BYTES as usize)
        {
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
}
