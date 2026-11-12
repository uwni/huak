//! Independent content layout through Typst's evaluator and frame layout API.
use comemo::Track;
use typst_core::diag::SourceResult;
use typst_core::engine::{Engine, Route, Sink, Traced};
use typst_core::foundations::{Context as EvalContext, Scope, StyleChain, Target, TargetElem};
use typst_core::introspection::{EmptyIntrospector, Locator};
use typst_core::layout::{Abs, Axes, Frame, Region, Size};
use typst_core::routines::SpanMode;
use typst_core::syntax::{RangeMapper, Span, SyntaxMode};
use typst_core::utils::Protected;
use typst_core::World;

use crate::abi::*;
use crate::context::{Context, JobWorld};
use crate::diagnostics::Report;
use crate::error::Error;

mod bounds;
mod setup;

pub(crate) struct Layout {
    pub(crate) frame: Frame,
}

impl Layout {
    pub(crate) fn metrics(&self) -> TypstMetrics {
        metrics(&self.frame)
    }

    pub(crate) fn bounds(&self) -> Result<[TypstPoint; 2], Error> {
        let bounds = bounds::bounds(&self.frame)
            .ok_or_else(|| Error::invalid("non-finite layout bounds"))?;
        Ok([bounds.min, bounds.max].map(|point| TypstPoint {
            x: point.x.to_pt(),
            y: point.y.to_pt(),
        }))
    }
}

pub(crate) fn metrics(frame: &Frame) -> TypstMetrics {
    TypstMetrics {
        width_pt: frame.width().to_pt(),
        height_pt: frame.height().to_pt(),
        baseline_pt: frame.baseline().to_pt(),
    }
}

impl Context {
    #[cfg(test)]
    pub(crate) fn layout(
        &self,
        source: &str,
        source_name: &str,
        options: &TypstLayoutOptions,
        request_index: usize,
    ) -> Result<(Layout, Report), Error> {
        self.layout_with_setup(
            source,
            source_name,
            options,
            "",
            "",
            Scope::new(),
            request_index,
        )
    }

    pub(crate) fn layout_with_setup(
        &self,
        source: &str,
        source_name: &str,
        options: &TypstLayoutOptions,
        setup_code: &str,
        setup_source_name: &str,
        bindings: Scope,
        request_index: usize,
    ) -> Result<(Layout, Report), Error> {
        let (mode, region) = region_and_syntax(options)?;
        let mut world = self.world(source, source_name)?;
        if !setup_code.is_empty() {
            world.set_setup(setup_code, setup_source_name)?;
        }
        let mut sink = Sink::new();
        let result = layout_in_world(&world, mode, region, bindings, &mut sink);
        let needs_document = !sink.introspections().is_empty();
        let delayed = sink.delayed();
        let mut report = Report::from_native(&world, &sink.warnings(), request_index);
        if needs_document {
            report.merge(Report::message(TYPST_DIAGNOSTIC_ERROR, "independent content cannot query document state; compile a complete document instead").with_source(source_name).with_request(request_index));
        }
        match result {
            Ok(frame) if delayed.is_empty() && !needs_document => Ok((Layout { frame }, report)),
            result => {
                if let Err(errors) = result {
                    report.merge(Report::from_native(&world, &errors, request_index));
                }
                report.merge(Report::from_native(&world, &delayed, request_index));
                Err(Error::compile(report))
            }
        }
    }
}

fn region_and_syntax(options: &TypstLayoutOptions) -> Result<(SyntaxMode, Region), Error> {
    if options.flags & !(TYPST_EXPAND_X | TYPST_EXPAND_Y | TYPST_BOUND_X | TYPST_BOUND_Y) != 0
        || options.reserved != 0
    {
        return Err(Error::invalid(
            "unknown layout flags or nonzero reserved field",
        ));
    }
    let mode = match options.syntax {
        TYPST_SYNTAX_MARKUP => SyntaxMode::Markup,
        TYPST_SYNTAX_CODE => SyntaxMode::Code,
        TYPST_SYNTAX_MATH => SyntaxMode::Math,
        _ => return Err(Error::invalid("unknown layout syntax")),
    };
    let dimension = |value: f64, expand: bool, bound: bool| -> Result<Abs, Error> {
        if !value.is_finite() || value < 0.0 {
            return Err(Error::invalid(
                "layout dimensions must be finite and nonnegative",
            ));
        }
        if value == 0.0 && !bound {
            if expand {
                return Err(Error::invalid(
                    "expansion requires a positive finite dimension",
                ));
            }
            Ok(Abs::inf())
        } else {
            Ok(Abs::pt(value))
        }
    };
    let expand = Axes::new(
        options.flags & TYPST_EXPAND_X != 0,
        options.flags & TYPST_EXPAND_Y != 0,
    );
    let size = Size::new(
        dimension(
            options.width_pt,
            expand.x,
            options.flags & TYPST_BOUND_X != 0,
        )?,
        dimension(
            options.height_pt,
            expand.y,
            options.flags & TYPST_BOUND_Y != 0,
        )?,
    );
    Ok((mode, Region::new(size, expand)))
}

fn layout_in_world(
    world: &JobWorld,
    mode: SyntaxMode,
    region: Region,
    bindings: Scope,
    sink: &mut Sink,
) -> SourceResult<Frame> {
    let library = world.library();
    let traced = Traced::default();
    let introspector = EmptyIntrospector;
    let setup_source = world.setup.as_ref();
    let world: &dyn World = world;
    let source = world
        .source(world.main())
        .expect("the request source is present");
    let eval_context = EvalContext::none();
    let mut engine = Engine {
        world: world.track(),
        library,
        introspector: Protected::new(introspector.track()),
        traced: traced.track(),
        sink: sink.track_mut(),
        route: Route::default(),
    };
    let content;
    if let Some(setup_source) = setup_source {
        (content, engine) =
            setup::evaluate(engine, &eval_context, setup_source, &source, mode, bindings)?;
    } else {
        content = if mode == SyntaxMode::Markup && bindings.iter().next().is_none() {
            typst_eval::eval(
                world.track(),
                library,
                traced.track(),
                comemo::TrackedMut::reborrow_mut(&mut engine.sink),
                Route::default().track(),
                &source,
            )?
            .content()
        } else {
            let mapper = RangeMapper::new(std::iter::once(0..source.text().len()))
                .expect("an identity source range is valid");
            typst_eval::eval_string(
                world.track(),
                library,
                comemo::TrackedMut::reborrow_mut(&mut engine.sink),
                introspector.track(),
                EvalContext::none().track(),
                source.text(),
                SpanMode::Mapped {
                    id: source.id(),
                    mapper: &mapper,
                    mapper_error_span: Span::detached(),
                },
                mode,
                bindings,
            )?
            .display()
        };
    }
    let target = TargetElem::target.set(Target::Paged).wrap();
    let base = StyleChain::new(&library.styles);
    let styles = base.chain(&target);
    typst_layout::layout_frame(&mut engine, &content, Locator::root(), styles, region)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use typst_core::foundations::{Array, Binding, Dict, IntoValue, Value};
    use typst_core::layout::FrameItem;

    fn glyph_count(frame: &Frame) -> usize {
        frame
            .items()
            .map(|(_, item)| match item {
                FrameItem::Text(text) => text.glyphs.len(),
                FrameItem::Group(group) => glyph_count(&group.frame),
                _ => 0,
            })
            .sum()
    }

    fn data(entries: &[(&str, Value)]) -> Scope {
        let mut payload = Dict::new();
        for (name, value) in entries {
            payload.insert((*name).into(), value.clone());
        }
        let mut scope = Scope::new();
        scope.bind("payload".into(), Binding::detached(payload));
        scope
    }

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
                0,
            )
            .unwrap()
            .0
    }

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
            crate::export::pdf(&crate::export::from_frame(&layout.frame), None)
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
        assert!(crate::export::pdf(&document, None)
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
            assert!(failure.report.entries.iter().any(|entry| {
                entry.source_name.ends_with("broken.typ") && entry.range.is_some()
            }));
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
            assert!(error.report.entries.iter().any(|entry| entry
                .message
                .contains("document state")
                && entry.source_name.ends_with("query.typ")
                && entry.request_index == 4));
        }
    }
}
