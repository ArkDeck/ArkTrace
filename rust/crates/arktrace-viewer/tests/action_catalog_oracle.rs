#[allow(dead_code)]
mod common;
use arktrace_viewer::*;
use serde_json::{Value, json};

#[test]
fn actual_swift_catalog_bilingual_help_and_markdown_are_exact() {
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/action-catalog-display-swift.json")).unwrap();
    let sections: Vec<_> = SHORTCUT_SECTIONS.iter().map(|section| {
        let entries: Vec<_> = section.entries().iter().map(|entry| json!({
            "legacyID":entry.legacy_id(),
            "keysEnglish":entry.keys_markdown(ActionCatalogLanguage::English),
            "keysChinese":entry.keys_markdown(ActionCatalogLanguage::SimplifiedChinese),
            "displayKeys":entry.display_keys(),
            "actionEnglish":entry.action_text(ActionCatalogLanguage::English),
            "actionChinese":entry.action_text(ActionCatalogLanguage::SimplifiedChinese)
        })).collect();
        json!({"legacyID":section.legacy_id(),
            "titleEnglish":section.title(ActionCatalogLanguage::English),
            "titleChinese":section.title(ActionCatalogLanguage::SimplifiedChinese),
            "entries":entries,
            "tableEnglish":shortcut_markdown_table(section.id(),ActionCatalogLanguage::English,&mut ||Ok(())).unwrap(),
            "tableChinese":shortcut_markdown_table(section.id(),ActionCatalogLanguage::SimplifiedChinese,&mut ||Ok(())).unwrap()})
    }).collect();
    common::compare(
        &json!({"schemaVersion":1,"sections":sections}),
        &expected,
        "actual Swift catalog",
    );
}

#[test]
fn actual_native_keydown_matches_every_normalized_input() {
    let inputs: Value =
        serde_json::from_str(include_str!("fixtures/action-catalog-inputs.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/action-catalog-keyboard-swift.json")).unwrap();
    let inputs = inputs["cases"].as_array().unwrap();
    assert_eq!(inputs.len(), 664);
    let actual: Vec<_> = inputs
        .iter()
        .map(|input| {
            let normalized: NormalizedShortcutInput =
                serde_json::from_value(input["normalized"].clone()).unwrap();
            let resolution =
                resolve_mac_shortcut(ACTION_CATALOG_API_VERSION, normalized, &mut || Ok(()))
                    .unwrap();
            let mut commands = Vec::new();
            let mut annotations = Vec::new();
            let forwarded = match resolution.route {
                ShortcutRoute::Forward { .. } => true,
                ShortcutRoute::Dispatch { action } => {
                    let definition = action.definition();
                    match definition.domain() {
                        ShortcutActionDomain::TimelineKeyboard => {
                            commands.push(definition.canonical_name())
                        }
                        ShortcutActionDomain::TimelineAnnotation => {
                            annotations.push(definition.canonical_name())
                        }
                        other => panic!("timeline key routed to {other:?}"),
                    }
                    false
                }
            };
            json!({"id":input["id"],"commands":commands,"annotations":annotations,
            "forwarded":forwarded,"keyboardFocusVisible":resolution.show_keyboard_focus})
        })
        .collect();
    common::compare(
        &json!(actual),
        &expected["cases"],
        "actual NSEvent + keyDown",
    );
}

#[test]
fn semantic_command_registry_covers_actual_native_command_entry_points() {
    let expected: Value =
        serde_json::from_str(include_str!("fixtures/action-catalog-keyboard-swift.json")).unwrap();
    let direct = expected["directCommands"].as_array().unwrap();
    let definitions: Vec<_> = SHORTCUT_ACTIONS
        .iter()
        .filter(|d| d.domain() == ShortcutActionDomain::TimelineKeyboard)
        .collect();
    assert_eq!(definitions.len(), direct.len());
    for (definition, native) in definitions.iter().zip(direct) {
        assert_eq!(native["name"], definition.canonical_name());
        assert_eq!(native["observed"], json!([definition.canonical_name()]));
        assert!(native["performed"].is_boolean());
    }
    // `performed` is actual native handler state evidence. The shared router
    // selects an entry point; it does not duplicate eligibility/viewport logic.
}
