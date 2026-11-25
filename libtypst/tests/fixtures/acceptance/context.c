/* Context options and their prefix evolution, caller fonts, imported files and inputs. */
#include "host.h"

void options_evolution(void) {
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


void custom_font(char const *directory) {
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


TypstContext *create_context(void) {
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

