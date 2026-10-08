#include "gdb_packet.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    uint8_t decoded[XRT_GDB_PAYLOAD_MAX + 1];
    struct xrt_gdb_view view;
    decoded[XRT_GDB_PAYLOAD_MAX] = 0xa5;
    enum xrt_gdb_decode_status status =
        xrt_gdb_decode(data, size, decoded, XRT_GDB_PAYLOAD_MAX, &view);
    assert(status <= XRT_GDB_BUFFER_TOO_SMALL);
    assert(view.consumed <= size);
    assert(decoded[XRT_GDB_PAYLOAD_MAX] == 0xa5);
    if (status == XRT_GDB_OK) assert(view.length <= XRT_GDB_PAYLOAD_MAX);
    if (status == XRT_GDB_NEED_MORE) assert(view.consumed == 0);
    /* Exercise generated valid frames as well as arbitrary malformed input. */
    if (size <= 4096) {
        uint8_t wire[2 * 4096 + 4];
        size_t wire_size;
        assert(xrt_gdb_encode(data, size, wire, sizeof(wire), &wire_size) == XRT_GDB_OK);
        assert(xrt_gdb_decode(wire, wire_size, decoded, sizeof(decoded) - 1, &view) == XRT_GDB_OK);
        assert(view.kind == XRT_GDB_PACKET && view.consumed == wire_size && view.length == size);
        assert(!size || !memcmp(decoded, data, size));
    }
    return 0;
}
