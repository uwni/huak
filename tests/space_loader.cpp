#include "../src/drawing/space/projection.h"
#include <cstddef>
#include <cstdio>
#include <dlfcn.h>

// Run against the packaged shared object. This executable has no OCCT or
// libtypst link dependencies, just like the desktop loader before startup.
int main(int argc, char **argv) {
  if (argc != 2) return 1;
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    std::fprintf(stderr, "%s\n", dlerror());
    return 1;
  }
  auto load = reinterpret_cast<decltype(&huak_space_api_v6)>(
      dlsym(library, "huak_space_api_v6"));
  const auto *api = load ? load() : nullptr;
  if (!api) return 1;
  // The table matches this header's version and size, with every entry.
  if (api->abi_version != HUAK_SPACE_ABI_VERSION || api->size != sizeof(*api))
    return 1;
  const char *entries = reinterpret_cast<const char *>(&api->build);
  for (size_t at = 0; at + sizeof(void *) <= sizeof(*api) - offsetof(HuakProjectionV6, build);
       at += sizeof(void *))
    if (!*reinterpret_cast<void *const *>(entries + at)) return 1;

  HuakModelShape segment{};
  segment.kind = HUAK_SEGMENT;
  segment.args[3] = 10;
  const size_t root = 0;
  HuakModel *model = nullptr;
  char error[256]{};
  if (api->build(&segment, 1, &root, 1, 0.01, &model, error, sizeof(error)) != HUAK_SPACE_OK) {
    std::fprintf(stderr, "%s\n", error);
    return 1;
  }
  HuakShape info{};
  HuakView *view = nullptr;
  HuakFrame frame{};
  HuakIndices curves{};
  ptrdiff_t image = -1;
  HuakPaths paths{};
  const double eye[3] = {0, 0, 1}, x[3] = {1, 0, 0};
  bool valid = api->shape(model, 0, &info, error, sizeof(error)) == HUAK_SPACE_OK &&
               info.faces == 0 && !info.empty &&
               api->view(model, eye, x, 0, &view, &frame, error, sizeof(error)) == HUAK_SPACE_OK &&
               api->curves(view, 0, &curves, error, sizeof(error)) == HUAK_SPACE_OK &&
               curves.count == 1 &&
               api->project(view, curves.items, 1, 0, 0.01, &image, error, sizeof(error)) == HUAK_SPACE_OK &&
               image >= 0;
  if (valid) {
    const HuakPiece piece{static_cast<size_t>(image), 1, 0, 0};
    valid = api->approximate(view, &piece, 1, 0.01, &paths, error, sizeof(error)) == HUAK_SPACE_OK &&
            paths.count == 1 && paths.offsets[1] == 2 &&
            paths.commands[0].op == HUAK_MOVE && paths.commands[1].op == HUAK_LINE;
  }
  // The boundary rejects null pointers and indices that name nothing, with or
  // without room for a message.
  HuakFace face{};
  const size_t missing = 7;
  const bool rejected =
      api->face(model, 0, 0, &face, error, sizeof(error)) == HUAK_SPACE_OUT_OF_RANGE &&
      api->shape(model, 1, &info, nullptr, 0) == HUAK_SPACE_OUT_OF_RANGE &&
      api->shape(model, 0, nullptr, error, sizeof(error)) == HUAK_SPACE_INVALID_ARGUMENT &&
      api->curves(nullptr, 0, &curves, error, sizeof(error)) == HUAK_SPACE_INVALID_ARGUMENT &&
      api->project(view, nullptr, 1, 0, 0.01, &image, error, sizeof(error)) == HUAK_SPACE_INVALID_ARGUMENT &&
      api->project(view, &missing, 1, 0, 0.01, &image, error, sizeof(error)) == HUAK_SPACE_OUT_OF_RANGE;
  if (!rejected) std::fprintf(stderr, "argument checks failed: %s\n", error);
  // Releasing null does nothing.
  api->release_view(nullptr);
  api->release_model(nullptr);
  if (view) api->release_view(view);
  api->release_model(model);
  dlclose(library);
  return valid && rejected ? 0 : 1;
}
