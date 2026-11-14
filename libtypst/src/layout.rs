//! Independent content layout through Typst's evaluator and frame layout API.
use std::sync::OnceLock;

use comemo::Track;
use typst_core::diag::SourceResult;
use typst_core::engine::{Engine, Route, Sink, Traced};
use typst_core::foundations::{
    Context as EvalContext, Scope, StyleChain, Target, TargetElem, Value,
};
use typst_core::introspection::{EmptyIntrospector, Locator};
use typst_core::layout::{Abs, Axes, Frame, Region, Size};
use typst_core::routines::SpanMode;
use typst_core::syntax::{RangeMapper, Source, Span, SyntaxMode};
use typst_core::utils::Protected;
use typst_core::World;

use crate::abi::*;
use crate::context::{Context, JobWorld};
use crate::diagnostics::Report;
use crate::error::Error;

mod bounds;
mod labels;
mod setup;

pub(crate) struct Layout {
    pub(crate) frame: Frame,
    /// Read from the frame when first requested.
    labels: OnceLock<Option<labels::Labels>>,
}

/// Template code and its optional setup. Requests keep these sources in their
/// world so that diagnostics raised inside a template call resolve.
#[derive(Clone, Copy, Default)]
pub(crate) struct TemplateSource<'a> {
    pub(crate) code: &'a str,
    pub(crate) source_name: &'a str,
    pub(crate) setup_code: &'a str,
    pub(crate) setup_source_name: &'a str,
}

/// Code to evaluate into a module, with the source name that names the
/// module and locates its diagnostics.
#[derive(Clone, Copy, Default)]
pub(crate) struct ModuleSource<'a> {
    pub(crate) code: &'a str,
    pub(crate) source_name: &'a str,
}

/// A module evaluated once and kept for many requests, with the sources that
/// diagnostics raised inside its functions refer to: its own first, then
/// those of the modules it was evaluated with.
pub(crate) struct EvaluatedModule {
    pub(crate) value: Value,
    pub(crate) sources: Vec<Source>,
}

/// Adds `source` unless it is already there. Two texts under one name would
/// leave the spans of one of them without a source.
pub(crate) fn retain_source(sources: &mut Vec<Source>, source: &Source) -> Result<(), Error> {
    match sources.iter().find(|known| known.id() == source.id()) {
        Some(known) if known.text() == source.text() => Ok(()),
        Some(_) => Err(Error::invalid(
            "module handles used together must have distinct source names",
        )),
        None => {
            sources.push(source.clone());
            Ok(())
        }
    }
}

/// What a request prepares before its content: the template sources it
/// refers to, the sources of the evaluated modules it uses, and the
/// functions it applies around its content as `#show:` rules, outermost
/// first.
#[derive(Clone, Copy, Default)]
pub(crate) struct Prepared<'a> {
    pub(crate) templates: &'a [TemplateSource<'a>],
    pub(crate) retained: &'a [Source],
    pub(crate) shows: &'a [Value],
}

impl Layout {
    pub(crate) fn new(frame: Frame) -> Self {
        Self {
            frame,
            labels: OnceLock::new(),
        }
    }

    /// Labeled elements in document order, borrowed for the layout's lifetime.
    pub(crate) fn labels(&self) -> Result<&[TypstLabeledElement], Error> {
        self.labels
            .get_or_init(|| labels::collect(&self.frame))
            .as_ref()
            .map(labels::Labels::elements)
            .ok_or_else(|| Error::invalid("non-finite label geometry"))
    }

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
            Prepared::default(),
            request_index,
        )
    }

    /// Evaluates module code like an imported file, with `bindings` visible
    /// from an enclosing scope. `retained` are the sources of the evaluated
    /// modules those bindings refer to. Warnings are returned for the caller's
    /// report.
    pub(crate) fn module(
        &self,
        module: ModuleSource<'_>,
        bindings: Scope,
        retained: &[Source],
    ) -> Result<(EvaluatedModule, Report), Error> {
        let mut world = self.world(module.code, module.source_name)?;
        world.add_parsed(retained)?;
        let library = world.library();
        let traced = Traced::default();
        let introspector = EmptyIntrospector;
        let mut sink = Sink::new();
        let eval_context = EvalContext::none();
        let result = {
            let world: &dyn World = &world;
            let source = world
                .source(world.main())
                .expect("the module source is present");
            let engine = Engine {
                world: world.track(),
                library,
                introspector: Protected::new(introspector.track()),
                traced: traced.track(),
                sink: sink.track_mut(),
                route: Route::default(),
            };
            setup::module(engine, &eval_context, &source, bindings).map(|(module, _)| module)
        };
        let mut report = Report::from_native(&world, &sink.warnings(), usize::MAX);
        match result {
            Ok(module) => {
                let mut sources = Vec::with_capacity(1 + retained.len());
                sources.push(world.source.clone());
                sources.extend_from_slice(retained);
                let module = EvaluatedModule {
                    value: Value::Module(module),
                    sources,
                };
                Ok((module, report))
            }
            Err(errors) => {
                report.merge(Report::from_native(&world, &errors, usize::MAX));
                Err(Error::compile(report))
            }
        }
    }

    /// Evaluates template code into its function value with its own bindings,
    /// before a request that refers to it. `retained` are the sources of the
    /// evaluated modules those bindings refer to. Warnings are returned for
    /// that request's report; the function itself owns its syntax and captures.
    pub(crate) fn template(
        &self,
        template: TemplateSource<'_>,
        bindings: Scope,
        retained: &[Source],
    ) -> Result<(Value, Report), Error> {
        let mut world = self.world(template.code, template.source_name)?;
        if !template.setup_code.is_empty() {
            world.set_setup(template.setup_code, template.setup_source_name)?;
        }
        world.add_parsed(retained)?;
        let library = world.library();
        let traced = Traced::default();
        let introspector = EmptyIntrospector;
        let mut sink = Sink::new();
        let eval_context = EvalContext::none();
        let result = {
            let setup = world.setup.as_ref();
            let world: &dyn World = &world;
            let source = world
                .source(world.main())
                .expect("the template source is present");
            let engine = Engine {
                world: world.track(),
                library,
                introspector: Protected::new(introspector.track()),
                traced: traced.track(),
                sink: sink.track_mut(),
                route: Route::default(),
            };
            setup::template(engine, &eval_context, setup, &source, bindings).map(|(value, _)| value)
        };
        let mut report = Report::from_native(&world, &sink.warnings(), usize::MAX);
        match result {
            Ok(value @ Value::Func(_)) => Ok((value, report)),
            Ok(value) => Err(Error::invalid(format!(
                "template code must evaluate to a function, found {}",
                value.ty()
            ))
            .with_source(template.source_name)),
            Err(errors) => {
                report.merge(Report::from_native(&world, &errors, usize::MAX));
                Err(Error::compile(report))
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn layout_with_setup(
        &self,
        source: &str,
        source_name: &str,
        options: &TypstLayoutOptions,
        setup_code: &str,
        setup_source_name: &str,
        bindings: Scope,
        prepared: Prepared<'_>,
        request_index: usize,
    ) -> Result<(Layout, Report), Error> {
        let (mode, region) = region_and_syntax(options)?;
        let mut world = self.world(source, source_name)?;
        if !setup_code.is_empty() {
            world.set_setup(setup_code, setup_source_name)?;
        }
        for template in prepared.templates {
            world.add_source(template.code, template.source_name)?;
            if !template.setup_code.is_empty() {
                world.add_source(template.setup_code, template.setup_source_name)?;
            }
        }
        world.add_parsed(prepared.retained)?;
        let mut sink = Sink::new();
        let result = layout_in_world(&world, mode, region, bindings, prepared.shows, &mut sink);
        let needs_document = !sink.introspections().is_empty();
        let delayed = sink.delayed();
        let mut report = Report::from_native(&world, &sink.warnings(), request_index);
        if needs_document {
            report.merge(Report::message(TYPST_DIAGNOSTIC_ERROR, "independent content cannot query document state; compile a complete document instead").with_source(source_name).with_request(request_index));
        }
        match result {
            Ok(frame) if delayed.is_empty() && !needs_document => Ok((Layout::new(frame), report)),
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
    let mode = crate::syntax::syntax_mode(options.syntax)
        .map_err(|_| Error::invalid("unknown layout syntax"))?;
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
    shows: &[Value],
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
    let mut content;
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
    // As with `#show: rule` at the start of the body, the innermost rule
    // receives the content first and nearer rules take precedence.
    for rule in shows.iter().rev() {
        let Value::Func(function) = rule else {
            unreachable!("show rules are checked to be functions before layout");
        };
        content = function
            .call(&mut engine, eval_context.track(), [content])?
            .display();
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
    use typst_core::foundations::{Array, Binding, Dict, IntoValue, Module, Value};
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
                Prepared::default(),
                0,
            )
            .unwrap()
            .0
    }

    /// Lays out `body` next to the request's `payload.word` and its binding
    /// `style`, the template made from `setup` and `code` with its own
    /// bindings. With `apply`, the template is also a show rule around it.
    fn styled(
        context: &Context,
        body: &str,
        setup: &str,
        code: &str,
        own: Scope,
        apply: bool,
    ) -> Result<(Layout, Report), Error> {
        let template = TemplateSource {
            code,
            source_name: "template.typ",
            setup_code: setup,
            setup_source_name: "template-setup.typ",
        };
        let (style, _) = context.template(template, own, &[])?;
        let mut bindings = data(&[("word", "Hello".into_value())]);
        bindings.bind("style".into(), Binding::detached(style.clone()));
        let shows = [style];
        let templates = Prepared {
            templates: &[template],
            retained: &[],
            shows: if apply { &shows } else { &[] },
        };
        context.layout_with_setup(
            body,
            "source.typ",
            &Default::default(),
            "",
            "",
            bindings,
            templates,
            0,
        )
    }

    fn mentions(error: &Error, source: &str, message: &str) -> bool {
        error
            .report
            .entries
            .iter()
            .any(|entry| entry.source_name.ends_with(source) && entry.message.contains(message))
    }

    #[test]
    fn templates_are_functions_with_their_own_scope_and_data() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let width = |body: &str, setup: &str, code: &str, own: Scope, apply: bool| {
            let (layout, _) = styled(&context, body, setup, code, own, apply).unwrap();
            layout.metrics().width_pt
        };
        let identity = "body => body";
        let plain = width("#payload.word", "", identity, Scope::new(), false);
        // The template reads its own `payload`; the body reads the request's.
        let mut size = Dict::new();
        size.insert("size".into(), Abs::pt(30.0).into_value());
        let mut own = Scope::new();
        own.bind("payload".into(), Binding::detached(size));
        let set_size = "body => { set text(size: payload.size); body }";
        let large = width(
            "#show: style\n#payload.word",
            "",
            set_size,
            own.clone(),
            false,
        );
        assert!(large > 2.0 * plain);
        // A request show rule applies it to the whole content.
        let applied = width("#payload.word", "", set_size, own.clone(), true);
        assert!((applied - large).abs() < 1e-9);
        // A direct call styles only part of the content.
        let part = width(
            "#style[#payload.word] #payload.word",
            "",
            set_size,
            own.clone(),
            false,
        );
        assert!(part > large && part < 2.0 * large);
        // Rules nearer to the content take precedence over an applied rule.
        let near = width("#text(size: 5pt, payload.word)", "", set_size, own, true);
        assert!(near < plain);
        // An everything rule wraps the body it receives.
        let wrapped = width(
            "#show: style\n#payload.word",
            "",
            "body => [Wrapped #body]",
            Scope::new(),
            false,
        );
        assert!(wrapped > plain);
        // The template's setup lends it definitions, while its own rules
        // style nothing and its definitions stay away from the body.
        let helper = width(
            "#show: style\n#payload.word",
            "let big(it) = text(size: 30pt, it)",
            "body => big(body)",
            Scope::new(),
            false,
        );
        assert!(helper > 2.0 * plain);
        let unstyled = width(
            "#show: style\n#payload.word",
            "set text(size: 30pt)",
            identity,
            Scope::new(),
            false,
        );
        assert!((unstyled - plain).abs() < 1e-9);
        let hidden = styled(
            &context,
            "#show: style\n#big[x]",
            "let big(it) = it",
            identity,
            Scope::new(),
            false,
        );
        let error = hidden.err().unwrap();
        assert_eq!(error.status, TYPST_COMPILE_FAILED);
        assert!(mentions(&error, "source.typ", "unknown variable"));
        // Errors raised during a call keep the template's own source names.
        let failing = styled(
            &context,
            "#show: style\nHello",
            "",
            "body => { set text(size: missing); body }",
            Scope::new(),
            false,
        );
        assert!(mentions(
            &failing.err().unwrap(),
            "template.typ",
            "unknown variable"
        ));
        let deep = styled(
            &context,
            "#show: style\nHello",
            "let broken(it) = text(size: missing, it)",
            "body => broken(body)",
            Scope::new(),
            false,
        );
        assert!(mentions(
            &deep.err().unwrap(),
            "template-setup.typ",
            "unknown variable"
        ));
        // The code must evaluate to a function; syntax errors appear when made.
        let number = TemplateSource {
            code: "1 + 2",
            source_name: "number.typ",
            ..Default::default()
        };
        let error = context.template(number, Scope::new(), &[]).err().unwrap();
        assert_eq!(error.status, TYPST_INVALID_ARGUMENT);
        let broken = TemplateSource {
            code: "body => {",
            source_name: "broken.typ",
            ..Default::default()
        };
        let error = context.template(broken, Scope::new(), &[]).err().unwrap();
        assert_eq!(error.status, TYPST_COMPILE_FAILED);
        assert!(mentions(&error, "broken.typ", ""));
        // Body, setup and template sources keep distinct names.
        let clash = TemplateSource {
            code: identity,
            source_name: "source.typ",
            ..Default::default()
        };
        let templates = Prepared {
            templates: &[clash],
            retained: &[],
            shows: &[],
        };
        let options = Default::default();
        let result = context.layout_with_setup(
            "Hello",
            "source.typ",
            &options,
            "",
            "",
            Scope::new(),
            templates,
            0,
        );
        assert_eq!(result.err().unwrap().status, TYPST_INVALID_ARGUMENT);
    }

    #[test]
    fn module_bindings_call_template_functions_in_markup_and_math() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let mark = TemplateSource {
            code: "(name, body) => [#box(body)#label(name)]",
            source_name: "mark.typ",
            ..Default::default()
        };
        let (function, _) = context.template(mark, Scope::new(), &[]).unwrap();
        let mut members = Scope::new();
        members.bind("mark".into(), Binding::detached(function));
        members.bind("count".into(), Binding::detached(2i64));
        let mut bindings = Scope::new();
        bindings.bind(
            "lib".into(),
            Binding::detached(Value::Module(Module::new("lib", members))),
        );
        let templates = Prepared {
            templates: &[mark],
            retained: &[],
            shows: &[],
        };
        let (layout, _) = context
            .layout_with_setup(
                "#lib.mark(\"x\")[Text] $mat(lib.mark(\"a\", a), b) $ #lib.count",
                "source.typ",
                &Default::default(),
                "",
                "",
                bindings,
                templates,
                0,
            )
            .unwrap();
        let labels = layout.labels().unwrap();
        let names: Vec<_> = labels
            .iter()
            .map(|element| unsafe {
                std::str::from_utf8(std::slice::from_raw_parts(
                    element.label.data,
                    element.label.len,
                ))
                .unwrap()
            })
            .collect();
        assert_eq!(names, ["x", "a"]);
    }

    #[test]
    fn evaluated_modules_keep_their_values_and_the_sources_their_errors_name() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        let mut own = Scope::new();
        own.bind("size".into(), Binding::detached(Abs::pt(30.0)));
        let base = ModuleSource {
            code: "#let scale = size\n#let fail() = panic(\"inside base\")",
            source_name: "base.typ",
        };
        let (base, _) = context.module(base, own, &[]).unwrap();
        assert_eq!(base.sources.len(), 1);
        let mut uses = Scope::new();
        uses.bind("base".into(), Binding::detached(base.value.clone()));
        let theme = ModuleSource {
            code: "#let twice = base.scale * 2\n#let fail = base.fail",
            source_name: "theme.typ",
        };
        let (theme, _) = context.module(theme, uses, &base.sources).unwrap();
        // Its own source comes first, then those it was evaluated with.
        assert_eq!(theme.sources.len(), 2);
        assert!(theme.sources[0]
            .id()
            .vpath()
            .get_with_slash()
            .ends_with("theme.typ"));
        drop(base);

        let mut bindings = Scope::new();
        bindings.bind("lib".into(), Binding::detached(theme.value.clone()));
        let prepared = Prepared {
            retained: &theme.sources,
            ..Default::default()
        };
        let layout = |body: &str, name: &str, prepared: Prepared<'_>| {
            context.layout_with_setup(
                body,
                name,
                &Default::default(),
                "",
                "",
                bindings.clone(),
                prepared,
                0,
            )
        };
        let (frame, _) = layout(
            "#assert(lib.twice == 60pt and \"base\" not in dictionary(lib))Hello",
            "source.typ",
            prepared,
        )
        .unwrap();
        assert!(glyph_count(&frame.frame) > 0);
        // An error inside the first module's function has a range in its text
        // only when the request's world keeps that source.
        let located = |prepared: Prepared<'_>| {
            let error = layout("#lib.fail()", "source.typ", prepared).err().unwrap();
            assert!(mentions(&error, "base.typ", "inside base"));
            error.report.entries[0].range.is_some()
        };
        assert!(located(prepared));
        assert!(!located(Prepared::default()));
        // Evaluated modules share the distinct-name rule with request sources.
        let clash = layout("Hello", "theme.typ", prepared).err().unwrap();
        assert_eq!(clash.status, TYPST_INVALID_ARGUMENT);

        let mut sources = Vec::new();
        for source in theme.sources.iter().chain(&theme.sources) {
            retain_source(&mut sources, source).unwrap();
        }
        assert_eq!(sources.len(), 2);
        let other = ModuleSource {
            code: "#let twice = 1pt",
            source_name: "theme.typ",
        };
        let (other, _) = context.module(other, Scope::new(), &[]).unwrap();
        let error = retain_source(&mut sources, &other.sources[0])
            .err()
            .unwrap();
        assert_eq!(error.status, TYPST_INVALID_ARGUMENT);
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
