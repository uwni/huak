/* Templates in layout requests. */
#include "host.h"

void request_templates(TypstContext const *context) {
    TypstDiagnostics *diagnostics = NULL;
    TypstValueInput size = { .kind = TYPST_VALUE_LENGTH, .number = 30 };
    TypstBinding size_member = { .name = str("size"), .value = &size };
    TypstValueInput data = { .kind = TYPST_VALUE_DICT, .bindings = &size_member, .binding_count = 1 };
    TypstBinding own = { .name = str("data"), .value = &data };
    TypstValueInput earlier = { .kind = TYPST_VALUE_TEMPLATE, .integer = 0 };
    TypstBinding inner = { .name = str("inner"), .value = &earlier };
    TypstTemplate templates[2] = {
        { .code = str("body => { set text(size: data.size); emphasis(body) }"),
          .source_name = str("large.typ"),
          .setup_code = str("let emphasis(body) = strong(body)\nset text(red)"),
          .setup_source_name = str("large-setup.typ"),
          .bindings = &own, .binding_count = 1 },
        /* A template's own bindings may refer to an earlier template. */
        { .code = str("body => inner[#body!]"), .source_name = str("outer.typ"),
          .bindings = &inner, .binding_count = 1 },
    };
    TypstValueInput function = { .kind = TYPST_VALUE_TEMPLATE, .integer = 0 };
    TypstBinding style = { .name = str("style"), .value = &function };
    size_t const large = 0, outer = 1, missing = 2;
    enum { PLAIN, SHOWN, COMPOSED, CALLED, MISSING, COUNT };
    TypstLayoutOptions options[COUNT];
    TypstLayoutRequest requests[COUNT] = {0};
    for (size_t index = 0; index < COUNT; ++index) {
        options[index] = (TypstLayoutOptions){ .struct_size = sizeof options[index],
            .templates = templates, .template_count = 2 };
        requests[index] = (TypstLayoutRequest){ .source = str("Hello"),
            .source_name = str("templated.typ"), .options = &options[index] };
    }
    options[SHOWN].shows = &large;
    options[SHOWN].show_count = 1;
    options[COMPOSED].shows = &outer;
    options[COMPOSED].show_count = 1;
    options[CALLED].bindings = &style;
    options[CALLED].binding_count = 1;
    requests[CALLED].source = str("#style[Hello] Hello");
    options[MISSING].shows = &missing;
    options[MISSING].show_count = 1;
    TypstLayoutResult results[COUNT] = {0};
    CHECK(api.context_layout_many(context, requests, COUNT, results, &diagnostics));
    for (size_t index = 0; index < MISSING; ++index)
        if (results[index].status != TYPST_OK) print_diagnostics(results[index].diagnostics);
    require(results[PLAIN].status == TYPST_OK && results[SHOWN].status == TYPST_OK &&
            results[COMPOSED].status == TYPST_OK && results[CALLED].status == TYPST_OK,
            "templates apply as show rules, compose and bind as functions");
    require(results[MISSING].status == TYPST_INVALID_ARGUMENT,
            "an out-of-range show index fails only its request");
    TypstMetrics metrics[MISSING] = {0};
    for (size_t index = 0; index < MISSING; ++index)
        CHECK(api.layout_metrics(results[index].layout, &metrics[index]));
    require(metrics[SHOWN].width_pt > 2 * metrics[PLAIN].width_pt,
            "a shown template styles the content with its own data");
    require(metrics[COMPOSED].width_pt > metrics[SHOWN].width_pt,
            "a template calls an earlier template it binds");
    require(metrics[CALLED].width_pt > metrics[SHOWN].width_pt &&
            metrics[CALLED].width_pt < metrics[SHOWN].width_pt + 2 * metrics[PLAIN].width_pt,
            "a bound template styles only the content it is called with");
    for (size_t index = 0; index < COUNT; ++index) {
        api.layout_release(results[index].layout);
        api.diagnostics_release(results[index].diagnostics);
    }

    /* A template's bindings cannot refer to itself or to a later template. */
    earlier.integer = 1;
    TypstLayout *layout = NULL;
    TypstLayoutRequest request = requests[PLAIN];
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "a forward template reference returns no layout");
    earlier.integer = 0;
    templates[1].code = str("1 + 2");
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "template code must evaluate to a function");
    templates[1].code = str("body => {");
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_COMPILE_FAILED, &diagnostics);
    require(layout == NULL, "template syntax errors fail the request");
}

