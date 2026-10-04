use arktrace_contract::*;
use arktrace_viewer::*;
#[test]
fn number_multiply_utf16_and_ascii_digit_stripping_have_distinct_semantics() {
    assert_eq!(
        palette_hash("ArkTrace 时间线", 20, &mut || Ok(())).unwrap(),
        12
    );
    assert_eq!(
        slice_name_color("fn42", 0, &mut || Ok(())).unwrap(),
        slice_name_color("fn43", 0, &mut || Ok(())).unwrap()
    );
    assert_ne!(
        palette_hash_func("٣", 0, i64::MAX, &mut || Ok(())).unwrap(),
        palette_hash_func("", 0, i64::MAX, &mut || Ok(())).unwrap()
    );
    assert_ne!(
        palette_hash("🚀", i64::MAX, &mut || Ok(())).unwrap(),
        palette_hash("�", i64::MAX, &mut || Ok(())).unwrap()
    );
}
#[test]
fn negative_annotation_index_and_depth_are_total_even_at_int64_extremes() {
    assert_eq!(annotation_color(-1), annotation_color(5));
    assert_eq!(annotation_color(i64::MIN).slot.index, 4);
    assert_eq!(
        palette_hash_func("slice42", i64::MIN, 20, &mut || Ok(())).unwrap(),
        palette_hash_func("slice42", 0, 20, &mut || Ok(())).unwrap()
    );
    assert_eq!(palette_hash("name", 0, &mut || Ok(())).unwrap(), 0);
    assert_eq!(palette_hash("name", -1, &mut || Ok(())).unwrap(), 0);
}
#[test]
fn exact_raw_state_takes_precedence_and_unknown_does_not_guess() {
    assert_eq!(
        state_color(Some("D-NIO"), Some(TraceThreadState::Running)).unwrap(),
        state_color(Some("DK-NIO"), None).unwrap()
    );
    assert_eq!(state_color(Some("READY"), None).unwrap().slot.index, 7);
    assert_eq!(
        state_color(Some("READY"), Some(TraceThreadState::Runnable))
            .unwrap()
            .slot
            .index,
        2
    );
    assert_eq!(
        state_color(None, Some(TraceThreadState::Stopped))
            .unwrap()
            .slot
            .index,
        7
    );
}
#[test]
fn alpha_is_clamped_for_finite_input_and_nonfinite_is_explicitly_rejected() {
    let color = Rgb::hex(0x377ea7);
    assert_eq!(color.rgba(-1.0).unwrap().alpha, 0.0);
    assert_eq!(color.rgba(2.0).unwrap().alpha, 1.0);
    for a in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(color.rgba(a), Err(ViewerError::InvalidGeometry));
    }
}
#[test]
fn palette_budget_and_cancel_failure_allow_next_hash_request() {
    assert_eq!(
        palette_hash(&"a".repeat(4097), 20, &mut || Ok(())),
        Err(ViewerError::InputBudgetExceeded)
    );
    let mut calls = 0;
    let mut check = || {
        calls += 1;
        if calls == 4 {
            Err(ViewerError::Cancelled)
        } else {
            Ok(())
        }
    };
    assert_eq!(
        palette_hash(&"🚀".repeat(1000), 20, &mut check),
        Err(ViewerError::Cancelled)
    );
    assert_eq!(calls, 4);
    assert!(palette_hash("next", 20, &mut || Ok(())).is_ok());
}
