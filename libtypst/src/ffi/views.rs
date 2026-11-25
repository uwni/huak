//! Views over result handles: outlines, buffers and diagnostics.
use super::*;

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
