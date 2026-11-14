//! Stable C entry points and their pointer, ownership and panic contracts.
//!
//! # Pointer and ownership contract
//!
//! Input records and nonempty views must point to aligned, initialized, readable
//! storage covering the declared prefix or array. Views may use null for zero
//! length. Inputs, including nested views, remain immutable for the entire call.
//! A versioned options record must expose its declared prefix, capped at the
//! known record size; a null options pointer selects defaults.
//!
//! Output pointers must address aligned, writable storage of the declared type,
//! disjoint from inputs and other outputs. An optional diagnostics output may be
//! null; otherwise it must be an empty writable handle slot. Reusing a slot or a
//! batch array does not release its previous owners: release those first.
//!
//! Every non-null opaque handle must have the correct type, originate from this
//! loaded library instance, and keep an owned reference alive throughout a call
//! or view read. Handles are immutable and reference counted. Each owned return
//! or retain requires one matching release; never free them with another
//! allocator. Borrowed views must not be mutated or used after the owner's last
//! release. Releasing other references concurrently is allowed while a reference
//! remains alive for each call or borrowed view. Keep the library mapped while
//! its handles, views, native workers, or thread-local destructors can use it.
use crate::{
    abi::*,
    diagnostics::Report,
    error::{discard_panic, panic_error, Error},
    handles::*,
    layout::metrics,
    scene::{PathStyle, SceneCommand, SceneContent, StrokeStyle},
};
use rayon::prelude::*;
use std::{
    mem::{align_of, size_of},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
    sync::Arc,
};

mod value;

fn owned<T>(value: T) -> *mut T {
    Arc::into_raw(Arc::new(value)).cast_mut()
}

unsafe fn required<'a, T>(value: *const T, label: &str) -> Result<&'a T, Error> {
    check_ptr(value, label)?;
    Ok(unsafe { &*value })
}
fn check_ptr<T>(value: *const T, label: &str) -> Result<(), Error> {
    if value.is_null() || !(value as usize).is_multiple_of(align_of::<T>()) {
        return Err(Error::invalid(format!(
            "{label} must be a non-null aligned pointer"
        )));
    }
    Ok(())
}
fn check_values<T>(data: *const T, len: usize, label: &str) -> Result<(), Error> {
    if len == 0 {
        return Ok(());
    }
    check_ptr(data, label)?;
    if len > isize::MAX as usize / size_of::<T>().max(1) {
        return Err(Error::invalid(format!("invalid {label} length")));
    }
    Ok(())
}
unsafe fn values<'a, T>(data: *const T, len: usize, label: &str) -> Result<&'a [T], Error> {
    if len == 0 {
        return Ok(&[]);
    }
    check_values(data, len, label)?;
    Ok(unsafe { std::slice::from_raw_parts(data, len) })
}
unsafe fn text<'a>(value: TypstStr, label: &str) -> Result<&'a str, Error> {
    let bytes = unsafe { values(value.data, value.len, label)? };
    std::str::from_utf8(bytes).map_err(|error| {
        Error::utf8(format!(
            "invalid UTF-8 in {label} at byte {}",
            error.valid_up_to()
        ))
    })
}

unsafe fn options<T: Copy + Default>(value: *const T) -> Result<T, Error> {
    if value.is_null() {
        return Ok(T::default());
    }
    check_ptr(value, "options")?;
    let length = unsafe { value.cast::<u32>().read() } as usize;
    if length != size_of::<u32>() && (length < 8 || !length.is_multiple_of(align_of::<T>())) {
        return Err(Error::invalid(
            "options.struct_size must contain its header and end at an aligned field boundary",
        ));
    }
    let mut result = T::default();
    unsafe {
        ptr::copy_nonoverlapping(
            value.cast::<u8>(),
            (&mut result as *mut T).cast::<u8>(),
            length.min(size_of::<T>()),
        );
    }
    Ok(result)
}

unsafe fn report(out: *mut *mut TypstDiagnostics, value: Report) {
    if !out.is_null() && !value.entries.is_empty() {
        unsafe {
            out.write(owned(TypstDiagnostics { inner: value }));
        }
    }
}

unsafe fn call(
    out: *mut *mut TypstDiagnostics,
    action: impl FnOnce() -> Result<Report, Error>,
) -> TypstStatus {
    if !out.is_null() {
        unsafe {
            out.write(ptr::null_mut());
        }
    }
    let result =
        catch_unwind(AssertUnwindSafe(action)).unwrap_or_else(|payload| Err(panic_error(payload)));
    match result {
        Ok(value) => {
            unsafe {
                report(out, value);
            }
            TYPST_OK
        }
        Err(error) => {
            unsafe {
                report(out, error.report);
            }
            error.status
        }
    }
}
unsafe fn output<T>(out: *mut *mut T) -> Result<(), Error> {
    if out.is_null() || !(out as usize).is_multiple_of(align_of::<*mut T>()) {
        return Err(Error::invalid(
            "output handle must be a non-null aligned pointer",
        ));
    }
    unsafe {
        out.write(ptr::null_mut());
    }
    Ok(())
}
unsafe fn retain<T>(value: *const T) {
    if !value.is_null() {
        unsafe {
            Arc::increment_strong_count(value);
        }
    }
}
unsafe fn release<T>(value: *const T) {
    if !value.is_null() {
        if let Err(payload) = catch_unwind(AssertUnwindSafe(|| unsafe {
            Arc::decrement_strong_count(value)
        })) {
            discard_panic(payload);
        }
    }
}

#[no_mangle]
pub extern "C" fn typst_abi_version() -> u32 {
    TYPST_ABI_VERSION
}

/// Returns the byte length of the first complete native content/code block.
/// Syntax errors inside a closed block are left to the eventual evaluation.
///
/// # Safety
/// `source` must be a readable view for the call and `out` a non-null writable
/// `usize`. The optional diagnostics slot follows the module pointer contract;
/// release any returned diagnostic with `typst_diagnostics_release`.
#[no_mangle]
pub unsafe extern "C" fn typst_source_block(
    source: TypstStr,
    out: *mut usize,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            check_ptr(out, "block length output")?;
            out.write(0);
            let length = crate::syntax::source_block(text(source, "Typst block")?)?;
            out.write(length);
            Ok(Report::default())
        })
    }
}

/// Finds where `source`, parsed in `syntax` mode (a TYPST_SYNTAX_* value), reads
/// members of the identifier `name`: each `name.member` in code, markup or math,
/// and each member listed in `import name: …`, in source order. A wildcard
/// import or other use of `name` as a whole value names no member; the view
/// reports it with TYPST_MEMBER_USES_WHOLE. Uses through another
/// value, as in `let m = name; m.x`, are not found. Syntax errors do not stop
/// the query. Available since ABI 1.8 with TYPST_CAP_MEMBER_USES.
///
/// # Safety
/// `source` and `name` must be readable views for the call. `out` must be a
/// non-null writable handle slot; release the handle with
/// `typst_member_uses_release`. The optional diagnostics slot follows the module
/// pointer contract.
#[no_mangle]
pub unsafe extern "C" fn typst_source_member_uses(
    source: TypstStr,
    syntax: u32,
    name: TypstStr,
    out: *mut *mut TypstMemberUses,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let mode = crate::syntax::syntax_mode(syntax)?;
            let uses = crate::syntax::member_uses(
                text(source, "source")?,
                mode,
                text(name, "member owner name")?,
            );
            out.write(owned(TypstMemberUses { inner: uses }));
            Ok(Report::default())
        })
    }
}

/// Borrows the uses a `typst_source_member_uses` handle found.
///
/// # Safety
/// `uses` must be live. `out` must point to aligned writable storage for one
/// `TypstMemberUseView`. Keep the handle alive for every access to the view.
#[no_mangle]
pub unsafe extern "C" fn typst_member_uses_view(
    uses: *const TypstMemberUses,
    out: *mut TypstMemberUseView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "member use output")?;
            out.write(TypstMemberUseView::default());
            let uses = &required(uses, "member uses")?.inner;
            let records = uses.records();
            out.write(TypstMemberUseView {
                uses: records.as_ptr(),
                use_count: records.len(),
                flags: uses.flags(),
                reserved: 0,
            });
            Ok(Report::default())
        })
    }
}

/// Releases a member-use handle; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a handle owned by the caller from this library.
#[no_mangle]
pub unsafe extern "C" fn typst_member_uses_release(value: *const TypstMemberUses) {
    unsafe { release(value) }
}

/// The returned strings are static and remain valid while the library is mapped.
///
/// # Safety
/// `out` must point to aligned, writable storage for one `TypstVersionInfo`.
/// Do not mutate the returned string views or use them after unloading the library.
#[no_mangle]
pub unsafe extern "C" fn typst_version_info(out: *mut TypstVersionInfo) -> TypstStatus {
    if check_ptr(out, "version output").is_err() {
        return TYPST_INVALID_ARGUMENT;
    }
    unsafe {
        out.write(TypstVersionInfo::default());
    }
    match catch_unwind(|| TypstVersionInfo {
        abi_major: TYPST_ABI_VERSION >> 16,
        abi_minor: TYPST_ABI_VERSION & 0xffff,
        capabilities: TYPST_CAP_PDF
            | TYPST_CAP_BATCH_LAYOUT
            | TYPST_CAP_NATIVE_SCENE
            | TYPST_CAP_TEXT_OUTLINE
            | TYPST_CAP_LAYOUT_BINDINGS
            | TYPST_CAP_PDF_IMPORT
            | TYPST_CAP_LAYOUT_TEMPLATES
            | TYPST_CAP_LAYOUT_LABELS
            | TYPST_CAP_BINDING_MODULES
            | TYPST_CAP_SHOW_VALUES
            | TYPST_CAP_MEMBER_USES
            | TYPST_CAP_MODULE_HANDLES
            | crate::context::FONT_DISCOVERY,
        library_version: TypstStr::view(env!("CARGO_PKG_VERSION")),
        typst_version: TypstStr::view(typst_core::utils::version().raw()),
    }) {
        Ok(value) => {
            unsafe {
                out.write(value);
            }
            TYPST_OK
        }
        Err(payload) => {
            discard_panic(payload);
            TYPST_PANIC
        }
    }
}

/// Creates an immutable context by copying the supplied resources and inputs.
///
/// # Safety
/// A non-null `config` and all nested arrays/views must follow the module pointer
/// contract. `out` must be a non-null writable handle slot; `diagnostics` may be
/// null or a writable handle slot. Release each returned owner with its matching
/// `typst_context_release` or `typst_diagnostics_release` function.
#[no_mangle]
pub unsafe extern "C" fn typst_context_create(
    config: *const TypstContextOptions,
    out: *mut *mut TypstContext,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let config: TypstContextOptions = options(config)?;
            if config.flags & !crate::context::CONTEXT_FLAGS != 0 {
                return Err(Error::unsupported("unknown context flags"));
            }
            let fonts = values(config.fonts, config.font_count, "fonts")?
                .iter()
                .map(|font| Ok(values(font.data.data, font.data.len, "font bytes")?.to_vec()))
                .collect::<Result<Vec<_>, Error>>()?;
            let font_dirs = values(config.font_dirs, config.font_dir_count, "font directories")?
                .iter()
                .map(|dir| Ok(std::path::PathBuf::from(text(*dir, "font directory")?)))
                .collect::<Result<Vec<_>, Error>>()?;
            let files = values(config.files, config.file_count, "files")?
                .iter()
                .map(|file| {
                    Ok((
                        text(file.path, "file path")?.to_owned(),
                        values(file.data.data, file.data.len, "file bytes")?.to_vec(),
                    ))
                })
                .collect::<Result<Vec<_>, Error>>()?;
            let inputs = text(config.inputs_json, "inputs JSON")?;
            let context =
                crate::context::Context::new(fonts, font_dirs, files, inputs, config.flags)?;
            out.write(owned(TypstContext { inner: context }));
            Ok(Report::default())
        })
    }
}

/// Compiles an in-memory source into an independently owned document.
///
/// # Safety
/// `context` must be a live context from this library. Both source views and the
/// non-null writable `out` slot must follow the module pointer contract.
/// `diagnostics` is optional. Release the returned document and diagnostic owners
/// separately; the document may outlive the context.
#[no_mangle]
pub unsafe extern "C" fn typst_context_compile(
    context: *const TypstContext,
    source: TypstStr,
    source_name: TypstStr,
    out: *mut *mut TypstDocument,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let context = required(context, "context")?;
            let (document, warnings) = context
                .inner
                .compile(text(source, "source")?, text(source_name, "source name")?)?;
            out.write(owned(TypstDocument { inner: document }));
            Ok(warnings)
        })
    }
}

// C views remain valid until the synchronous call, including its parallel
// jobs, returns. Typst's Source trees and returned diagnostics own their data.
struct Request<'a> {
    source: &'a str,
    source_name: &'a str,
    setup_code: &'a str,
    setup_source_name: &'a str,
    bindings: typst_core::foundations::Scope,
    templates: Vec<crate::layout::TemplateSource<'a>>,
    /// Sources of the evaluated modules behind the request's handles.
    retained: Vec<typst_core::syntax::Source>,
    shows: Vec<typst_core::foundations::Value>,
    /// Warnings raised while the request's templates were made.
    warnings: Report,
    flags: u32,
    width_pt: f64,
    height_pt: f64,
    syntax: u32,
    reserved: u32,
}
impl Request<'_> {
    fn options(&self) -> TypstLayoutOptions {
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
unsafe fn module_handles(
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

/// Evaluates `source` like an imported file and retains the resulting module:
/// the file's top-level definitions become the members of a module named by
/// the source name's file stem, and the content it produces is kept with the
/// module, unused. List the handle in the `module_handles` of layout or later
/// evaluation options, where TYPST_VALUE_MODULE_HANDLE inputs refer to it;
/// the source is not evaluated again. The module owns its values and the
/// source text that diagnostics raised later inside its functions refer to, so
/// it can outlive `context`, the options and the handles it was made with.
/// A source name must be nonempty and differ from those of the requests,
/// templates and other handles the module is used with. Warnings are
/// returned with success. Available since ABI 1.8 with
/// TYPST_CAP_MODULE_HANDLES.
///
/// # Safety
/// `context` must be live. Both source views must follow the module pointer
/// contract, and so must `config` unless it is null, which selects defaults,
/// with its nested views and live module handles. `out` must be a non-null
/// writable handle slot; `diagnostics` is optional. Release the returned
/// module with `typst_module_release` and any diagnostic owner separately.
#[no_mangle]
pub unsafe extern "C" fn typst_context_eval(
    context: *const TypstContext,
    source: TypstStr,
    source_name: TypstStr,
    config: *const TypstEvalOptions,
    out: *mut *mut TypstModule,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let context = required(context, "context")?;
            let source_name = text(source_name, "source name")?;
            let attribute = |error: Error| error.with_source(source_name);
            if source_name.is_empty() {
                return Err(Error::invalid("module source name must not be empty"));
            }
            let config: TypstEvalOptions = options(config).map_err(attribute)?;
            if config.flags != 0 {
                return Err(attribute(Error::unsupported("unknown evaluation flags")));
            }
            let (handles, retained) =
                module_handles(config.module_handles, config.module_handle_count)
                    .map_err(attribute)?;
            let references = self::value::References {
                handles: &handles,
                ..Default::default()
            };
            let bindings = self::value::bindings(config.bindings, config.binding_count, references)
                .map_err(attribute)?;
            let module = crate::layout::ModuleSource {
                code: text(source, "source").map_err(attribute)?,
                source_name,
            };
            let (module, warnings) = context
                .inner
                .module(module, bindings, &retained)
                .map_err(attribute)?;
            out.write(owned(TypstModule { inner: module }));
            Ok(warnings)
        })
    }
}

/// The modules of the handles exist already. Template functions are made
/// next, so that bindings and show rules can refer to both by index.
unsafe fn request<'a>(
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
        let references = self::value::References {
            templates: &functions,
            handles: &handles,
        };
        let bindings =
            unsafe { self::value::bindings(record.bindings, record.binding_count, references) }
                .map_err(attribute)?;
        let (function, report) = context.template(template, bindings, &retained)?;
        warnings.merge(report);
        templates.push(template);
        functions.push(function);
    }
    let references = self::value::References {
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
        let mut rule = unsafe { self::value::value(input, references) }.map_err(attribute)?;
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
        bindings: unsafe {
            self::value::bindings(options.bindings, options.binding_count, references)
        }
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

/// Lays out one request into an independently owned native layout.
///
/// # Safety
/// `context` must be live and `input` must point to one initialized request, with
/// readable source/setup views and an optional valid options prefix. `out` must
/// be a non-null writable handle slot. All pointers follow the module contract.
/// Release returned layout and optional diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_context_layout(
    context: *const TypstContext,
    input: *const TypstLayoutRequest,
    out: *mut *mut TypstLayout,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let context = required(context, "context")?;
            let input = request(&context.inner, required(input, "layout request")?)?;
            let prepared = crate::layout::Prepared {
                templates: &input.templates,
                retained: &input.retained,
                shows: &input.shows,
            };
            let (layout, warnings) = context
                .inner
                .layout_with_setup(
                    input.source,
                    input.source_name,
                    &input.options(),
                    input.setup_code,
                    input.setup_source_name,
                    input.bindings,
                    prepared,
                    usize::MAX,
                )
                .map_err(|error| error.with_source(input.source_name))?;
            out.write(owned(TypstLayout { inner: layout }));
            let mut report = input.warnings;
            report.merge(warnings);
            Ok(report)
        })
    }
}

/// Processes independent requests in parallel and publishes results in input
/// order. Global success means all requests were processed; inspect each result
/// status. Every result owns its layout and diagnostics, including mixed errors.
/// A global argument error starts no work and initializes the result slots when
/// their pointer and count are valid. All input memory is borrowed for this call.
///
/// # Safety
/// `context` must be live. For nonzero `count`, `inputs` must expose that many
/// initialized requests, including their nested views/options, and `outputs`
/// must expose that many aligned writable result slots. Their storage and the
/// optional diagnostic slot must be disjoint and follow the module contract.
/// Release every populated result layout/diagnostic and the global diagnostic
/// independently, including on failure; the caller owns the output array itself.
#[no_mangle]
pub unsafe extern "C" fn typst_context_layout_many(
    context: *const TypstContext,
    inputs: *const TypstLayoutRequest,
    count: usize,
    outputs: *mut TypstLayoutResult,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            check_values(outputs.cast_const(), count, "layout results")?;
            for index in 0..count {
                outputs.add(index).write(TypstLayoutResult::default());
            }
            let context = required(context, "context")?;
            let requests = values(inputs, count, "layout requests")?
                .iter()
                .map(|value| request(&context.inner, value))
                .collect::<Vec<_>>();
            let outcomes = requests
                .into_par_iter()
                .enumerate()
                .map(|(index, input)| {
                    catch_unwind(AssertUnwindSafe(|| {
                        let input = input?;
                        let prepared = crate::layout::Prepared {
                            templates: &input.templates,
                            retained: &input.retained,
                            shows: &input.shows,
                        };
                        let (layout, warnings) = context
                            .inner
                            .layout_with_setup(
                                input.source,
                                input.source_name,
                                &input.options(),
                                input.setup_code,
                                input.setup_source_name,
                                input.bindings,
                                prepared,
                                index,
                            )
                            .map_err(|error| error.with_source(input.source_name))?;
                        let mut report = input.warnings;
                        report.merge(warnings);
                        Ok((layout, report))
                    }))
                    .unwrap_or_else(|payload| Err(panic_error(payload)))
                })
                .collect::<Vec<_>>();
            for (index, result) in outcomes.into_iter().enumerate() {
                let result = match result {
                    Ok((layout, report)) => TypstLayoutResult {
                        status: TYPST_OK,
                        reserved: 0,
                        layout: owned(TypstLayout { inner: layout }),
                        diagnostics: if report.entries.is_empty() {
                            ptr::null_mut()
                        } else {
                            owned(TypstDiagnostics {
                                inner: report.with_request(index),
                            })
                        },
                    },
                    Err(error) => TypstLayoutResult {
                        status: error.status,
                        reserved: 0,
                        layout: ptr::null_mut(),
                        diagnostics: owned(TypstDiagnostics {
                            inner: error.report.with_request(index),
                        }),
                    },
                };
                outputs.add(index).write(result);
            }
            Ok(Report::default())
        })
    }
}

/// Reads the dimensions and baseline of a layout.
///
/// # Safety
/// `layout` must be a live layout from this library and `out` must point to one
/// aligned writable `TypstMetrics`, disjoint from the borrowed layout.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_metrics(
    layout: *const TypstLayout,
    out: *mut TypstMetrics,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "metrics output")?;
            out.write(TypstMetrics::default());
            let layout = required(layout, "layout")?;
            out.write(layout.inner.metrics());
            Ok(Report::default())
        })
    }
}

/// Reads conservative bounds in frame-local, y-down points, including logical
/// dimensions and painted overflow. Clips may make the visible extent smaller.
/// Native text, strokes and images remain native; no outline extraction occurs.
/// Available since ABI 1.1.
///
/// # Safety
/// `layout` must be live. `out` must hold two aligned writable `TypstPoint`s,
/// disjoint from the layout, receiving the minimum and maximum respectively.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_bounds(
    layout: *const TypstLayout,
    out: *mut TypstPoint,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "bounds output")?;
            out.write(TypstPoint::default());
            out.add(1).write(TypstPoint::default());
            let bounds = required(layout, "layout")?.inner.bounds()?;
            ptr::copy_nonoverlapping(bounds.as_ptr(), out, bounds.len());
            Ok(Report::default())
        })
    }
}

/// Borrows every labeled element of a layout, read from the start and end tags
/// Typst places around content that carries a label. Elements appear in
/// document order, a label as often as it occurs. Records are made on the
/// first call and live as long as the layout. Available since ABI 1.6.
///
/// # Safety
/// `layout` must be live. `out` must point to aligned writable storage for one
/// `TypstLabelView`, disjoint from the layout. Keep a layout reference alive
/// for every access to the returned view; do not mutate or free it.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_labels(
    layout: *const TypstLayout,
    out: *mut TypstLabelView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "labels output")?;
            out.write(TypstLabelView::default());
            let elements = required(layout, "layout")?.inner.labels()?;
            out.write(TypstLabelView {
                elements: elements.as_ptr(),
                element_count: elements.len(),
            });
            Ok(Report::default())
        })
    }
}

/// Returns the number of pages, or zero for a null document.
///
/// # Safety
/// A non-null `document` must be a live document from this library, with an owned
/// reference kept alive throughout the call.
#[no_mangle]
pub unsafe extern "C" fn typst_document_page_count(document: *const TypstDocument) -> usize {
    if document.is_null() {
        0
    } else {
        let document = unsafe { &*document };
        document.inner.document.pages().len()
    }
}

/// Reads page dimensions and baseline; out-of-range indices return an error.
///
/// # Safety
/// `document` must be live and `out` must point to aligned writable storage for
/// one `TypstMetrics`, disjoint from the document, for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn typst_document_page_metrics(
    document: *const TypstDocument,
    page: usize,
    out: *mut TypstMetrics,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "metrics output")?;
            out.write(TypstMetrics::default());
            let document = required(document, "document")?;
            let page = document
                .inner
                .document
                .pages()
                .get(page)
                .ok_or_else(|| Error::range("page index is out of range"))?;
            out.write(metrics(&page.frame));
            Ok(Report::default())
        })
    }
}

unsafe fn pdf_standard<'a>(config: *const TypstPdfOptions) -> Result<Option<&'a str>, Error> {
    let config: TypstPdfOptions = unsafe { options(config)? };
    if config.flags != 0 {
        return Err(Error::unsupported("unknown PDF flags"));
    }
    let standard = unsafe { text(config.standard, "PDF standard")? };
    Ok((!standard.is_empty()).then_some(standard))
}

/// Exports one document page into an independently owned SVG buffer.
///
/// # Safety
/// `document` must be live. `out` must be a non-null writable buffer slot, and
/// the optional diagnostics slot must follow the module pointer contract.
/// Release the returned buffer and diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_document_export_svg(
    document: *const TypstDocument,
    page: usize,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let document = required(document, "document")?;
            let bytes = crate::export::svg(&document.inner.document, page)?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}
/// Exports a document into an independently owned PDF buffer.
///
/// # Safety
/// `document` must be live. A non-null `config`, its declared options prefix and
/// its standard-name view must remain readable for the call. `out` and the
/// optional diagnostic slot follow the module pointer contract. Release the
/// returned buffer and diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_document_export_pdf(
    document: *const TypstDocument,
    config: *const TypstPdfOptions,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let document = required(document, "document")?;
            let bytes = crate::export::pdf(&document.inner.document, pdf_standard(config)?)?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}
/// Exports an independent layout into an owned SVG buffer.
///
/// # Safety
/// `layout` must be live. `out` must be a non-null writable buffer slot, and the
/// optional diagnostics slot must follow the module pointer contract. Release
/// the returned buffer and diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_export_svg(
    layout: *const TypstLayout,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let layout = required(layout, "layout")?;
            let page = crate::export::page_from_frame(layout.inner.frame.clone());
            let bytes = typst_svg::svg(&page, &typst_svg::SvgOptions::default()).into_bytes();
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}
/// Exports an independent layout into an owned PDF buffer.
///
/// # Safety
/// `layout` must be live. A non-null `config` and its nested standard-name view
/// must follow the module options contract. `out` must be a non-null writable
/// buffer slot; `diagnostics` is optional. Release both returned owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_export_pdf(
    layout: *const TypstLayout,
    config: *const TypstPdfOptions,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let layout = required(layout, "layout")?;
            let bytes = crate::export::pdf(
                &crate::export::from_frame(&layout.inner.frame),
                pdf_standard(config)?,
            )?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}

unsafe fn path<'a>(value: *const TypstPath) -> Result<&'a [TypstPathSegment], Error> {
    let value = unsafe { required(value, "path")? };
    unsafe { values(value.segments, value.segment_count, "path segments") }
}
unsafe fn style<'a>(value: *const TypstStyle) -> Result<PathStyle<'a>, Error> {
    let value = unsafe { required(value, "path style")? };
    if value.flags & !(TYPST_STYLE_FILL | TYPST_STYLE_STROKE) != 0 {
        return Err(Error::unsupported("unknown path style flags"));
    }
    let stroke = if value.flags & TYPST_STYLE_STROKE != 0 {
        Some(StrokeStyle {
            color: value.stroke,
            width_pt: value.stroke_width_pt,
            line_cap: value.line_cap,
            line_join: value.line_join,
            miter_limit: value.miter_limit,
            dashes: unsafe { values(value.dashes, value.dash_count, "stroke dashes")? },
            dash_phase_pt: value.dash_phase_pt,
        })
    } else {
        None
    };
    Ok(PathStyle {
        fill: (value.flags & TYPST_STYLE_FILL != 0).then_some(value.fill),
        fill_rule: value.fill_rule,
        fill_gradient: None,
        stroke_gradient: None,
        stroke,
    })
}

/// Imports a zero-based PDF page into a reusable native scene, at its natural
/// page dimensions in points. Copies the input bytes; the scene can outlive them.
/// The context only supplies the environment for Typst's decoder: the result
/// does not depend on its fonts, files or inputs, so any live context will do.
/// PDF output uses Typst's native PDF embedding, including its format restrictions.
///
/// # Safety
/// `context` is borrowed for this call. `data` follows the module pointer contract. `out` must be a writable scene
/// slot; `diagnostics` is optional. Release the scene and diagnostics separately.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_from_pdf(
    context: *const TypstContext,
    data: TypstBytes,
    page: usize,
    out: *mut *mut TypstScene,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let (inner, report) = crate::scene::Scene::from_pdf(
                &required(context, "context")?.inner,
                values(data.data, data.len, "PDF data")?,
                page,
            )?;
            out.write(owned(TypstScene { inner }));
            Ok(report)
        })
    }
}

/// Copies native scene commands and retains referenced layouts/nested scenes.
///
/// # Safety
/// A non-null `config`, its declared prefix, items, paths, styles, dash arrays,
/// clips and option views must follow the module pointer contract. Referenced
/// layout/scene handles must be live and originate from this library. `out` must
/// be a non-null writable scene slot; `diagnostics` is optional. Release both
/// returned owners separately; the scene may outlive its input handles/views.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_create(
    config: *const TypstSceneOptions,
    out: *mut *mut TypstScene,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let config: TypstSceneOptions = options(config)?;
            if config.flags != 0 {
                return Err(Error::unsupported("unknown scene flags"));
            }
            let commands = values(config.items, config.item_count, "scene items")?
                .iter()
                .map(|item| {
                    if item.reserved != 0 {
                        return Err(Error::invalid("scene item reserved field must be zero"));
                    }
                    let item_options: TypstSceneItemOptions = options(item.options)?;
                    if (!item_options.fill_gradient.is_null()
                        || !item_options.stroke_gradient.is_null())
                        && item.kind != TYPST_ITEM_PATH
                    {
                        return Err(Error::invalid("gradient paint requires a path"));
                    }
                    let content = match item.kind {
                        TYPST_ITEM_PATH if item.layout.is_null() && item.scene.is_null() => {
                            let mut style = style(item.style)?;
                            let gradient = |view: *const TypstGradient| {
                                if view.is_null() {
                                    return Ok(None);
                                }
                                let g = required(view, "gradient")?;
                                if g.reserved != 0 {
                                    return Err(Error::invalid(
                                        "gradient reserved field must be zero",
                                    ));
                                }
                                crate::scene::gradient(
                                    g,
                                    values(g.colors, g.count, "gradient colors")?,
                                )
                                .map(Some)
                            };
                            style.fill_gradient = gradient(item_options.fill_gradient)?;
                            style.stroke_gradient = gradient(item_options.stroke_gradient)?;
                            SceneContent::Path {
                                segments: path(item.path)?,
                                style,
                            }
                        }
                        TYPST_ITEM_LAYOUT
                            if item.path.is_null()
                                && item.scene.is_null()
                                && item.style.is_null() =>
                        {
                            SceneContent::Frame(&required(item.layout, "item layout")?.inner.frame)
                        }
                        TYPST_ITEM_SCENE
                            if item.path.is_null()
                                && item.layout.is_null()
                                && item.style.is_null() =>
                        {
                            SceneContent::Frame(&required(item.scene, "nested scene")?.inner.frame)
                        }
                        _ => {
                            return Err(Error::invalid(
                                "scene item must select one supported content kind",
                            ))
                        }
                    };
                    if item_options.flags & !TYPST_SCENE_ITEM_ISOLATE_TRANSFORM != 0 {
                        return Err(Error::unsupported("unknown scene item flags"));
                    }
                    let tag = text(item_options.tag, "scene item tag")?;
                    Ok(SceneCommand {
                        content,
                        transform: item.transform,
                        clip: if item.clip.is_null() {
                            None
                        } else {
                            Some(path(item.clip)?)
                        },
                        tag: (!tag.is_empty()).then_some(tag),
                        isolate_transform: item_options.flags & TYPST_SCENE_ITEM_ISOLATE_TRANSFORM
                            != 0,
                    })
                })
                .collect::<Result<Vec<_>, Error>>()?;
            let scene = crate::scene::Scene::new(config.width_pt, config.height_pt, commands)?;
            out.write(owned(TypstScene { inner: scene }));
            Ok(Report::default())
        })
    }
}
/// Reads scene dimensions and baseline.
///
/// # Safety
/// `scene` must be live and `out` must point to one aligned writable
/// `TypstMetrics`, disjoint from the scene, for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_metrics(
    scene: *const TypstScene,
    out: *mut TypstMetrics,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "metrics output")?;
            out.write(TypstMetrics::default());
            let scene = required(scene, "scene")?;
            out.write(metrics(&scene.inner.frame));
            Ok(Report::default())
        })
    }
}
/// Exports a scene into an independently owned SVG buffer.
///
/// # Safety
/// `scene` must be live. `out` must be a non-null writable buffer slot, and the
/// optional diagnostic slot must follow the module pointer contract. Release
/// returned buffer and diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_export_svg(
    scene: *const TypstScene,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let scene = required(scene, "scene")?;
            let page = crate::export::page_from_frame(scene.inner.frame.clone());
            let bytes = typst_svg::svg(&page, &typst_svg::SvgOptions::default()).into_bytes();
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}
/// Exports a scene into an independently owned PDF buffer.
///
/// # Safety
/// `scene` must be live. A non-null `config` and its nested standard-name view
/// must follow the module options contract. `out` must be a non-null writable
/// buffer slot; `diagnostics` is optional. Release both returned owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_export_pdf(
    scene: *const TypstScene,
    config: *const TypstPdfOptions,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let scene = required(scene, "scene")?;
            let bytes = crate::export::pdf(
                &crate::export::from_frame(&scene.inner.frame),
                pdf_standard(config)?,
            )?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}

/// Extracts optional editable outlines into an independently owned object.
///
/// # Safety
/// `layout` must be live. `out` must be a non-null writable outline slot, and the
/// optional diagnostic slot must follow the module pointer contract. Release
/// the returned outline and diagnostic owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_outline(
    layout: *const TypstLayout,
    out: *mut *mut TypstOutline,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let layout = required(layout, "layout")?;
            let outline = crate::outline::extract(&layout.inner)?;
            out.write(owned(TypstOutline { inner: outline }));
            Ok(Report::default())
        })
    }
}
/// Borrows the outline's immutable path, segment and dash arrays.
///
/// # Safety
/// `outline` must be live and `out` must point to aligned writable storage for
/// one `TypstOutlineView`, disjoint from the outline. Keep an outline reference
/// alive for every access to the returned views; do not mutate or free them.
#[no_mangle]
pub unsafe extern "C" fn typst_outline_view(
    outline: *const TypstOutline,
    out: *mut TypstOutlineView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "outline output")?;
            out.write(TypstOutlineView {
                paths: ptr::null(),
                path_count: 0,
                segments: ptr::null(),
                segment_count: 0,
                dashes: ptr::null(),
                dash_count: 0,
                run_count: 0,
            });
            let outline = required(outline, "outline")?;
            out.write(TypstOutlineView {
                paths: outline.inner.paths.as_ptr(),
                path_count: outline.inner.paths.len(),
                segments: outline.inner.segments.as_ptr(),
                segment_count: outline.inner.segments.len(),
                dashes: outline.inner.dashes.as_ptr(),
                dash_count: outline.inner.dashes.len(),
                run_count: outline.inner.run_count(),
            });
            Ok(Report::default())
        })
    }
}

/// The view borrows the buffer and remains valid until its last release.
///
/// # Safety
/// A non-null `buffer` must be a live buffer from this library. Keep an owned
/// reference alive while reading the immutable byte view; do not free its data.
/// A null buffer returns an empty view.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_data(buffer: *const TypstBuffer) -> TypstBytes {
    if buffer.is_null() {
        TypstBytes::default()
    } else {
        let buffer = unsafe { &*buffer };
        TypstBytes {
            data: buffer.inner.as_ptr(),
            len: buffer.inner.len(),
        }
    }
}
/// Returns the number of primary diagnostics, or zero for a null report.
///
/// # Safety
/// A non-null `diagnostics` must be a live report from this library, with an
/// owned reference kept alive throughout the call.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_count(diagnostics: *const TypstDiagnostics) -> usize {
    if diagnostics.is_null() {
        0
    } else {
        let diagnostics = unsafe { &*diagnostics };
        diagnostics.inner.entries.len()
    }
}
/// Borrows a primary diagnostic; out-of-range indices return an error.
///
/// # Safety
/// `diagnostics` must be live and `out` must point to aligned writable storage
/// for one `TypstDiagnosticView`, disjoint from the report. Returned strings
/// remain borrowed: keep the report alive and do not mutate or free their data.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_get(
    diagnostics: *const TypstDiagnostics,
    index: usize,
    out: *mut TypstDiagnosticView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "diagnostic output")?;
            out.write(TypstDiagnosticView::default());
            let diagnostics = required(diagnostics, "diagnostics")?;
            let entry = diagnostics
                .inner
                .entries
                .get(index)
                .ok_or_else(|| Error::range("diagnostic index is out of range"))?;
            out.write(entry.view());
            Ok(Report::default())
        })
    }
}
/// Borrows a diagnostic hint or trace note; invalid indices return an error.
///
/// # Safety
/// `diagnostics` must be live and `out` must point to aligned writable storage
/// for one `TypstDiagnosticView`, disjoint from the report. Returned strings
/// remain borrowed: keep the report alive and do not mutate or free their data.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_get_note(
    diagnostics: *const TypstDiagnostics,
    index: usize,
    note: usize,
    out: *mut TypstDiagnosticView,
) -> TypstStatus {
    unsafe {
        call(ptr::null_mut(), || {
            check_ptr(out, "note output")?;
            out.write(TypstDiagnosticView::default());
            let diagnostics = required(diagnostics, "diagnostics")?;
            let entry = diagnostics
                .inner
                .entries
                .get(index)
                .and_then(|entry| entry.notes.get(note))
                .ok_or_else(|| Error::range("diagnostic note index is out of range"))?;
            out.write(entry.view());
            Ok(Report::default())
        })
    }
}

/// Evict upstream process-wide memoization entries older than max_age epochs.
/// This does not release live layouts, scenes, fonts, documents or buffers.
#[no_mangle]
pub extern "C" fn typst_cache_evict(max_age: u32) -> TypstStatus {
    match catch_unwind(|| comemo::evict(max_age as usize)) {
        Ok(()) => TYPST_OK,
        Err(payload) => {
            discard_panic(payload);
            TYPST_PANIC
        }
    }
}

/// Acquires one additional context reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live context from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_context_retain(value: *const TypstContext) {
    unsafe { retain(value) }
}
/// Releases one owned context reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a context reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_context_release(value: *const TypstContext) {
    unsafe { release(value) }
}
/// Acquires one additional layout reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live layout from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_retain(value: *const TypstLayout) {
    unsafe { retain(value) }
}
/// Releases one owned layout reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a layout reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_layout_release(value: *const TypstLayout) {
    unsafe { release(value) }
}
/// Acquires one additional document reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live document from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_document_retain(value: *const TypstDocument) {
    unsafe { retain(value) }
}
/// Releases one owned document reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a document reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_document_release(value: *const TypstDocument) {
    unsafe { release(value) }
}
/// Acquires one additional scene reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live scene from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_retain(value: *const TypstScene) {
    unsafe { retain(value) }
}
/// Releases one owned scene reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a scene reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_scene_release(value: *const TypstScene) {
    unsafe { release(value) }
}
/// Acquires one additional outline reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live outline from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_outline_retain(value: *const TypstOutline) {
    unsafe { retain(value) }
}
/// Releases one owned outline reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be an outline reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_outline_release(value: *const TypstOutline) {
    unsafe { release(value) }
}
/// Acquires one additional buffer reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live buffer from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_retain(value: *const TypstBuffer) {
    unsafe { retain(value) }
}
/// Releases one owned buffer reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a buffer reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_buffer_release(value: *const TypstBuffer) {
    unsafe { release(value) }
}
/// Acquires one additional diagnostic report reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live report from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_retain(value: *const TypstDiagnostics) {
    unsafe { retain(value) }
}
/// Releases one owned diagnostic report reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a report reference owned by the caller from this
/// library. This consumes that reference; keep another owner for any live views.
#[no_mangle]
pub unsafe extern "C" fn typst_diagnostics_release(value: *const TypstDiagnostics) {
    unsafe { release(value) }
}
/// Acquires one additional module reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a live module from this library, with an existing
/// reference held through the call. Release the new reference exactly once.
#[no_mangle]
pub unsafe extern "C" fn typst_module_retain(value: *const TypstModule) {
    unsafe { retain(value) }
}
/// Releases one owned module reference; null is a no-op.
///
/// # Safety
/// A non-null `value` must be a module reference owned by the caller from this
/// library. This consumes that reference; do not reuse it without another owner.
#[no_mangle]
pub unsafe extern "C" fn typst_module_release(value: *const TypstModule) {
    unsafe { release(value) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_and_diagnostics_outlive_borrowed_request_text() {
        unsafe {
            let mut context = ptr::null_mut();
            assert_eq!(
                typst_context_create(ptr::null(), &mut context, ptr::null_mut()),
                TYPST_OK
            );
            let results = {
                let sources = [String::from("#title"), String::from("#missing_name")];
                let names = [String::from("good.typ"), String::from("bad.typ")];
                let setup = String::from("let title = [Retained Ω]");
                let setup_name = String::from("shared-setup.typ");
                let options = TypstLayoutOptions {
                    setup_code: TypstStr::view(&setup),
                    setup_source_name: TypstStr::view(&setup_name),
                    ..Default::default()
                };
                let inputs = std::array::from_fn::<_, 2, _>(|index| TypstLayoutRequest {
                    source: TypstStr::view(&sources[index]),
                    source_name: TypstStr::view(&names[index]),
                    options: &options,
                });
                let mut results = [TypstLayoutResult::default(); 2];
                assert_eq!(
                    typst_context_layout_many(
                        context,
                        inputs.as_ptr(),
                        inputs.len(),
                        results.as_mut_ptr(),
                        ptr::null_mut(),
                    ),
                    TYPST_OK
                );
                results
            };
            typst_context_release(context);

            assert_eq!(results[0].status, TYPST_OK);
            assert_eq!(results[1].status, TYPST_COMPILE_FAILED);
            let mut metrics = TypstMetrics::default();
            assert_eq!(
                typst_layout_metrics(results[0].layout, &mut metrics),
                TYPST_OK
            );
            assert!(metrics.width_pt > 0.0);
            let mut svg = ptr::null_mut();
            assert_eq!(
                typst_layout_export_svg(results[0].layout, &mut svg, ptr::null_mut()),
                TYPST_OK
            );
            assert!((*svg).inner.starts_with(b"<svg"));
            assert!((*results[1].diagnostics)
                .inner
                .entries
                .iter()
                .any(|entry| entry.source_name == "/bad.typ"
                    && entry.message.contains("missing_name")
                    && entry.request_index == 1));
            typst_buffer_release(svg);
            for result in results {
                typst_layout_release(result.layout);
                typst_diagnostics_release(result.diagnostics);
            }
        }
    }

    #[test]
    fn native_scene_owns_path_clip_and_dash_inputs_after_create_returns() {
        unsafe {
            let (scene, before) = {
                let mut segments = vec![
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_MOVE,
                        p1: TypstPoint { x: 2.0, y: 3.0 },
                        ..Default::default()
                    },
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_CUBIC,
                        p1: TypstPoint { x: 8.0, y: 1.0 },
                        p2: TypstPoint { x: 15.0, y: 21.0 },
                        p3: TypstPoint { x: 25.0, y: 13.0 },
                        ..Default::default()
                    },
                ];
                let mut clip_segments = vec![
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_MOVE,
                        ..Default::default()
                    },
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_LINE,
                        p1: TypstPoint { x: 30.0, y: 0.0 },
                        ..Default::default()
                    },
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_LINE,
                        p1: TypstPoint { x: 30.0, y: 25.0 },
                        ..Default::default()
                    },
                    TypstPathSegment {
                        kind: TYPST_SEGMENT_CLOSE,
                        ..Default::default()
                    },
                ];
                let mut dashes = vec![3.0, 1.0];
                let path = TypstPath {
                    segments: segments.as_ptr(),
                    segment_count: segments.len(),
                };
                let clip = TypstPath {
                    segments: clip_segments.as_ptr(),
                    segment_count: clip_segments.len(),
                };
                let style = TypstStyle {
                    flags: TYPST_STYLE_STROKE,
                    fill_rule: TYPST_FILL_NONZERO,
                    fill: TypstColor::default(),
                    stroke: TypstColor {
                        r: 0.1,
                        g: 0.2,
                        b: 0.3,
                        a: 1.0,
                    },
                    stroke_width_pt: 2.5,
                    line_cap: TYPST_CAP_ROUND,
                    line_join: TYPST_JOIN_BEVEL,
                    miter_limit: 7.0,
                    dashes: dashes.as_ptr(),
                    dash_count: dashes.len(),
                    dash_phase_pt: 0.5,
                };
                let item = TypstSceneItem {
                    kind: TYPST_ITEM_PATH,
                    reserved: 0,
                    transform: TypstTransform::default(),
                    path: &path,
                    style: &style,
                    layout: ptr::null(),
                    scene: ptr::null(),
                    clip: &clip,
                    options: ptr::null(),
                };
                let options = TypstSceneOptions {
                    width_pt: 50.0,
                    height_pt: 30.0,
                    items: &item,
                    item_count: 1,
                    ..Default::default()
                };
                let mut scene = ptr::null_mut();
                assert_eq!(
                    typst_scene_create(&options, &mut scene, ptr::null_mut()),
                    TYPST_OK
                );
                let mut before = ptr::null_mut();
                assert_eq!(
                    typst_scene_export_svg(scene, &mut before, ptr::null_mut()),
                    TYPST_OK
                );

                segments.fill(TypstPathSegment::default());
                clip_segments.fill(TypstPathSegment::default());
                dashes.fill(f64::NAN);
                // All caller-owned arrays and input records drop at this boundary.
                (scene, before)
            };
            let mut after = ptr::null_mut();
            assert_eq!(
                typst_scene_export_svg(scene, &mut after, ptr::null_mut()),
                TYPST_OK
            );
            assert_eq!((*before).inner, (*after).inner);
            assert!((*after).inner.starts_with(b"<svg"));
            for expected in [b"stroke-dasharray".as_slice(), b"clip-path".as_slice()] {
                assert!((*after)
                    .inner
                    .windows(expected.len())
                    .any(|part| part == expected));
            }
            let mut pdf = ptr::null_mut();
            assert_eq!(
                typst_scene_export_pdf(scene, ptr::null(), &mut pdf, ptr::null_mut()),
                TYPST_OK
            );
            assert!((*pdf).inner.starts_with(b"%PDF-"));
            typst_buffer_release(before);
            typst_buffer_release(after);
            typst_buffer_release(pdf);
            typst_scene_release(scene);
        }
    }

    #[test]
    fn panic_stays_inside_the_ffi_call_and_has_an_owned_diagnostic() {
        let mut diagnostic = ptr::null_mut();
        let status = unsafe {
            call(&mut diagnostic, || {
                panic!("panic payload with unicode Ω and NUL \0")
            })
        };
        assert_eq!(status, TYPST_PANIC);
        assert!(!diagnostic.is_null());
        let owner = unsafe { &*diagnostic };
        let entry = &owner.inner.entries[0];
        assert!(entry.message.contains("Ω and NUL \0"));
        unsafe {
            typst_diagnostics_release(diagnostic);
        }
    }
    #[test]
    fn invalid_views_and_partial_options_are_rejected_before_borrowing() {
        assert!(unsafe { values::<u64>(ptr::null(), 1, "test") }.is_err());
        assert!(unsafe { values::<u64>(ptr::dangling(), usize::MAX, "test") }.is_err());
        let header = [9u32, 0];
        assert!(unsafe { options::<TypstContextOptions>(header.as_ptr().cast()) }.is_err());
        assert!(unsafe {
            text(
                TypstStr {
                    data: [0xff].as_ptr(),
                    len: 1,
                },
                "test",
            )
        }
        .is_err());
    }
}
