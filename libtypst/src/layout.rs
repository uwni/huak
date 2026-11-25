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
mod tests;
