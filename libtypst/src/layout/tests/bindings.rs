use super::*;
use typst_core::foundations::{Array, IntoValue};

fn bound(context: &Context, source: &str, bindings: Scope, setup: &str, syntax: u32) -> Layout {
    context
        .layout_with_setup(
            source,
            "source.typ",
            &TypstLayoutOptions {
                syntax,
                ..Default::default()
            },
            setup,
            "setup.typ",
            bindings,
            Prepared::default(),
            0,
        )
        .unwrap()
        .0
}

/// Lays out `body` next to the request's `payload.word` and its binding
/// `style`, the template made from `setup` and `code` with its own
/// bindings. With `apply`, the template is also a show rule around it.

#[test]
fn lexical_bindings_use_native_types_and_keep_strings_as_data() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    let title = "Café Ω \"quoted\"\n#panic(\"must stay data\")";
    let scope = data(&[
        ("count", i64::MIN.into_value()),
        ("ratio", 1.25.into_value()),
        ("flag", true.into_value()),
        ("title", title.into_value()),
        (
            "values",
            [1i64.into_value(), "two".into_value(), Value::None]
                .into_iter()
                .collect::<Array>()
                .into_value(),
        ),
    ]);
    let source = r#"{
        assert(type(payload.count) == int)
        assert(payload.count + 1 == -9223372036854775807)
        assert(type(payload.ratio) == float)
        assert(payload.ratio == 1.25)
        assert(payload.flag == true)
        assert(payload.values == (1, "two", none))
        assert(payload.title == "Café Ω \"quoted\"\n#panic(\"must stay data\")")
        payload.title
    }"#;
    let layout = bound(&context, source, scope, "", TYPST_SYNTAX_CODE);
    assert!(glyph_count(&layout.frame) > 20);
    let svg = crate::export::svg(&crate::export::from_frame(&layout.frame), 0).unwrap();
    assert!(svg.starts_with(b"<svg"));
    assert!(
        crate::export::pdf(&crate::export::from_frame(&layout.frame), "", "")
            .unwrap()
            .starts_with(b"%PDF-")
    );
}

#[test]
fn request_bindings_share_setup_scope_and_do_not_stale_cache_or_context() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    let source = "#greeting";
    let setup = "let greeting = payload.title; set text(size: payload.size, fill: payload.ink)";
    let first = data(&[
        ("title", "Short".into_value()),
        ("size", Abs::pt(11.0).into_value()),
        ("ink", typst_core::visualize::Color::BLACK.into_value()),
    ]);
    let second = data(&[
        ("title", "A much longer line".into_value()),
        ("size", Abs::pt(20.0).into_value()),
        ("ink", typst_core::visualize::Color::BLACK.into_value()),
    ]);
    let a = bound(&context, source, first.clone(), setup, TYPST_SYNTAX_MARKUP);
    let b = bound(&context, source, second, setup, TYPST_SYNTAX_MARKUP);
    let again = bound(&context, source, first, setup, TYPST_SYNTAX_MARKUP);
    assert!(b.frame.width() > a.frame.width());
    assert_eq!(a.metrics().width_pt, again.metrics().width_pt);
    assert!(context
        .layout("#payload.title", "isolated.typ", &Default::default(), 0)
        .is_err());
    assert!(context
        .layout("#std.payload", "standard.typ", &Default::default(), 0)
        .is_err());
}

#[test]
fn request_bindings_stay_local_to_all_syntax_modes_and_imports() {
    let context = Context::new(
        vec![],
        vec![],
        vec![("child.typ".into(), b"#payload.title".to_vec())],
        "",
        0,
    )
    .unwrap();
    let scope = data(&[
        ("title", "Native title".into_value()),
        ("count", 3i64.into_value()),
    ]);
    for (syntax, source) in [
        (TYPST_SYNTAX_MARKUP, "#payload.title"),
        (TYPST_SYNTAX_CODE, "payload.title"),
        (TYPST_SYNTAX_MATH, "#payload.count + x"),
    ] {
        assert!(glyph_count(&bound(&context, source, scope.clone(), "", syntax).frame) > 0);
    }
    let error = context
        .layout_with_setup(
            "#include \"child.typ\"",
            "source.typ",
            &Default::default(),
            "",
            "setup.typ",
            scope,
            Prepared::default(),
            9,
        )
        .err()
        .unwrap();
    assert_eq!(error.status, TYPST_COMPILE_FAILED);
    assert!(error
        .report
        .entries
        .iter()
        .any(|entry| entry.source_name.ends_with("child.typ")
            && entry.message.contains("unknown variable")));
}

#[test]
fn binding_errors_keep_native_setup_and_body_source_ranges() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    for (setup, body, expected) in [
        ("", "#payload.missing", "source.typ"),
        ("let label = payload.missing", "#label", "setup.typ"),
    ] {
        let error = context
            .layout_with_setup(
                body,
                "source.typ",
                &Default::default(),
                setup,
                "setup.typ",
                data(&[("title", "available".into_value())]),
                Prepared::default(),
                13,
            )
            .err()
            .expect("missing field must produce a native error");
        assert_eq!(error.status, TYPST_COMPILE_FAILED);
        assert!(error
            .report
            .entries
            .iter()
            .any(|entry| entry.source_name.ends_with(expected)
                && entry.range.is_some()
                && entry.request_index == 13));
    }
}
