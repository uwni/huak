//! Entry points that need no context: the ABI version and capabilities, cache eviction, and source queries.
use super::*;

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
            | TYPST_CAP_PDF_CREATOR
            | TYPST_CAP_GRADIENT_STOPS
            | TYPST_CAP_PDF_PAGE_OPACITY
            | TYPST_CAP_RASTER_IMAGE
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
