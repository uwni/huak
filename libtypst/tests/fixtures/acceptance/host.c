/* The API table loaded from the library, and the checks every area uses. */
#include "host.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

Api api;

void require(bool condition, char const *message) {
    if (!condition) {
        fprintf(stderr, "acceptance: %s\n", message);
        exit(EXIT_FAILURE);
    }
}


TypstStr str(char const *text) {
    TypstStr value = { .data = (uint8_t const *)text, .len = strlen(text) };
    return value;
}


bool contains(TypstBytes bytes, char const *text) {
    size_t length = strlen(text);
    if (length > bytes.len) return false;
    for (size_t index = 0; index <= bytes.len - length; ++index) {
        if (memcmp(bytes.data + index, text, length) == 0) return true;
    }
    return false;
}


void print_diagnostics(TypstDiagnostics const *diagnostics) {
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


void check(TypstStatus status, TypstDiagnostics **diagnostics) {
    if (status != TYPST_OK) {
        fprintf(stderr, "unexpected status: %u\n", status);
        print_diagnostics(*diagnostics);
        exit(EXIT_FAILURE);
    }
    api.diagnostics_release(*diagnostics);
    *diagnostics = NULL;
}


void expect_error(TypstStatus status, TypstStatus expected,
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


void load_api(char const *path) {
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
                            TYPST_CAP_LAYOUT_BINDINGS | TYPST_CAP_LAYOUT_LABELS |
                            TYPST_CAP_BINDING_MODULES | TYPST_CAP_MODULE_HANDLES |
                            TYPST_CAP_SHOW_VALUES | TYPST_CAP_MEMBER_USES | TYPST_CAP_PDF_CREATOR;
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


void save_buffer(char const *directory, char const *name, TypstBuffer *buffer,
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

bool label_is(TypstLabeledElement const *element, char const *name) {
    return element->label.len == strlen(name) && memcmp(element->label.data, name, element->label.len) == 0;
}

