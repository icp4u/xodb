/* Fast component within the periodic fault lane; no Vulkan device required. */
#include "vulkan-fault.c"
#include "check.h"
int main(void) {
    CHECK(setenv("XODB_TEST_PRIVATE_DISPLAY", "1", 1) == 0);
    CHECK(setenv("XDG_RUNTIME_DIR", "/tmp/.work/synthetic", 1) == 0);
    VkDeviceMemory first = (VkDeviceMemory)(uintptr_t)0x10000;
    VkDeviceMemory second = (VkDeviceMemory)(uintptr_t)0x20000;
    track(K_MEMORY, (uint64_t)first);
    track(K_MEMORY, (uint64_t)second);
    map_state(first, 1);
    map_state(second, 1);
    map_state(first, 0);
    map_state(second, 0);
    CHECK(violations == 0);
    /* Planted wrong unmap must still be detected after multiple live maps. */
    map_state(first, 0);
    CHECK(violations == 1);
    untrack(K_MEMORY, (uint64_t)first);
    untrack(K_MEMORY, (uint64_t)second);
    CHECK(live_bytes == 0 && leaks == 0);
    return 0;
}
