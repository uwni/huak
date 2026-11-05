/* An independent owner of the public C ABI: no Rust types or linked symbols. */
#include "libtypst.h"
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#define API_FUNCTIONS(X) \
    X(abi_version) X(version_info) X(cache_evict) \
    X(context_create) X(context_compile) X(context_layout) X(context_layout_many) \
    X(layout_metrics) X(layout_bounds) X(document_page_count) X(document_page_metrics) \
    X(document_export_svg) X(document_export_pdf) \
    X(layout_export_svg) X(layout_export_pdf) \
    X(scene_create) X(scene_metrics) X(scene_export_svg) X(scene_export_pdf) \
    X(layout_outline) X(outline_view) X(buffer_data) \
    X(diagnostics_count) X(diagnostics_get) X(diagnostics_get_note) \
    X(context_retain) X(context_release) X(document_retain) X(document_release) \
    X(layout_retain) X(layout_release) X(scene_retain) X(scene_release) \
    X(outline_retain) X(outline_release) X(buffer_retain) X(buffer_release) \
    X(diagnostics_retain) X(diagnostics_release)

/* Function types come from the generated header, never a duplicate signature list. */
#define DECLARE(name) __typeof__(typst_##name) *name;
static struct { API_FUNCTIONS(DECLARE) } api;
#undef DECLARE

static void require(bool condition, char const *message) {
    if (!condition) {
        fprintf(stderr, "acceptance: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

static TypstStr str(char const *text) {
    TypstStr value = { .data = (uint8_t const *)text, .len = strlen(text) };
    return value;
}

static TypstTransform identity(void) {
    TypstTransform value = { .xx = 1, .yy = 1 };
    return value;
}

static bool contains(TypstBytes bytes, char const *text) {
    size_t length = strlen(text);
    if (length > bytes.len) return false;
    for (size_t index = 0; index <= bytes.len - length; ++index) {
        if (memcmp(bytes.data + index, text, length) == 0) return true;
    }
    return false;
}

static void print_diagnostics(TypstDiagnostics const *diagnostics) {
    for (size_t index = 0; index < api.diagnostics_count(diagnostics); ++index) {
        TypstDiagnosticView view = {0};
        require(api.diagnostics_get(diagnostics, index, &view) == TYPST_OK, "read diagnostic");
        fprintf(stderr, "diagnostic[%zu] request %zu: %.*s\n", index,
                view.request_index, (int)view.message.len, (char const *)view.message.data);
        for (size_t note = 0; note < view.note_count; ++note) {
            TypstDiagnosticView detail = {0};
            require(api.diagnostics_get_note(diagnostics, index, note, &detail) == TYPST_OK,
                    "read diagnostic note");
            fprintf(stderr, "  note: %.*s\n", (int)detail.message.len,
                    (char const *)detail.message.data);
        }
    }
}

static void check(TypstStatus status, TypstDiagnostics **diagnostics) {
    if (status != TYPST_OK) {
        fprintf(stderr, "unexpected status: %u\n", status);
        print_diagnostics(*diagnostics);
        exit(EXIT_FAILURE);
    }
    api.diagnostics_release(*diagnostics);
    *diagnostics = NULL;
}

/* Taking the diagnostic pointer's address avoids C argument evaluation order issues. */
#define CHECK(call) check((call), &diagnostics)

static void expect_error(TypstStatus status, TypstStatus expected,
                         TypstDiagnostics **diagnostics) {
    require(status == expected, "unexpected error category");
    require(api.diagnostics_count(*diagnostics) > 0, "errors must have independent diagnostics");
    api.diagnostics_retain(*diagnostics);
    api.diagnostics_release(*diagnostics);
    TypstDiagnosticView view = {0};
    require(api.diagnostics_get(*diagnostics, 0, &view) == TYPST_OK, "retained diagnostic remains valid");
    require(view.message.len > 0, "diagnostic message must be nonempty");
    require(view.severity == TYPST_DIAGNOSTIC_ERROR, "error severity");
    api.diagnostics_release(*diagnostics);
    *diagnostics = NULL;
}

static void load_api(char const *path) {
#ifdef _WIN32
    HMODULE library = LoadLibraryA(path);
#else
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) fprintf(stderr, "dlopen: %s\n", dlerror());
#endif
    require(library != NULL, "load the current native library");
#ifdef _WIN32
#define FIND_SYMBOL(name) FARPROC symbol = GetProcAddress(library, "typst_" #name)
#else
#define FIND_SYMBOL(name) void *symbol = dlsym(library, "typst_" #name)
#endif
#define LOAD(name) do { \
        FIND_SYMBOL(name); \
        require(symbol != NULL, "missing symbol: typst_" #name); \
        _Static_assert(sizeof api.name == sizeof symbol, "dynamic function pointer representation"); \
        memcpy(&api.name, &symbol, sizeof symbol); \
    } while (0);
    API_FUNCTIONS(LOAD)
#undef LOAD
#undef FIND_SYMBOL
    require(api.abi_version() == TYPST_ABI_VERSION, "header and DSO ABI version agree");
    TypstVersionInfo version = {0};
    require(api.version_info(&version) == TYPST_OK, "query native versions");
    require(version.abi_major == (TYPST_ABI_VERSION >> 16), "version major agrees");
    require(version.library_version.len > 0 && version.typst_version.len > 0,
            "library and upstream versions are available");
    uint64_t capabilities = TYPST_CAP_PDF | TYPST_CAP_BATCH_LAYOUT |
                            TYPST_CAP_NATIVE_SCENE | TYPST_CAP_TEXT_OUTLINE |
                            TYPST_CAP_LAYOUT_BINDINGS;
    require((version.capabilities & capabilities) == capabilities, "all accepted capabilities advertised");
    /* Rust worker/TLS destructors can reference this DSO. Keep it resident until
       process exit; all individual native owners are still released below. */
}

static void write_artifact(char const *directory, char const *name, TypstBytes bytes) {
    size_t length = strlen(directory) + strlen(name) + 2;
    char *path = malloc(length);
    require(path != NULL, "allocate artifact path");
    snprintf(path, length, "%s/%s", directory, name);
    FILE *file = fopen(path, "wb");
    require(file != NULL, "create artifact");
    require(fwrite(bytes.data, 1, bytes.len, file) == bytes.len, "write complete artifact");
    require(fclose(file) == 0, "close artifact");
    free(path);
}

static void save_buffer(char const *directory, char const *name, TypstBuffer *buffer,
                        char const *marker) {
    require(buffer != NULL, "export returns an owned buffer");
    api.buffer_retain(buffer);
    api.buffer_release(buffer);
    TypstBytes bytes = api.buffer_data(buffer);
    require(bytes.data != NULL && bytes.len > 0, "retained buffer remains valid");
    require(contains(bytes, marker), "export has the required format");
    write_artifact(directory, name, bytes);
    api.buffer_release(buffer);
}

static void custom_font(char const *directory) {
    size_t length = strlen(directory) + sizeof "/font.ttf";
    char *path = malloc(length);
    require(path != NULL, "allocate font path");
    snprintf(path, length, "%s/font.ttf", directory);
    FILE *file = fopen(path, "rb");
    require(file != NULL, "open caller-provided font");
    require(fseek(file, 0, SEEK_END) == 0, "seek font length");
    long size = ftell(file);
    require(size > 0 && fseek(file, 0, SEEK_SET) == 0, "read font length");
    uint8_t *bytes = malloc((size_t)size);
    require(bytes != NULL, "allocate caller font bytes");
    require(fread(bytes, 1, (size_t)size, file) == (size_t)size, "read complete font");
    require(fclose(file) == 0, "close font fixture");
    free(path);
    TypstFontSource font = { .data = { .data = bytes, .len = (size_t)size } };
    TypstContextOptions options = {
        .struct_size = sizeof options,
        .flags = TYPST_CONTEXT_NO_BUILTIN_FONTS,
        .fonts = &font,
        .font_count = 1
    };
    TypstContext *context = NULL;
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.context_create(&options, &context, &diagnostics));
    free(bytes); /* Context creation must copy font bytes, not borrow this allocation. */
    TypstLayoutRequest request = { .source = str("Selectable Alpha"), .source_name = str("font.typ") };
    TypstLayout *layout = NULL;
    CHECK(api.context_layout(context, &request, &layout, &diagnostics));
    api.context_release(context);
    TypstMetrics metrics = {0};
    CHECK(api.layout_metrics(layout, &metrics));
    require(metrics.width_pt > 0 && metrics.height_pt > 0, "caller font supports real layout");
    TypstPoint bounds[2];
    CHECK(api.layout_bounds(layout, bounds));
    require(bounds[0].x <= 0 && bounds[1].x >= metrics.width_pt, "bounds include native layout width");
    require(bounds[0].y <= 0 && bounds[1].y >= metrics.height_pt, "bounds include native layout height");
    require(api.layout_bounds(layout, NULL) == TYPST_INVALID_ARGUMENT, "bounds reject null output");
    api.layout_release(layout);
}

static TypstContext *create_context(void) {
    char imported[] = "#let title = [Selectable Alpha]\n";
    TypstFile file = {
        .path = str("shared.typ"),
        .data = { .data = (uint8_t const *)imported, .len = strlen(imported) }
    };
    TypstContextOptions options = {
        .struct_size = sizeof options,
        .files = &file,
        .file_count = 1
    };
    options.inputs_json = str("{\"label\":\"from inputs\"}");
    TypstContext *context = NULL;
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.context_create(&options, &context, &diagnostics));
    memset(imported, 0, sizeof imported); /* Imported files are copied as well. */
    api.context_retain(context);
    api.context_release(context);
    return context;
}

static void options_evolution(void) {
    _Alignas(TypstContextOptions) struct { uint32_t struct_size; } prefix = { sizeof prefix };
    TypstDiagnostics *diagnostics = NULL;
    TypstContext *context = NULL;
    CHECK(api.context_create((TypstContextOptions const *)&prefix, &context, &diagnostics));
    api.context_release(context);
    struct {
        TypstContextOptions options;
        uint64_t future_fields[2];
    } extended = { .options = { .struct_size = sizeof extended }, .future_fields = { UINT64_MAX, UINT64_MAX } };
    CHECK(api.context_create(&extended.options, &context, &diagnostics));
    api.context_release(context);
    TypstContextOptions invalid = { .struct_size = 1 };
    expect_error(api.context_create(&invalid, &context, &diagnostics),
                 TYPST_INVALID_ARGUMENT, &diagnostics);
    require(context == NULL, "failed creation initializes its output");
}

static void request_bindings(TypstContext const *context) {
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
}

static TypstDocument *compile_document(TypstContext const *context) {
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

static TypstLayout *batch_layout(TypstContext const *context) {
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

static TypstScene *create_scene(TypstLayout const *layout) {
    TypstPathSegment segments[] = {
        { .kind = TYPST_SEGMENT_MOVE, .p1 = { 5, 5 } },
        { .kind = TYPST_SEGMENT_LINE, .p1 = { 90, 5 } },
        { .kind = TYPST_SEGMENT_CUBIC, .p1 = { 110, 15 }, .p2 = { 110, 50 }, .p3 = { 90, 60 } },
        { .kind = TYPST_SEGMENT_LINE, .p1 = { 5, 60 } },
        { .kind = TYPST_SEGMENT_CLOSE }
    };
    TypstPath path = { .segments = segments, .segment_count = 5 };
    double dashes[] = { 6, 2 };
    TypstStyle style = {
        .flags = TYPST_STYLE_FILL | TYPST_STYLE_STROKE,
        .fill_rule = TYPST_FILL_EVENODD,
        .fill = { .r = 1, .g = 0.7, .b = 0.3, .a = 0.7 },
        .stroke = { .r = 0.1, .g = 0.2, .b = 0.8, .a = 1 },
        .stroke_width_pt = 3,
        .line_cap = TYPST_CAP_ROUND,
        .line_join = TYPST_JOIN_BEVEL,
        .miter_limit = 4,
        .dashes = dashes, .dash_count = 2, .dash_phase_pt = 1
    };
    TypstSceneItem child_item = { .kind = TYPST_ITEM_PATH, .transform = {0}, .path = &path, .style = &style };
    child_item.transform = identity();
    TypstSceneOptions child_options = { .struct_size = sizeof child_options, .width_pt = 120, .height_pt = 80,
                                        .items = &child_item, .item_count = 1 };
    TypstScene *child = NULL;
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.scene_create(&child_options, &child, &diagnostics));
    TypstSceneItem items[] = {
        { .kind = TYPST_ITEM_SCENE, .scene = child, .clip = &path },
        { .kind = TYPST_ITEM_LAYOUT, .layout = layout }
    };
    items[0].transform = identity();
    items[0].transform.xx = 1.3;
    items[0].transform.yy = 0.8;
    items[0].transform.xy = 0.15;
    items[0].transform.dx = 12;
    items[0].transform.dy = 10;
    items[1].transform = identity();
    items[1].transform.dx = 12;
    items[1].transform.dy = 100;
    TypstSceneOptions options = { .struct_size = sizeof options, .width_pt = 280, .height_pt = 250,
                                  .items = items, .item_count = 2 };
    TypstScene *scene = NULL;
    CHECK(api.scene_create(&options, &scene, &diagnostics));
    api.scene_release(child); /* Parent must retain its nested scene. */
    memset(segments, 0, sizeof segments); /* Input geometry/style are only borrowed during creation. */
    memset(dashes, 0, sizeof dashes);
    api.scene_retain(scene);
    api.scene_release(scene);
    TypstMetrics metrics = {0};
    CHECK(api.scene_metrics(scene, &metrics));
    require(metrics.width_pt == 280 && metrics.height_pt == 250, "native scene dimensions");
    return scene;
}

static TypstScene *outline_scene(TypstOutline const *outline, TypstMetrics metrics) {
    TypstOutlineView view = {0};
    TypstDiagnostics *diagnostics = NULL;
    CHECK(api.outline_view(outline, &view));
    require(view.path_count > 0 && view.segment_count > 0, "real glyph outlines returned in bulk");
    TypstPath *paths = calloc(view.path_count, sizeof *paths);
    TypstStyle *styles = calloc(view.path_count, sizeof *styles);
    TypstSceneItem *items = calloc(view.path_count, sizeof *items);
    require(paths != NULL && styles != NULL && items != NULL, "allocate caller outline scene");
    for (size_t index = 0; index < view.path_count; ++index) {
        TypstOutlinedPath const *source = &view.paths[index];
        require(source->segment_offset <= view.segment_count &&
                source->segment_count <= view.segment_count - source->segment_offset, "outline segment bounds");
        require(source->dash_offset <= view.dash_count &&
                source->dash_count <= view.dash_count - source->dash_offset, "outline dash bounds");
        paths[index].segments = view.segments + source->segment_offset;
        paths[index].segment_count = source->segment_count;
        styles[index] = (TypstStyle){
            .flags = source->flags, .fill_rule = source->fill_rule,
            .fill = source->fill, .stroke = source->stroke,
            .stroke_width_pt = source->stroke_width_pt,
            .line_cap = source->line_cap, .line_join = source->line_join,
            .miter_limit = source->miter_limit,
            .dashes = source->dash_count ? view.dashes + source->dash_offset : NULL,
            .dash_count = source->dash_count, .dash_phase_pt = source->dash_phase_pt
        };
        items[index] = (TypstSceneItem){ .kind = TYPST_ITEM_PATH, .transform = source->transform,
                                        .path = &paths[index], .style = &styles[index] };
    }
    TypstSceneOptions options = { .struct_size = sizeof options,
        .width_pt = metrics.width_pt, .height_pt = metrics.height_pt,
        .items = items, .item_count = view.path_count };
    TypstScene *scene = NULL;
    CHECK(api.scene_create(&options, &scene, &diagnostics));
    free(items);
    free(styles);
    free(paths);
    return scene;
}

int main(int argc, char **argv) {
    require(argc == 3, "usage: c-abi-host library output-directory");
    load_api(argv[1]);
    options_evolution();
    custom_font(argv[2]);
    TypstContext *context = create_context();
    request_bindings(context);
    TypstDocument *document = compile_document(context);
    TypstLayout *layout = batch_layout(context);
    TypstScene *scene = create_scene(layout);
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
