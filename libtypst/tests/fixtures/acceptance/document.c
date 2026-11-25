/* Compiled documents and PDF options: creator metadata and the legacy options prefix. */
#include "host.h"

TypstDocument *compile_document(TypstContext const *context) {
    char const source[] =
        "#set page(width: 260pt, height: auto, margin: 12pt)\n"
        "#set text(size: 12pt)\n"
        "#import \"shared.typ\": title\n"
        "#title — café #sys.inputs.label\n"
        "$sum_(i=1)^n i = n(n+1)/2$\n"
        "#rect(width: 65pt, height: 18pt, fill: rgb(\"#efb6c8\"), stroke: 1pt + blue)\n";
    TypstDiagnostics *diagnostics = NULL;
    TypstDocument *document = NULL;
    CHECK(api.context_compile(context, str(source), str("main.typ"), &document, &diagnostics));
    api.document_retain(document);
    api.document_release(document);
    require(api.document_page_count(document) == 1, "real source compiles into one page");
    TypstMetrics metrics = {0};
    CHECK(api.document_page_metrics(document, 0, &metrics));
    require(metrics.width_pt > 0 && metrics.height_pt > 0, "document page metrics");
    uint8_t invalid_utf8[] = { 0xff, 0xfe };
    TypstDocument *failed = NULL;
    TypstStr bad = { .data = invalid_utf8, .len = sizeof invalid_utf8 };
    expect_error(api.context_compile(context, bad, str("bad.typ"), &failed, &diagnostics),
                 TYPST_INVALID_UTF8, &diagnostics);
    require(failed == NULL, "invalid UTF-8 does not return a document");
    expect_error(api.context_compile(context, str("#let x = ("), str("broken.typ"), &failed, &diagnostics),
                 TYPST_COMPILE_FAILED, &diagnostics);
    require(failed == NULL, "compile errors do not return a document");
    return document;
}


void pdf_creators(TypstDocument const *document, TypstLayout const *layout,
                  TypstScene const *scene, char const *directory) {
    TypstDiagnostics *diagnostics = NULL;
    TypstBuffer *buffer = NULL;
    TypstPdfOptions options = { .struct_size = sizeof options,
        .standard = str("1.7"), .creator = str("C host café <&> (test)") };
    CHECK(api.document_export_pdf(document, &options, &buffer, &diagnostics));
    save_buffer(directory, "creator-document.pdf", buffer, "%PDF-");
    CHECK(api.layout_export_pdf(layout, &options, &buffer, &diagnostics));
    save_buffer(directory, "creator-layout.pdf", buffer, "%PDF-");
    CHECK(api.scene_export_pdf(scene, &options, &buffer, &diagnostics));
    save_buffer(directory, "creator-scene.pdf", buffer, "%PDF-");

    /* The old allocation ends before creator; the library must not read it. */
    struct { uint32_t struct_size; uint32_t flags; TypstStr standard; } legacy = {
        .struct_size = sizeof legacy,
    };
    _Static_assert(sizeof legacy == offsetof(TypstPdfOptions, creator), "original PDF options prefix");
    CHECK(api.document_export_pdf(document, (TypstPdfOptions const *)&legacy, &buffer, &diagnostics));
    save_buffer(directory, "legacy-pdf-options.pdf", buffer, "%PDF-");

    uint8_t invalid_utf8[] = { 0xff };
    options.creator = (TypstStr){ .data = invalid_utf8, .len = sizeof invalid_utf8 };
    require(api.document_export_pdf(document, &options, &buffer, &diagnostics) == TYPST_INVALID_UTF8,
            "PDF creator validates UTF-8");
    require(buffer == NULL && diagnostics != NULL, "invalid creator clears output and reports error");
    api.diagnostics_release(diagnostics);
    diagnostics = NULL;
    options.creator = (TypstStr){ .len = 1 };
    require(api.scene_export_pdf(scene, &options, &buffer, &diagnostics) == TYPST_INVALID_ARGUMENT,
            "nonempty PDF creator requires readable bytes");
    require(buffer == NULL, "invalid creator pointer clears output");
    api.diagnostics_release(diagnostics);
}
