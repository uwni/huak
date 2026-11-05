/* Intentionally incomplete: used ONLY to verify rejection before real calls.
 * All rendering tests load the independently built Rust libtypst. */
#include "libtypst.h"
uint32_t typst_abi_version(void) {
    return TYPST_ABI_VERSION ^ (TYPST_TEST_INCOMPATIBLE ? 0x00010000u : 0u);
}
void typst_layout_release(TypstLayout const *layout) {
    (void)layout;
}
