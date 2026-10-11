#include "gdb_lldb.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    /* An exact-sized copy lets the sanitizer see any read past the reply. */
    char *copy = malloc(size ? size : 1);
    if (!copy) return 0;
    memcpy(copy, data, size);
    struct xrt_gdb_host host = {0};
    struct xrt_gdb_region region;
    struct { struct xrt_gdb_image rows[3]; uint64_t canary; } out = {.canary = UINT64_C(0x5a5a5a5a5a5a5a5a)};
    size_t total = 0;
    (void)xrt_gdb_host_parse(copy, size, &host);
    (void)xrt_gdb_process_parse(copy, size, &host);
    assert(host.address_bits <= 64 && host.pid <= INT32_MAX);
    for (unsigned cut = 0; cut < 2; ++cut)
        if (xrt_gdb_region_parse(copy, size, cut, 0x1000, &region) == XRT_OK) {
            assert(memchr(region.name, 0, sizeof(region.name)) && memchr(region.type, 0, sizeof(region.type)));
            assert(!region.size || (region.start <= 0x1000 && 0x1000 - region.start < region.size));
        }
    enum xrt_status status = xrt_gdb_images_parse(copy, size, out.rows, 3, &total);
    assert(out.canary == UINT64_C(0x5a5a5a5a5a5a5a5a) && total <= XRT_GDB_IMAGES_MAX);
    if (status == XRT_OK)
        for (size_t i = 0; i < total && i < 3; ++i) assert(memchr(out.rows[i].path, 0, sizeof(out.rows[i].path)));
    free(copy);
    return 0;
}
