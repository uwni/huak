/* Source member queries and evaluated module handles. */
#include "host.h"

void member_uses(void) {
    TypstDiagnostics *diagnostics = NULL;
    TypstMemberUses *uses = NULL;
    TypstMemberUseView view = {0};
    TypstStr text = str("#lib.title $lib.mark(a)$ #import lib: alpha\n#other.x");
    CHECK(api.source_member_uses(text, TYPST_SYNTAX_MARKUP, str("lib"), &uses, &diagnostics));
    CHECK(api.member_uses_view(uses, &view));
    char const *expected[3] = { "title", "mark", "alpha" };
    require(view.use_count == 3 && view.flags == 0, "member uses are found in markup, math and imports");
    for (size_t index = 0; index < 3; ++index) {
        TypstMemberUse const *use = &view.uses[index];
        require(use->member.len == strlen(expected[index]) &&
                memcmp(use->member.data, expected[index], use->member.len) == 0 &&
                use->end - use->start == use->member.len &&
                memcmp(text.data + use->start, use->member.data, use->member.len) == 0,
                "member uses name each member and its byte range");
    }
    api.member_uses_release(uses);
    CHECK(api.source_member_uses(str("#let f(lib) = lib.a"), TYPST_SYNTAX_MARKUP, str("lib"),
                                 &uses, &diagnostics));
    CHECK(api.member_uses_view(uses, &view));
    require(view.flags == TYPST_MEMBER_USES_REBOUND, "binding the name is reported");
    api.member_uses_release(uses);
    CHECK(api.source_member_uses(str("#lib.a #repr(dictionary(lib))"), TYPST_SYNTAX_MARKUP, str("lib"),
                                 &uses, &diagnostics));
    CHECK(api.member_uses_view(uses, &view));
    require(view.use_count == 1 && view.flags == TYPST_MEMBER_USES_WHOLE,
            "using the name as a whole value is reported beside its members");
    api.member_uses_release(uses);
}


static bool source_is(TypstDiagnosticView const *view, char const *name) {
    TypstStr found = view->source_name;
    while (found.len > 0 && found.data[0] == '/') {
        ++found.data;
        --found.len;
    }
    return found.len == strlen(name) && memcmp(found.data, name, found.len) == 0;
}


void module_handles(TypstContext const *context) {
    TypstDiagnostics *diagnostics = NULL;
    TypstValueInput size = { .kind = TYPST_VALUE_LENGTH, .number = 30 };
    TypstBinding own = { .name = str("size"), .value = &size };
    TypstEvalOptions base_options = { .struct_size = sizeof base_options,
                                      .bindings = &own, .binding_count = 1 };
    TypstModule *base = NULL;
    /* The file sees its bindings; only its own definitions are members. */
    CHECK(api.context_eval(context,
        str("#let scale = size\n#let style(body) = { set text(size: scale); body }\n"
            "#let fail() = panic(\"inside base\")\n"
            "#let mark(name, body) = [#box(body)#label(name)]\nIgnored content"),
        str("base.typ"), &base_options, &base, &diagnostics));
    require(base != NULL, "evaluation returns a module handle");

    /* A module's bindings may refer to the handles its options list. */
    TypstValueInput first = { .kind = TYPST_VALUE_MODULE_HANDLE, .integer = 0 };
    TypstBinding uses_base = { .name = str("base"), .value = &first };
    TypstModule const *with_base[1] = { base };
    TypstEvalOptions theme_options = { .struct_size = sizeof theme_options,
        .bindings = &uses_base, .binding_count = 1,
        .module_handles = with_base, .module_handle_count = 1 };
    TypstModule *theme = NULL;
    TypstStr theme_code = str("#let twice = base.scale * 2\n#let style = base.style\n#let fail = base.fail\n"
                              "#let mark = base.mark");
    CHECK(api.context_eval(context, theme_code, str("theme.typ"), &theme_options, &theme, &diagnostics));
    /* The module keeps what it was evaluated with after that handle is released. */
    api.module_retain(theme);
    api.module_release(theme);
    api.module_release(base);

    TypstModule const *handles[2] = { theme, theme };
    TypstValueInput again = { .kind = TYPST_VALUE_MODULE_HANDLE, .integer = 1 };
    TypstBinding roots[2] = { { .name = str("lib"), .value = &first },
                              { .name = str("same"), .value = &again } };
    TypstStr style_path = str("style");
    TypstShowValue show = { .value = &first, .path = &style_path, .path_count = 1 };
    enum { PLAIN, SHOWN, COUNT };
    TypstLayoutOptions options[COUNT];
    TypstLayoutRequest requests[COUNT] = {0};
    for (size_t index = 0; index < COUNT; ++index) {
        options[index] = (TypstLayoutOptions){ .struct_size = sizeof options[index],
            .module_handles = handles, .module_handle_count = 2, .bindings = roots, .binding_count = 2 };
        requests[index] = (TypstLayoutRequest){
            .source = str("#assert(type(lib) == module and repr(lib) == \"<module theme>\")"
                          "#assert(lib.twice == 60pt and \"base\" not in dictionary(lib))"
                          "#assert(same.twice == lib.twice)#lib.mark(\"x\")[Hello]"),
            .source_name = str("handles.typ"), .options = &options[index] };
    }
    options[SHOWN].show_values = &show;
    options[SHOWN].show_value_count = 1;
    TypstLayoutResult results[COUNT] = {0};
    CHECK(api.context_layout_many(context, requests, COUNT, results, &diagnostics));
    for (size_t index = 0; index < COUNT; ++index)
        if (results[index].status != TYPST_OK) print_diagnostics(results[index].diagnostics);
    require(results[PLAIN].status == TYPST_OK && results[SHOWN].status == TYPST_OK,
            "module handles bind as modules and their members apply as show rules");
    TypstMetrics metrics[COUNT] = {0};
    for (size_t index = 0; index < COUNT; ++index)
        CHECK(api.layout_metrics(results[index].layout, &metrics[index]));
    require(metrics[SHOWN].width_pt > 2 * metrics[PLAIN].width_pt,
            "a member of an evaluated module applied as a show rule styles the content");
    TypstLabelView labels = {0};
    CHECK(api.layout_labels(results[PLAIN].layout, &labels));
    require(labels.element_count == 1 && label_is(&labels.elements[0], "x"),
            "a module function labels what it is called with");
    for (size_t index = 0; index < COUNT; ++index) {
        api.layout_release(results[index].layout);
        api.diagnostics_release(results[index].diagnostics);
    }

    TypstLayout *layout = NULL;
    TypstLayoutRequest request = requests[SHOWN];
    style_path = str("twice");
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "a show value must be a function");
    style_path = str("missing");
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "a show value path must name existing fields");
    style_path = str("style");

    /* An error raised inside a module the handle was evaluated with is found in that module's text. */
    request = requests[PLAIN];
    request.source = str("#lib.fail()");
    require(api.context_layout(context, &request, &layout, &diagnostics) == TYPST_COMPILE_FAILED &&
            layout == NULL, "an error inside a module function fails the request");
    TypstDiagnosticView view = {0};
    require(api.diagnostics_get(diagnostics, 0, &view) == TYPST_OK && source_is(&view, "base.typ") &&
            (view.flags & TYPST_DIAGNOSTIC_HAS_RANGE) != 0 && view.byte_end > view.byte_start,
            "the error is located in the source of the module that raised it");
    api.diagnostics_release(diagnostics);
    diagnostics = NULL;

    request.source = str("Hello");
    again.integer = 2;
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "a module handle index must be in range");
    again.integer = 1;
    request.source_name = str("theme.typ");
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "a request and its module handles have distinct source names");
    request.source_name = str("handles.typ");

    /* Two different texts under one name cannot be used together. */
    TypstModule *other = NULL;
    CHECK(api.context_eval(context, str("#let twice = 1pt"), str("theme.typ"), NULL, &other, &diagnostics));
    handles[1] = other;
    expect_error(api.context_layout(context, &request, &layout, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(layout == NULL, "module handles used together have distinct source names");
    handles[1] = theme;
    api.module_release(other);

    other = NULL;
    expect_error(api.context_eval(context, str("#let = 1"), str("broken.typ"), NULL, &other, &diagnostics),
                 TYPST_COMPILE_FAILED, &diagnostics);
    require(other == NULL, "a module with a syntax error returns no handle");
    expect_error(api.context_eval(context, str("#let twice = 1pt"), str(""), NULL, &other, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(other == NULL, "an evaluated module needs a source name");
    /* The handle evaluated above is released; these options list the live one. */
    handles[1] = theme;
    TypstEvalOptions later = { .struct_size = sizeof later, .bindings = &uses_base, .binding_count = 1,
                               .module_handles = handles, .module_handle_count = 1 };
    first.integer = 1;
    expect_error(api.context_eval(context, theme_code, str("later.typ"), &later, &other, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(other == NULL, "a module handle index must be in range during evaluation");
    first.integer = 0;
    /* Templates belong to requests. */
    first.kind = TYPST_VALUE_TEMPLATE;
    expect_error(api.context_eval(context, theme_code, str("later.typ"), &later, &other, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(other == NULL, "evaluation options have no templates to refer to");
    api.module_release(theme);
    api.module_release(NULL);
}


