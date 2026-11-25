//! Decoding one C layout request (templates, bindings, module handles, show rules) into native values.
use super::*;

// C views remain valid until the synchronous call, including its parallel
// jobs, returns. Typst's Source trees and returned diagnostics own their data.
pub(super) struct Request<'a> {
    pub(super) source: &'a str,
    pub(super) source_name: &'a str,
    pub(super) setup_code: &'a str,
    pub(super) setup_source_name: &'a str,
    pub(super) bindings: typst_core::foundations::Scope,
    pub(super) templates: Vec<crate::layout::TemplateSource<'a>>,
    /// Sources of the evaluated modules behind the request's handles.
    pub(super) retained: Vec<typst_core::syntax::Source>,
    pub(super) shows: Vec<typst_core::foundations::Value>,
    /// Warnings raised while the request's templates were made.
    pub(super) warnings: Report,
    pub(super) flags: u32,
    pub(super) width_pt: f64,
    pub(super) height_pt: f64,
    pub(super) syntax: u32,
    pub(super) reserved: u32,
}
impl Request<'_> {
    pub(super) fn options(&self) -> TypstLayoutOptions {
        TypstLayoutOptions {
            flags: self.flags,
            width_pt: self.width_pt,
            height_pt: self.height_pt,
            syntax: self.syntax,
            reserved: self.reserved,
            ..Default::default()
        }
    }
}

/// The modules behind borrowed handles, for inputs to refer to by index, and
/// the sources that diagnostics raised inside their functions refer to.
pub(super) unsafe fn module_handles(
    data: *const *const TypstModule,
    count: usize,
) -> Result<
    (
        Vec<typst_core::foundations::Value>,
        Vec<typst_core::syntax::Source>,
    ),
    Error,
> {
    let mut modules = Vec::with_capacity(count);
    let mut sources = Vec::new();
    for handle in unsafe { values(data, count, "module handles")? } {
        let module = &unsafe { required(*handle, "module handle")? }.inner;
        modules.push(module.value.clone());
        for source in &module.sources {
            crate::layout::retain_source(&mut sources, source)?;
        }
    }
    Ok((modules, sources))
}

/// The modules of the handles exist already. Template functions are made
/// next, so that bindings and show rules can refer to both by index.
pub(super) unsafe fn request<'a>(
    context: &crate::context::Context,
    value: &'a TypstLayoutRequest,
) -> Result<Request<'a>, Error> {
    let source_name = unsafe { text(value.source_name, "source name")? };
    let attribute = |error: Error| error.with_source(source_name);
    let options: TypstLayoutOptions = unsafe { options(value.options) }.map_err(attribute)?;
    let named = |name: &'a str, what: &str| {
        if name.is_empty() {
            Err(attribute(Error::invalid(format!(
                "{what} must not be empty"
            ))))
        } else {
            Ok(name)
        }
    };
    let (handles, retained) =
        unsafe { module_handles(options.module_handles, options.module_handle_count) }
            .map_err(attribute)?;
    let mut templates = Vec::new();
    let mut functions = Vec::new();
    let mut warnings = Report::default();
    let records = unsafe { values(options.templates, options.template_count, "templates") };
    for record in records.map_err(attribute)? {
        let setup_code =
            unsafe { text(record.setup_code, "template setup code") }.map_err(attribute)?;
        let setup_name = unsafe { text(record.setup_source_name, "template setup source name") };
        let template = crate::layout::TemplateSource {
            code: unsafe { text(record.code, "template code") }.map_err(attribute)?,
            source_name: named(
                unsafe { text(record.source_name, "template source name") }.map_err(attribute)?,
                "template source name",
            )?,
            setup_code,
            setup_source_name: if setup_code.is_empty() {
                ""
            } else {
                named(setup_name.map_err(attribute)?, "template setup source name")?
            },
        };
        // Earlier templates are already evaluated; later ones cannot be referenced.
        let references = value::References {
            templates: &functions,
            handles: &handles,
        };
        let bindings =
            unsafe { value::bindings(record.bindings, record.binding_count, references) }
                .map_err(attribute)?;
        let (function, report) = context.template(template, bindings, &retained)?;
        warnings.merge(report);
        templates.push(template);
        functions.push(function);
    }
    let references = value::References {
        templates: &functions,
        handles: &handles,
    };
    let indices =
        unsafe { values(options.shows, options.show_count, "show rules") }.map_err(attribute)?;
    let mut shows = indices
        .iter()
        .map(|&index| {
            functions.get(index).cloned().ok_or_else(|| {
                attribute(Error::invalid("show rule template index is out of range"))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    let records = unsafe { values(options.show_values, options.show_value_count, "show values") };
    for record in records.map_err(attribute)? {
        let input = unsafe { required(record.value, "show rule value") }.map_err(attribute)?;
        let mut rule = unsafe { value::value(input, references) }.map_err(attribute)?;
        let path = unsafe { values(record.path, record.path_count, "show rule path") };
        for field in path.map_err(attribute)? {
            let field = unsafe { text(*field, "show rule field") }.map_err(attribute)?;
            rule = rule
                .field(field, ())
                .map_err(|message| attribute(Error::invalid(message.to_string())))?;
        }
        if !matches!(rule, typst_core::foundations::Value::Func(_)) {
            return Err(attribute(Error::invalid(format!(
                "a show rule value must be a function, found {}",
                rule.ty()
            ))));
        }
        shows.push(rule);
    }
    Ok(Request {
        source: unsafe { text(value.source, "source") }.map_err(attribute)?,
        setup_code: unsafe { text(options.setup_code, "setup code") }.map_err(attribute)?,
        setup_source_name: unsafe { text(options.setup_source_name, "setup source name") }
            .map_err(attribute)?,
        bindings: unsafe { value::bindings(options.bindings, options.binding_count, references) }
            .map_err(attribute)?,
        templates,
        retained,
        shows,
        warnings,
        flags: options.flags,
        width_pt: options.width_pt,
        height_pt: options.height_pt,
        syntax: options.syntax,
        reserved: options.reserved,
        source_name,
    })
}
