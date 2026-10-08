#ifndef XODB_RUNTIME_GDB_PACKET_H
#define XODB_RUNTIME_GDB_PACKET_H
/* GDB remote serial protocol framing. The payload is untrusted.
 * Checksums cover the bytes between the introducer and '#'.
 * '}' XOR 0x20 escapes '#', '$', '}', and '*'.
 * '*' then (count + 29) repeats the previous byte count more times.
 * '0* ' is therefore four '0' bytes. */
#include <stddef.h>
#include <stdint.h>

#define XRT_GDB_PAYLOAD_MAX 65536u
#define XRT_GDB_WIRE_MAX (2u * XRT_GDB_PAYLOAD_MAX + 4u)
/* One complete frame is consumed on decode errors. NEED_MORE consumes none.
 * A malformed prefix consumes at least one byte so a stream can recover.
 * Output bytes are valid only on OK. The caller bounds its stream buffer. */

enum xrt_gdb_kind {
    XRT_GDB_ACK,
    XRT_GDB_NAK,
    XRT_GDB_INTERRUPT,
    XRT_GDB_PACKET,
    XRT_GDB_NOTIFY
};
enum xrt_gdb_decode_status {
    XRT_GDB_OK,
    XRT_GDB_NEED_MORE,
    XRT_GDB_BAD_CHECKSUM,
    XRT_GDB_BAD_FRAME,
    XRT_GDB_BUFFER_TOO_SMALL
};
struct xrt_gdb_view {
    enum xrt_gdb_kind kind;
    size_t consumed;
    size_t length;
};
enum xrt_gdb_decode_status xrt_gdb_decode(const uint8_t *in, size_t in_len, uint8_t *out,
                                         size_t out_cap, struct xrt_gdb_view *view);
enum xrt_gdb_decode_status xrt_gdb_encode(const uint8_t *payload, size_t length, uint8_t *out,
                                         size_t out_cap, size_t *out_len);
#endif
