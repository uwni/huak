/* Labeled elements and batch layout. */
#include "host.h"

void labeled_elements(TypstContext const *context) {
    TypstLayoutOptions options = { .struct_size = sizeof options, .syntax = TYPST_SYNTAX_MATH };
    TypstLayoutRequest request = {
        .source = str("mat(#[#box[$a$] <top>], b; c, #[#box[$d$] <bottom>])"),
        .source_name = str("labels.typ"),
        .options = &options
    };
    TypstLayout *layout = NULL;
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.context_layout(context, &request, &layout, &diagnostics));
    TypstPoint bounds[2];
    CHECK(api.layout_bounds(layout, bounds));
    TypstLabelView view = {0};
    CHECK(api.layout_labels(layout, &view));
    /* The view borrows the layout while any reference to it is alive. */
    api.layout_retain(layout);
    api.layout_release(layout);
    require(view.element_count == 2, "only the two labeled boxes are reported");
    TypstLabeledElement const *top = &view.elements[0];
    TypstLabeledElement const *bottom = &view.elements[1];
    require(label_is(top, "top") && label_is(bottom, "bottom"), "labels arrive in document order");
    for (size_t index = 0; index < view.element_count; ++index) {
        TypstLabeledElement const *element = &view.elements[index];
        require((element->flags & TYPST_LABEL_EXTENT) != 0, "boxes have an extent");
        require(element->min.x >= bounds[0].x && element->max.x <= bounds[1].x &&
                    element->min.y >= bounds[0].y && element->max.y <= bounds[1].y,
                "element extents lie within the layout bounds");
    }
    require(top->max.x < bottom->min.x, "matrix columns separate their cells");
    require(top->position.y < bottom->position.y, "cells start on their row's baseline");
    TypstLabelView again = {0};
    CHECK(api.layout_labels(layout, &again));
    require(again.elements == view.elements && again.element_count == 2, "records are made once");
    require(api.layout_labels(layout, NULL) == TYPST_INVALID_ARGUMENT, "labels reject null output");
    require(api.layout_labels(NULL, &again) == TYPST_INVALID_ARGUMENT && again.element_count == 0,
            "a null layout clears the view");
    api.layout_release(layout);
}


TypstLayout *batch_layout(TypstContext const *context) {
    TypstLayoutOptions region = { .struct_size = sizeof region, .width_pt = 180 };
    TypstLayoutOptions code = { .struct_size = sizeof code, .syntax = TYPST_SYNTAX_CODE };
    TypstLayoutOptions math = { .struct_size = sizeof math, .syntax = TYPST_SYNTAX_MATH };
    uint8_t invalid_utf8[] = { 0xff };
    TypstLayoutRequest requests[] = {
        { .source = {0}, .source_name = {0}, .options = &region },
        { .source = {0}, .source_name = {0} },
        { .source = {0}, .source_name = {0}, .options = &code },
        { .source = { .data = invalid_utf8, .len = sizeof invalid_utf8 }, .source_name = {0} },
        { .source = {0}, .source_name = {0}, .options = &math }
    };
    requests[0].source = str("#set text(size: 16pt)\nSelectable Alpha\n$integral_0^1 x^2 dif x$\n#rect(width: 55pt, height: 14pt, fill: red)");
    requests[1].source = str("#let broken = (");
    requests[2].source = str("{ set text(size: 18pt, weight: 700); [Code fragment] }");
    requests[4].source = str("sum_(i=1)^n i");
    for (size_t index = 0; index < 5; ++index) requests[index].source_name = str("batch.typ");
    TypstLayoutResult results[5] = {0};
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.context_layout_many(context, requests, 5, results, &diagnostics));
    TypstStatus expected[] = { TYPST_OK, TYPST_COMPILE_FAILED, TYPST_OK, TYPST_INVALID_UTF8, TYPST_OK };
    for (size_t index = 0; index < 5; ++index) {
        require(results[index].status == expected[index], "batch preserves request result order");
        if (expected[index] == TYPST_OK) {
            require(results[index].layout != NULL, "batch success returns layout owner");
            TypstMetrics metrics = {0};
            CHECK(api.layout_metrics(results[index].layout, &metrics));
            require(metrics.width_pt > 0 && metrics.height_pt > 0 && isfinite(metrics.baseline_pt),
                    "batch returns real fragment metrics");
        } else {
            require(results[index].layout == NULL, "batch error leaves layout null");
            require(api.diagnostics_count(results[index].diagnostics) > 0, "per-request diagnostics");
            TypstDiagnosticView view = {0};
            CHECK(api.diagnostics_get(results[index].diagnostics, 0, &view));
            require(view.request_index == index, "diagnostic keeps the original request index");
            require(view.source_name.len > 0 && view.message.len > 0, "source-associated diagnostic");
        }
        api.diagnostics_release(results[index].diagnostics);
        if (index != 0) api.layout_release(results[index].layout);
    }
    api.layout_retain(results[0].layout);
    api.layout_release(results[0].layout);
    return results[0].layout;
}

