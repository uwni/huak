//! Creating contexts, compiling documents and evaluating modules.
use super::request::module_handles;
use super::*;

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
            let references = value::References {
                handles: &handles,
                ..Default::default()
            };
            let bindings = value::bindings(config.bindings, config.binding_count, references)
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
