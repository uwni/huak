use super::*;
use typst_core::foundations::{Binding, Dict, IntoValue, Module};

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
