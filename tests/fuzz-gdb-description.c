#include "gdb_description.h"
#include "gdb_packet.h"
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    struct xrt_gdb_description *d = malloc(sizeof(*d));
    if (!d) return 0;
    enum xrt_status status = xrt_gdb_description_parse(d, (const char *)data, size, NULL, NULL);
    if (status == XRT_OK) {
        assert(d->arch && d->count <= XRT_GDB_REGISTERS_MAX);
        size_t bytes = 0;
        for (uint32_t i = 0; i < d->count; ++i) {
            size_t end = 2u * (d->registers[i].offset + d->registers[i].bytes);
            if (end > XRT_GDB_PAYLOAD_MAX) break;
            bytes = end;
        }
        if (!bytes) { free(d); return 0; }
        uint8_t *raw = malloc(bytes);
        if (raw) {
            memset(raw, 'x', bytes);
            struct xrt_registers registers;
            assert(xrt_gdb_description_decode(d, raw, bytes, &registers) == XRT_OK);
            memset(raw, '0', bytes);
            assert(xrt_gdb_description_decode(d, raw, bytes, &registers) == XRT_OK);
            free(raw);
        }
    }
    free(d);
    return 0;
}
