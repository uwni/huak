//! Pages of a finished document, and SVG and PDF export of documents, layouts and scenes.
use super::*;

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

unsafe fn export_pdf(
    document: &typst_layout::PagedDocument,
    config: *const TypstPdfOptions,
) -> Result<Vec<u8>, Error> {
    let config: TypstPdfOptions = unsafe { options(config)? };
    if config.flags != 0 {
        return Err(Error::unsupported("unknown PDF flags"));
    }
    crate::export::pdf(
        document,
        unsafe { text(config.standard, "PDF standard")? },
        unsafe { text(config.creator, "PDF creator")? },
    )
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
/// its string views must remain readable for the call. `out` and the
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
            let bytes = export_pdf(&document.inner.document, config)?;
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
/// `layout` must be live. A non-null `config` and its nested string views
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
            let bytes = export_pdf(&crate::export::from_frame(&layout.inner.frame), config)?;
            out.write(owned(TypstBuffer { inner: bytes }));
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
/// `scene` must be live. A non-null `config` and its nested string views
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
            let bytes = export_pdf(&crate::export::from_frame(&scene.inner.frame), config)?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}

/// Draws a zero-based PDF page inside one transparency group at `opacity`,
/// from 0 to 1, and returns a one-page PDF of the same size. The page then
/// blends with what lies under it as a whole, as an SVG group's `opacity`
/// does: unlike colors that each carry the opacity, overlapping parts of the
/// page do not show through one another. Typst's groups have no opacity; a
/// page exported with `typst_scene_export_pdf`, wrapped here and imported
/// with `typst_scene_from_pdf` stands in for one. The result declares the
/// input's PDF version, at least 1.4. Requires TYPST_CAP_PDF_PAGE_OPACITY.
///
/// # Safety
/// `data` follows the module pointer contract. `out` must be a non-null writable
/// buffer slot; `diagnostics` is optional. Release both returned owners separately.
#[no_mangle]
pub unsafe extern "C" fn typst_pdf_page_with_opacity(
    data: TypstBytes,
    page: usize,
    opacity: f64,
    out: *mut *mut TypstBuffer,
    diagnostics: *mut *mut TypstDiagnostics,
) -> TypstStatus {
    unsafe {
        call(diagnostics, || {
            output(out)?;
            let bytes = crate::export::pdf_page_with_opacity(
                values(data.data, data.len, "PDF data")?,
                page,
                opacity,
            )?;
            out.write(owned(TypstBuffer { inner: bytes }));
            Ok(Report::default())
        })
    }
}
