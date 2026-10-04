use arktrace_viewer::*;
use std::collections::BTreeSet;
fn input(key: NormalizedMacShortcutKey) -> NormalizedShortcutInput {
    NormalizedShortcutInput {
        key,
        modifiers: ShortcutModifiers::default(),
        scope: ShortcutInputScope::Timeline,
        text_input_active: false,
    }
}
fn route(input: NormalizedShortcutInput) -> ShortcutResolution {
    resolve_mac_shortcut(1, input, &mut || Ok(())).unwrap()
}
#[test]
fn version_and_closed_id_boundaries_reject_unknown_values() {
    assert_eq!(
        resolve_mac_shortcut(2, input(NormalizedMacShortcutKey::W), &mut || Ok(())),
        Err(ActionCatalogError::UnsupportedVersion)
    );
    for code in [0, 30, u32::MAX] {
        assert_eq!(
            ShortcutActionId::from_code(code),
            Err(ActionCatalogError::UnknownAction)
        );
    }
    for definition in SHORTCUT_ACTIONS {
        assert_eq!(
            ShortcutActionId::from_code(definition.id().code()).unwrap(),
            definition.id()
        );
    }
    let mut json = serde_json::to_value(input(NormalizedMacShortcutKey::W)).unwrap();
    json["key"] = "arbitrary host string".into();
    assert!(serde_json::from_value::<NormalizedShortcutInput>(json).is_err());
}
#[test]
fn text_input_and_ime_ownership_guard_even_physical_command_arrows() {
    for key in [
        NormalizedMacShortcutKey::LeftArrow,
        NormalizedMacShortcutKey::M,
        NormalizedMacShortcutKey::Return,
    ] {
        for scope in [
            ShortcutInputScope::Timeline,
            ShortcutInputScope::SearchResults,
            ShortcutInputScope::Other,
            ShortcutInputScope::TextInput,
        ] {
            let mut event = input(key);
            event.scope = scope;
            event.modifiers.command = true;
            event.text_input_active = true;
            assert_eq!(
                route(event),
                ShortcutResolution {
                    route: ShortcutRoute::Forward {
                        reason: ShortcutForwardReason::TextInput
                    },
                    show_keyboard_focus: false
                }
            );
        }
        let mut event = input(key);
        event.scope = ShortcutInputScope::TextInput;
        assert!(!route(event).show_keyboard_focus);
        assert!(matches!(
            route(event).route,
            ShortcutRoute::Forward {
                reason: ShortcutForwardReason::TextInput
            }
        ));
    }
}
#[test]
fn search_and_outside_focus_are_left_with_native_host() {
    for key in [
        NormalizedMacShortcutKey::UpArrow,
        NormalizedMacShortcutKey::DownArrow,
        NormalizedMacShortcutKey::Return,
    ] {
        for (scope, reason) in [
            (
                ShortcutInputScope::SearchResults,
                ShortcutForwardReason::SearchResultsHost,
            ),
            (
                ShortcutInputScope::Other,
                ShortcutForwardReason::OutsideTimeline,
            ),
        ] {
            let mut event = input(key);
            event.scope = scope;
            assert_eq!(
                route(event),
                ShortcutResolution {
                    route: ShortcutRoute::Forward { reason },
                    show_keyboard_focus: false
                }
            );
        }
    }
}
#[test]
fn menu_letters_forward_but_actual_physical_arrow_priority_is_preserved() {
    let mut letter = input(NormalizedMacShortcutKey::W);
    letter.modifiers.command = true;
    assert_eq!(
        route(letter).route,
        ShortcutRoute::Forward {
            reason: ShortcutForwardReason::Menu
        }
    );
    let mut arrow = input(NormalizedMacShortcutKey::LeftArrow);
    arrow.modifiers.command = true;
    arrow.modifiers.control = true;
    assert_eq!(
        route(arrow).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::PreviousEvent
        }
    );
    arrow.modifiers.option = true;
    assert_eq!(
        route(arrow).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::PanBackward
        }
    );
}
#[test]
fn control_annotations_and_bare_selection_aliases_do_not_conflict() {
    let mut event = input(NormalizedMacShortcutKey::LeftBracket);
    assert_eq!(
        route(event).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::ZoomSelection
        }
    );
    event.modifiers.control = true;
    assert_eq!(
        route(event).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::PreviousMark
        }
    );
    event.key = NormalizedMacShortcutKey::M;
    assert_eq!(
        route(event).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::CreateTransientMark
        }
    );
    event.modifiers.shift = true;
    assert_eq!(
        route(event).route,
        ShortcutRoute::Dispatch {
            action: ShortcutActionId::CreatePersistentMark
        }
    );
    event.key = NormalizedMacShortcutKey::W;
    assert_eq!(
        route(event).route,
        ShortcutRoute::Forward {
            reason: ShortcutForwardReason::Control
        }
    );
}
#[test]
fn unknown_keys_forward_and_keyboard_focus_intent_is_separate_from_dispatch() {
    assert_eq!(
        route(input(NormalizedMacShortcutKey::Unknown)),
        ShortcutResolution {
            route: ShortcutRoute::Forward {
                reason: ShortcutForwardReason::UnknownKey
            },
            show_keyboard_focus: true
        }
    );
}
#[test]
fn cancellation_or_deadline_never_returns_a_partial_result_and_retry_is_clean() {
    for error in [
        ActionCatalogError::Cancelled,
        ActionCatalogError::DeadlineReached,
    ] {
        for stop in [0, 1] {
            let mut calls = 0;
            let result = resolve_mac_shortcut(1, input(NormalizedMacShortcutKey::W), &mut || {
                let current = calls;
                calls += 1;
                if current == stop { Err(error) } else { Ok(()) }
            });
            assert_eq!(result, Err(error));
        }
        for stop in [0, 1, 7, 13] {
            let mut calls = 0;
            let result = shortcut_markdown_table(
                ShortcutSectionId::Timeline,
                ActionCatalogLanguage::SimplifiedChinese,
                &mut || {
                    let current = calls;
                    calls += 1;
                    if current == stop { Err(error) } else { Ok(()) }
                },
            );
            assert_eq!(result, Err(error));
        }
        assert!(matches!(
            route(input(NormalizedMacShortcutKey::W)).route,
            ShortcutRoute::Dispatch {
                action: ShortcutActionId::ZoomInAtPointer
            }
        ));
        assert!(
            shortcut_markdown_table(
                ShortcutSectionId::Timeline,
                ActionCatalogLanguage::SimplifiedChinese,
                &mut || Ok(())
            )
            .is_ok()
        );
    }
}
#[test]
fn scoped_numeric_ids_remove_legacy_row_identity_collision_and_cover_semantics() {
    let mut section_ids = BTreeSet::new();
    let mut entry_ids = BTreeSet::new();
    let mut action_ids = BTreeSet::new();
    for section in SHORTCUT_SECTIONS {
        assert!(section_ids.insert(section.id() as u32));
        for row in section.entries() {
            assert!(entry_ids.insert(row.id() as u32));
            for action in row.actions() {
                action_ids.insert(action.code());
            }
        }
        for language in [
            ActionCatalogLanguage::English,
            ActionCatalogLanguage::SimplifiedChinese,
        ] {
            let table = shortcut_markdown_table(section.id(), language, &mut || Ok(())).unwrap();
            assert!(table.len() <= MAXIMUM_ACTION_CATALOG_TABLE_BYTES as usize);
            assert!(!table.ends_with('\n'));
        }
    }
    assert_eq!(
        TIMELINE_SHORTCUTS[4].legacy_id(),
        SEARCH_RESULTS_SHORTCUTS[0].legacy_id()
    );
    assert_ne!(TIMELINE_SHORTCUTS[4].id(), SEARCH_RESULTS_SHORTCUTS[0].id());
    assert_eq!(entry_ids.len(), 19);
    assert_eq!(action_ids.len(), 29);
}
