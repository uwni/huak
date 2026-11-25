use super::*;
use std::sync::Arc;

#[test]
fn markup_code_math_and_native_styles_produce_real_frames() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    for (syntax, source) in [
        (
            TYPST_SYNTAX_MARKUP,
            "Café Ω $ x^2 $ #rect(width: 20pt, height: 4pt)",
        ),
        (
            TYPST_SYNTAX_CODE,
            "{ set text(size: 22pt, weight: 700, fill: red); [Styled] }",
        ),
        (TYPST_SYNTAX_MATH, "sum_(i=1)^n i"),
    ] {
        let options = TypstLayoutOptions {
            syntax,
            ..Default::default()
        };
        let (layout, _) = context.layout(source, "content.typ", &options, 0).unwrap();
        assert!(glyph_count(&layout.frame) > 0);
        let metrics = layout.metrics();
        assert!(metrics.width_pt.is_finite() && metrics.width_pt > 0.0);
        assert!(metrics.height_pt.is_finite() && metrics.height_pt > 0.0);
        assert!(metrics.baseline_pt.is_finite());
    }
}

#[test]
fn region_wrapping_and_expansion_use_native_layout() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    let source = "A paragraph with enough words to wrap into several lines in a narrow region.";
    let narrow = TypstLayoutOptions {
        width_pt: 80.0,
        ..Default::default()
    };
    let wide = TypstLayoutOptions {
        width_pt: 240.0,
        ..Default::default()
    };
    let (narrow, _) = context.layout(source, "paragraph.typ", &narrow, 0).unwrap();
    let (wide, _) = context.layout(source, "paragraph.typ", &wide, 0).unwrap();
    assert!(narrow.frame.height() > wide.frame.height());
    let expanded = TypstLayoutOptions {
        flags: TYPST_EXPAND_X | TYPST_EXPAND_Y,
        width_pt: 240.0,
        height_pt: 120.0,
        ..Default::default()
    };
    let (expanded, _) = context.layout("Text", "", &expanded, 0).unwrap();
    assert_eq!(expanded.frame.width().to_pt(), 240.0);
    assert_eq!(expanded.frame.height().to_pt(), 120.0);
    assert!(context
        .layout(
            "Text",
            "",
            &TypstLayoutOptions {
                flags: TYPST_EXPAND_X,
                ..Default::default()
            },
            0
        )
        .is_err());
}

#[test]
fn independent_concurrent_requests_share_resources_and_outputs_outlive_context() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    let layouts = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..4)
            .map(|index| {
                let context = &context;
                scope.spawn(move || {
                    context
                        .layout(
                            &format!("Concurrent {index} $ x^2 $"),
                            "parallel.typ",
                            &Default::default(),
                            index,
                        )
                        .unwrap()
                        .0
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>()
    });
    for layout in &layouts {
        assert!(glyph_count(&layout.frame) > 10);
    }
    let resources = Arc::downgrade(&context.resources);
    drop(context);
    assert!(resources.upgrade().is_none());
    assert!(layouts.iter().all(|layout| glyph_count(&layout.frame) > 10));
    let document = crate::export::from_frame(&layouts[0].frame);
    assert!(crate::export::svg(&document, 0)
        .unwrap()
        .starts_with(b"<svg"));
    assert!(crate::export::pdf(&document, "", "")
        .unwrap()
        .starts_with(b"%PDF-"));
}

#[test]
fn failed_layouts_keep_request_diagnostics_and_do_not_poison_resources() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    for syntax in [TYPST_SYNTAX_MARKUP, TYPST_SYNTAX_CODE, TYPST_SYNTAX_MATH] {
        let options = TypstLayoutOptions {
            syntax,
            ..Default::default()
        };
        let failure = context
            .layout("#unknown_name(", "broken.typ", &options, 17)
            .err()
            .expect("invalid source must fail in each syntax mode");
        assert_eq!(failure.status, TYPST_COMPILE_FAILED);
        assert!(!failure.report.entries.is_empty());
        assert!(failure
            .report
            .entries
            .iter()
            .all(|entry| entry.request_index == 17));
        assert!(failure
            .report
            .entries
            .iter()
            .any(|entry| { entry.source_name.ends_with("broken.typ") && entry.range.is_some() }));
    }
    let (valid, _) = context
        .layout("Valid", "valid.typ", &Default::default(), 0)
        .unwrap();
    assert!(glyph_count(&valid.frame) > 0);
}

#[test]
fn standalone_layout_rejects_queries_that_require_document_convergence() {
    let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
    for source in [
        "#context counter(page).get().repr()",
        "#context query(heading).len()",
    ] {
        let error = context
            .layout(source, "query.typ", &Default::default(), 4)
            .err()
            .expect("document state is unavailable in a standalone layout");
        assert_eq!(error.status, TYPST_COMPILE_FAILED);
        assert!(error
            .report
            .entries
            .iter()
            .any(|entry| entry.message.contains("document state")
                && entry.source_name.ends_with("query.typ")
                && entry.request_index == 4));
    }
}
