//! A setup and a body are separate parsed trees, evaluated by the upstream VM.
use comemo::Track;
use typst_core::{
    diag::{At, SourceResult},
    engine::{Engine, Sink},
    foundations::{Content, Context, Scope, Scopes, Value},
    syntax::{ast, FileId, RangeMapper, Source, Span, SyntaxKind, SyntaxMode, SyntaxNode},
};
use typst_eval::{Eval, Vm};

#[comemo::memoize]
fn prepared(source: &str, id: FileId) -> SourceResult<SyntaxNode> {
    let mut node = typst_core::syntax::parse_code(source);
    let mapper = RangeMapper::new(std::iter::once(0..source.len())).expect("identity source range");
    node.synthesize_mapped(id, &mapper).at(Span::detached())?;
    Ok(node)
}

pub(super) fn evaluate<'a>(
    mut engine: Engine<'a>,
    context: &'a Context<'a>,
    setup: &Source,
    body: &Source,
    mode: SyntaxMode,
    bindings: Scope,
) -> SourceResult<(Content, Engine<'a>)> {
    let prefix = prepared(setup.text(), setup.id())?;
    let mut body_tree = match mode {
        SyntaxMode::Code => typst_core::syntax::parse_code(body.text()),
        SyntaxMode::Math => typst_core::syntax::parse_math(body.text()),
        SyntaxMode::Markup => body.root().clone(),
    };
    let mapper =
        RangeMapper::new(std::iter::once(0..body.text().len())).expect("identity source range");
    body_tree
        .synthesize_mapped(body.id(), &mapper)
        .at(Span::detached())?;
    let mut errors = diagnostics(&prefix, &mut engine.sink);
    errors.extend(diagnostics(&body_tree, &mut engine.sink));
    if !errors.is_empty() {
        return Err(errors.into());
    }
    let (kind, left, right) = match mode {
        SyntaxMode::Markup => (
            SyntaxKind::ContentBlock,
            SyntaxKind::LeftBracket,
            SyntaxKind::RightBracket,
        ),
        SyntaxMode::Math => (SyntaxKind::Equation, SyntaxKind::Dollar, SyntaxKind::Dollar),
        SyntaxMode::Code => (
            SyntaxKind::CodeBlock,
            SyntaxKind::LeftBrace,
            SyntaxKind::RightBrace,
        ),
    };
    // Zero-length synthetic delimiters do not shift real byte ranges. Only the
    // upstream AST evaluates their syntax and lexical/style scope semantics.
    let mut expression = SyntaxNode::inner(
        kind,
        vec![
            SyntaxNode::leaf(left, ""),
            body_tree,
            SyntaxNode::leaf(right, ""),
        ],
    );
    expression
        .synthesize_mapped(body.id(), &mapper)
        .at(Span::detached())?;
    let mut children = prefix.children().cloned().collect::<Vec<_>>();
    children.push(expression);
    let tree = SyntaxNode::inner(SyntaxKind::Code, children);
    let library = engine.library;
    let mut scopes = Scopes::new(Some(library));
    if bindings.iter().next().is_some() {
        scopes.scopes.push(bindings);
    }
    let mut vm = Vm::new(engine, context.track(), scopes, Span::detached());
    let value = tree
        .cast::<ast::Code>()
        .expect("native Code tree")
        .eval(&mut vm)?;
    if let Some(flow) = vm.flow {
        return Err(vec![flow.forbidden()].into());
    }
    Ok((value.display(), vm.engine))
}

/// Evaluates template code in its own scope with its own bindings. Optional
/// setup runs first in that scope, so the resulting function captures its
/// definitions; the content and styles the setup produces are discarded.
pub(super) fn template<'a>(
    mut engine: Engine<'a>,
    context: &'a Context<'a>,
    setup: Option<&Source>,
    source: &Source,
    bindings: Scope,
) -> SourceResult<(Value, Engine<'a>)> {
    let prefix = setup
        .map(|setup| prepared(setup.text(), setup.id()))
        .transpose()?;
    let code = prepared(source.text(), source.id())?;
    let mut errors = Vec::new();
    if let Some(prefix) = &prefix {
        errors.extend(diagnostics(prefix, &mut engine.sink));
    }
    errors.extend(diagnostics(&code, &mut engine.sink));
    if !errors.is_empty() {
        return Err(errors.into());
    }
    let mut scopes = Scopes::new(Some(engine.library));
    if bindings.iter().next().is_some() {
        scopes.scopes.push(bindings);
    }
    let mut vm = Vm::new(engine, context.track(), scopes, Span::detached());
    if let Some(prefix) = &prefix {
        statements(prefix, &mut vm)?;
    }
    let value = statements(&code, &mut vm)?;
    Ok((value, vm.engine))
}

fn statements(tree: &SyntaxNode, vm: &mut Vm) -> SourceResult<Value> {
    let value = tree
        .cast::<ast::Code>()
        .expect("native Code tree")
        .eval(vm)?;
    if let Some(flow) = vm.flow.take() {
        return Err(vec![flow.forbidden()].into());
    }
    Ok(value)
}

fn diagnostics(
    node: &SyntaxNode,
    sink: &mut comemo::TrackedMut<'_, Sink>,
) -> Vec<typst_core::diag::SourceDiagnostic> {
    let (errors, warnings) = node.errors_and_warnings();
    for warning in warnings {
        sink.warn(warning.into());
    }
    errors.into_iter().map(Into::into).collect()
}

#[cfg(test)]
mod tests {
    use crate::{abi::*, context::Context};
    #[test]
    fn setup_scope_and_styles_apply_to_each_syntax_without_comment_concatenation() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        for (syntax, source, reference) in [
            (
                TYPST_SYNTAX_MARKUP,
                "#greeting $ x^2 $",
                "[#greeting $ x^2 $]",
            ),
            (TYPST_SYNTAX_CODE, "greeting", "{ greeting }"),
            (TYPST_SYNTAX_MATH, "greeting + x^2", "$greeting + x^2$"),
        ] {
            let options = TypstLayoutOptions {
                syntax,
                ..Default::default()
            };
            let setup = "let greeting = [Hello Ω]; set text(size: 22pt); // trailing comment";
            let (layout, _) = context
                .layout_with_setup(
                    source,
                    "source",
                    &options,
                    setup,
                    "preamble",
                    Default::default(),
                    Default::default(),
                    0,
                )
                .unwrap();
            assert!(layout.metrics().width_pt > 0.0);
            let reference =
                format!("{{ let greeting = [Hello Ω]; set text(size: 22pt); {reference} }}");
            let (expected, _) = context
                .layout(
                    &reference,
                    "reference",
                    &TypstLayoutOptions {
                        syntax: TYPST_SYNTAX_CODE,
                        ..Default::default()
                    },
                    0,
                )
                .unwrap();
            assert_eq!(
                layout.metrics().width_pt,
                expected.metrics().width_pt,
                "syntax {syntax}"
            );
            assert_eq!(
                layout.metrics().height_pt,
                expected.metrics().height_pt,
                "syntax {syntax}"
            );
        }
    }
    #[test]
    fn independent_setup_and_body_diagnostics_keep_their_native_byte_ranges() {
        let context = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        for (setup, body, expected) in [
            ("let title = missing_setup", "text", "preamble"),
            ("let title = [valid]", "#missing_body", "source"),
        ] {
            let error = match context.layout_with_setup(
                body,
                "source",
                &Default::default(),
                setup,
                "preamble",
                Default::default(),
                Default::default(),
                7,
            ) {
                Ok(_) => panic!("expected native evaluation error"),
                Err(error) => error,
            };
            assert_eq!(error.status, TYPST_COMPILE_FAILED);
            assert!(error
                .report
                .entries
                .iter()
                .any(|entry| entry.source_name.ends_with(expected)
                    && entry.range.is_some()
                    && entry.request_index == 7));
        }
    }
    #[test]
    fn native_zero_regions_and_optional_plugin_policy_are_explicit() {
        let context =
            Context::new(vec![], vec![], vec![], "", TYPST_CONTEXT_DISABLE_PLUGINS).unwrap();
        let options = TypstLayoutOptions {
            flags: TYPST_BOUND_X | TYPST_EXPAND_X,
            ..Default::default()
        };
        let (layout, _) = context.layout("x", "source", &options, 0).unwrap();
        assert_eq!(layout.metrics().width_pt, 0.0);
        for source in ["#repr(plugin)", "#repr(std.plugin)"] {
            assert!(context
                .layout(source, "source", &Default::default(), 0)
                .is_err());
        }
        let ordinary = Context::new(vec![], vec![], vec![], "", 0).unwrap();
        assert!(ordinary
            .layout("#repr(type(plugin))", "source", &Default::default(), 0)
            .is_ok());
    }
}
