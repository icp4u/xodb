#ifndef XODB_RUNTIME_WIRE_H
#define XODB_RUNTIME_WIRE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define XRT_WIRE_VERSION 1
#define XRT_WIRE_HEADER_SIZE 32
#define XRT_WIRE_MAX_BODY (1024u * 1024u)
/* Every integer is big endian. No native struct/pointer is sent. Header:
 * magic "XRT1", version:u16, op:u16, request:u64, target:u32,
 * status:u32, body_size:u32, flags:u32 (0=request, 1=response).
 * Transport is an authenticated inherited stream (normally SSH stdio).
 * A malformed or truncated frame permanently ends that connection. */
struct xrt_wire_frame {
    uint16_t op;
    uint64_t request;
    uint32_t target, status, size, flags;
};
enum xrt_wire_result { XRT_WIRE_OK, XRT_WIRE_EOF, XRT_WIRE_IO, XRT_WIRE_INVALID, XRT_WIRE_TIMEOUT };
enum xrt_wire_result xrt_wire_read(int fd, struct xrt_wire_frame *, void *body, size_t capacity,
                                   int timeout_ms);
enum xrt_wire_result xrt_wire_write(int fd, const struct xrt_wire_frame *, const void *body,
                                    int timeout_ms);
bool xrt_wire_header_encode(const struct xrt_wire_frame *, uint8_t out[XRT_WIRE_HEADER_SIZE]);
bool xrt_wire_header_decode(const uint8_t in[XRT_WIRE_HEADER_SIZE], struct xrt_wire_frame *);
/* Bounded payload codec. An error latches; subsequent operations are inert. */
struct xrt_codec {
    uint8_t *bytes;
    size_t size, at;
    bool read, ok;
};
struct xrt_codec xrt_codec(void *bytes, size_t size, bool read);
void xrt_codec_bytes(struct xrt_codec *, void *data, size_t size);
void xrt_codec_u8(struct xrt_codec *, uint8_t *);
void xrt_codec_u16(struct xrt_codec *, uint16_t *);
void xrt_codec_u32(struct xrt_codec *, uint32_t *);
void xrt_codec_u64(struct xrt_codec *, uint64_t *);
void xrt_codec_bool(struct xrt_codec *, bool *);
#endif
