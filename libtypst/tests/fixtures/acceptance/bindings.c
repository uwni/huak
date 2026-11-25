/* Typed binding values in layout requests, modules, option prefix evolution and batch isolation. */
#include "host.h"

void request_bindings(TypstContext const *context) {
    TypstDiagnostics *diagnostics = NULL;
    TypstLayoutOptions old = { .struct_size = offsetof(TypstLayoutOptions, bindings) };
    /* Deliberately unreadable trailing data must be ignored by the old prefix. */
    old.bindings = (TypstBinding const *)(uintptr_t)1;
    old.binding_count = SIZE_MAX;
    TypstLayoutRequest request = { .source = {0}, .source_name = {0}, .options = &old };
    request.source = str("Legacy layout options");
    TypstLayout *layout = NULL;
    CHECK(api.context_layout(context, &request, &layout, &diagnostics));
    api.layout_release(layout);
    struct {
        TypstLayoutOptions options;
        uint64_t future_fields[2];
    } future = { .options = { .struct_size = sizeof future },
                 .future_fields = { UINT64_MAX, UINT64_MAX } };
    request.options = &future.options;
    CHECK(api.context_layout(context, &request, &layout, &diagnostics));
    api.layout_release(layout);
    old.struct_size = 3;
    request.options = &old;
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "malformed option prefix is rejected before reading bindings");

    TypstLayoutOptions options[4] = {
        { .struct_size = sizeof options[0] }, { .struct_size = sizeof options[0] },
        { .struct_size = sizeof options[0] }, { .struct_size = sizeof options[0] }
    };
    TypstValueInput leaves[2][4] = {0};
    TypstBinding members[2][4] = {0};
    TypstValueInput dictionaries[2] = {0};
    TypstBinding roots[2] = {0};
    char const *names[] = { "count", "title", "size", "ink" };
    for (size_t index = 0; index < 2; ++index) {
        leaves[index][0] = (TypstValueInput){ .kind = TYPST_VALUE_INT, .integer = (int64_t)(7 + index) };
        leaves[index][1] = (TypstValueInput){ .kind = TYPST_VALUE_STRING,
            .text = str(index == 0 ? "Short" : "A substantially longer title") };
        leaves[index][2] = (TypstValueInput){ .kind = TYPST_VALUE_LENGTH, .number = index == 0 ? 11 : 20 };
        leaves[index][3] = (TypstValueInput){ .kind = TYPST_VALUE_COLOR, .color = { .r = 0.2, .g = 0.3, .b = 0.8, .a = 1 } };
        for (size_t leaf = 0; leaf < 4; ++leaf)
            members[index][leaf] = (TypstBinding){ .name = str(names[leaf]), .value = &leaves[index][leaf] };
        dictionaries[index] = (TypstValueInput){ .kind = TYPST_VALUE_DICT, .bindings = members[index], .binding_count = 4 };
        roots[index] = (TypstBinding){ .name = str("external"), .value = &dictionaries[index] };
        options[index].bindings = &roots[index];
        options[index].binding_count = 1;
    }
    options[2].binding_count = 1; /* A null array with a nonzero count is invalid. */
    TypstLayoutRequest requests[4] = {0};
    for (size_t index = 0; index < 4; ++index) {
        requests[index].source = str("#assert(type(external.count) == int) #assert(type(external.size) == type(1pt)) "
            "#assert(type(external.ink) == type(red))\n#set text(size: external.size, fill: external.ink)\n#external.title");
        requests[index].source_name = str("request-bindings.typ");
        requests[index].options = &options[index];
    }
    TypstLayoutResult results[4] = {0};
    CHECK(api.context_layout_many(context, requests, 4, results, &diagnostics));
    for (size_t index = 0; index < 2; ++index)
        if (results[index].status != TYPST_OK) print_diagnostics(results[index].diagnostics);
    require(results[0].status == TYPST_OK && results[1].status == TYPST_OK,
            "same-source requests use their own native typed bindings");
    require(results[2].status == TYPST_INVALID_ARGUMENT && results[3].status == TYPST_COMPILE_FAILED,
            "bad payload and missing binding keep their independent errors");
    TypstMetrics first = {0}, second = {0};
    CHECK(api.layout_metrics(results[0].layout, &first));
    CHECK(api.layout_metrics(results[1].layout, &second));
    require(second.width_pt > first.width_pt, "binding values are included in evaluation caching");
    TypstBuffer *buffer = NULL;
    CHECK(api.layout_export_svg(results[0].layout, &buffer, &diagnostics));
    require(contains(api.buffer_data(buffer), "<svg"), "bound content exports actual SVG");
    api.buffer_release(buffer);
    CHECK(api.layout_export_pdf(results[1].layout, NULL, &buffer, &diagnostics));
    require(contains(api.buffer_data(buffer), "/ToUnicode"), "bound content remains selectable PDF text");
    api.buffer_release(buffer);
    for (size_t index = 0; index < 4; ++index) {
        api.layout_release(results[index].layout);
        api.diagnostics_release(results[index].diagnostics);
    }
    layout = NULL;
    request.source = str("#external.title");
    request.options = NULL;
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_COMPILE_FAILED, &diagnostics);
    require(layout == NULL, "binding requests do not modify the shared context");
    uint8_t invalid_utf8[] = { 0xff };
    leaves[0][1].text = (TypstStr){ .data = invalid_utf8, .len = sizeof invalid_utf8 };
    request.options = &options[0];
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_UTF8, &diagnostics);
    require(layout == NULL, "invalid binding UTF-8 returns no layout");

    /* The same members bound as a module read the same way. */
    leaves[0][1].text = str("Short");
    TypstValueInput module = { .kind = TYPST_VALUE_MODULE, .text = str("external"),
                               .bindings = members[0], .binding_count = 4 };
    TypstBinding module_root = { .name = str("external"), .value = &module };
    TypstLayoutOptions module_options = { .struct_size = sizeof module_options,
                                          .bindings = &module_root, .binding_count = 1 };
    request.source = str("#assert(type(external) == module) #assert(external.count == 7) #external.title");
    request.options = &module_options;
    CHECK(api.context_layout(context, &request, &layout, &diagnostics));
    api.layout_release(layout);
}

