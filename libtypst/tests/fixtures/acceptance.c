/* An independent owner of the public C ABI: no Rust types or linked symbols. */
#include "acceptance/host.h"

int main(int argc, char **argv) {
    require(argc == 3, "usage: c-abi-host library output-directory");
    load_api(argv[1]);
    options_evolution();
    custom_font(argv[2]);
    TypstContext *context = create_context();
    request_bindings(context);
    request_templates(context);
    member_uses();
    module_handles(context);
    labeled_elements(context);
    TypstDocument *document = compile_document(context);
    TypstLayout *layout = batch_layout(context);
    TypstScene *scene = create_scene(layout);
    pdf_creators(document, layout, scene, argv[2]);
    TypstOutline *outline = NULL;
    TypstDiagnostics *diagnostics = NULL;
    TypstMetrics metrics = {0};
    CHECK(api.layout_metrics(layout, &metrics));
    CHECK(api.layout_outline(layout, &outline, &diagnostics));
    api.outline_retain(outline);
    api.outline_release(outline);
    api.context_release(context);
    TypstBuffer *buffer = NULL;
    CHECK(api.document_export_svg(document, 0, &buffer, &diagnostics));
    save_buffer(argv[2], "acceptance.svg", buffer, "<svg");
    CHECK(api.document_export_pdf(document, NULL, &buffer, &diagnostics));
    api.document_release(document);
    save_buffer(argv[2], "acceptance.pdf", buffer, "%PDF-");
    CHECK(api.layout_export_svg(layout, &buffer, &diagnostics));
    require(contains(api.buffer_data(buffer), "<path"), "standalone layout exports real SVG");
    api.buffer_release(buffer);
    CHECK(api.layout_export_pdf(layout, NULL, &buffer, &diagnostics));
    require(contains(api.buffer_data(buffer), "%PDF-"), "standalone layout exports PDF");
    api.buffer_release(buffer);
    api.layout_release(layout);
    CHECK(api.scene_export_svg(scene, &buffer, &diagnostics));
    require(contains(api.buffer_data(buffer), "clip"), "native clipping reaches SVG output");
    require(contains(api.buffer_data(buffer), "stroke-dasharray"), "native dashes reach SVG output");
    require(contains(api.buffer_data(buffer), "<radialGradient") && contains(api.buffer_data(buffer), "<linearGradient"),
            "independent fill and stroke paints survive the source scope");
    save_buffer(argv[2], "native-scene.svg", buffer, "<svg");
    CHECK(api.scene_export_pdf(scene, NULL, &buffer, &diagnostics));
    api.scene_release(scene);
    save_buffer(argv[2], "native-scene.pdf", buffer, "%PDF-");
    TypstScene *outlined = outline_scene(outline, metrics);
    api.outline_release(outline);
    CHECK(api.scene_export_svg(outlined, &buffer, &diagnostics));
    api.scene_release(outlined);
    save_buffer(argv[2], "outlined.svg", buffer, "<path");
    api.context_release(NULL);
    api.document_release(NULL);
    api.layout_release(NULL);
    api.scene_release(NULL);
    api.outline_release(NULL);
    api.buffer_release(NULL);
    api.diagnostics_release(NULL);
    CHECK(api.cache_evict(0));
    puts("stable C ABI acceptance passed");
    return EXIT_SUCCESS;
}
