/* Shared declarations of the independent C ABI acceptance host: the API table
   loaded at run time, the checks every area uses, and one entry point per area. */
#ifndef TYPST_ACCEPTANCE_HOST_H
#define TYPST_ACCEPTANCE_HOST_H

#include "libtypst.h"
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define API_FUNCTIONS(X) \
    X(abi_version) X(version_info) X(cache_evict) \
    X(context_create) X(context_compile) X(context_layout) X(context_layout_many) \
    X(layout_metrics) X(layout_bounds) X(layout_labels) X(document_page_count) X(document_page_metrics) \
    X(document_export_svg) X(document_export_pdf) \
    X(layout_export_svg) X(layout_export_pdf) \
    X(scene_create) X(scene_metrics) X(scene_export_svg) X(scene_export_pdf) \
    X(layout_outline) X(outline_view) X(buffer_data) \
    X(diagnostics_count) X(diagnostics_get) X(diagnostics_get_note) \
    X(context_retain) X(context_release) X(document_retain) X(document_release) \
    X(layout_retain) X(layout_release) X(scene_retain) X(scene_release) \
    X(outline_retain) X(outline_release) X(buffer_retain) X(buffer_release) \
    X(diagnostics_retain) X(diagnostics_release) \
    X(source_member_uses) X(member_uses_view) X(member_uses_release) \
    X(context_eval) X(module_retain) X(module_release)

/* Function types come from the generated header, never a duplicate signature list. */
#define DECLARE(name) __typeof__(typst_##name) *name;
typedef struct { API_FUNCTIONS(DECLARE) } Api;
#undef DECLARE
extern Api api;

void require(bool condition, char const *message);
TypstStr str(char const *text);
bool contains(TypstBytes bytes, char const *text);
void print_diagnostics(TypstDiagnostics const *diagnostics);
void check(TypstStatus status, TypstDiagnostics **diagnostics);
/* Taking the diagnostic pointer's address avoids C argument evaluation order issues. */
#define CHECK(call) check((call), &diagnostics)
void expect_error(TypstStatus status, TypstStatus expected, TypstDiagnostics **diagnostics);
void load_api(char const *path);
void save_buffer(char const *directory, char const *name, TypstBuffer *buffer, char const *marker);
bool label_is(TypstLabeledElement const *element, char const *name);

/* One entry point per area, in the order main uses them. */
void custom_font(char const *directory);
TypstContext *create_context(void);
void options_evolution(void);
void request_bindings(TypstContext const *context);
void request_templates(TypstContext const *context);
void member_uses(void);
void module_handles(TypstContext const *context);
void labeled_elements(TypstContext const *context);
TypstDocument *compile_document(TypstContext const *context);
TypstLayout *batch_layout(TypstContext const *context);
TypstScene *create_scene(TypstLayout const *layout);
TypstScene *outline_scene(TypstOutline const *outline, TypstMetrics metrics);
void pdf_creators(TypstDocument const *document, TypstLayout const *layout,
                  TypstScene const *scene, char const *directory);

#endif
