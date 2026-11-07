#include "../src/drawing/space/projection.h"
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
  auto load = reinterpret_cast<decltype(&huak_space_api_v1)>(
      dlsym(library, "huak_space_api_v1"));
  const auto *api = load ? load() : nullptr;
  if (!api || !api->project || !api->release) return 1;

  HuakModelShape segment{};
  segment.kind = HUAK_SEGMENT;
  segment.args[3] = 10;
  const size_t root = 0;
  HuakLinework lines{};
  char error[256]{};
  if (api->project(&segment, 1, &root, 1, 0, 1.0, 0, 0.01, 0, nullptr,
                   &lines, error, sizeof(error)) != 0) {
    std::fprintf(stderr, "%s\n", error);
    return 1;
  }
  const bool valid = lines.count == 1 && lines.lines[0].kind == HUAK_CURVE &&
                     lines.lines[0].count >= 2;
  api->release(&lines);
  dlclose(library);
  return valid && !lines.owner ? 0 : 1;
}
