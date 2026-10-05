#define _GNU_SOURCE 1
#include "xrt_wire.h"
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>
struct xrt_codec xrt_codec(void *bytes, size_t size, bool read)
{
    return (struct xrt_codec){.bytes = bytes, .size = size, .read = read, .ok = true};
}
void xrt_codec_bytes(struct xrt_codec *c, void *data, size_t size)
{
    if (!c->ok)
        return;
    if (size > c->size - c->at) {
        c->ok = false;
        return;
    }
    if (size) {
        if (c->read)
            memcpy(data, c->bytes + c->at, size);
        else
            memcpy(c->bytes + c->at, data, size);
    }
    c->at += size;
}
void xrt_codec_u8(struct xrt_codec *c, uint8_t *n)
{
    xrt_codec_bytes(c, n, 1);
}
void xrt_codec_u16(struct xrt_codec *c, uint16_t *n)
{
    uint8_t b[2] = {0};
    if (!c->read) {
        b[0] = (uint8_t)(*n >> 8);
        b[1] = (uint8_t)*n;
    }
    xrt_codec_bytes(c, b, 2);
    if (c->ok && c->read)
        *n = (uint16_t)((uint16_t)b[0] << 8 | b[1]);
}
void xrt_codec_u32(struct xrt_codec *c, uint32_t *n)
{
    uint8_t b[4] = {0};
    if (!c->read)
        for (unsigned i = 0; i < 4; ++i)
            b[i] = (uint8_t)(*n >> (24 - 8 * i));
    xrt_codec_bytes(c, b, 4);
    if (c->ok && c->read) {
        *n = 0;
        for (unsigned i = 0; i < 4; ++i)
            *n = (*n << 8) | b[i];
    }
}
void xrt_codec_u64(struct xrt_codec *c, uint64_t *n)
{
    uint8_t b[8] = {0};
    if (!c->read)
        for (unsigned i = 0; i < 8; ++i)
            b[i] = (uint8_t)(*n >> (56 - 8 * i));
    xrt_codec_bytes(c, b, 8);
    if (c->ok && c->read) {
        *n = 0;
        for (unsigned i = 0; i < 8; ++i)
            *n = (*n << 8) | b[i];
    }
}
void xrt_codec_bool(struct xrt_codec *c, bool *v)
{
    uint8_t n = c->read ? 0 : (*v ? 1 : 0);
    xrt_codec_u8(c, &n);
    if (n > 1)
        c->ok = false;
    if (c->ok && c->read)
        *v = n != 0;
}
bool xrt_wire_header_encode(const struct xrt_wire_frame *f, uint8_t out[32])
{
    if (f->size > XRT_WIRE_MAX_BODY || f->flags > 1 || !f->request)
        return false;
    struct xrt_codec c = xrt_codec(out, 32, false);
    uint32_t magic = UINT32_C(0x58525431);
    uint16_t version = XRT_WIRE_VERSION;
    struct xrt_wire_frame v = *f;
    xrt_codec_u32(&c, &magic);
    xrt_codec_u16(&c, &version);
    xrt_codec_u16(&c, &v.op);
    xrt_codec_u64(&c, &v.request);
    xrt_codec_u32(&c, &v.target);
    xrt_codec_u32(&c, &v.status);
    xrt_codec_u32(&c, &v.size);
    xrt_codec_u32(&c, &v.flags);
    return c.ok;
}
bool xrt_wire_header_decode(const uint8_t in[32], struct xrt_wire_frame *out)
{
    struct xrt_codec c = xrt_codec((void *)in, 32, true);
    uint32_t magic = 0;
    uint16_t version = 0;
    struct xrt_wire_frame f = {0};
    xrt_codec_u32(&c, &magic);
    xrt_codec_u16(&c, &version);
    xrt_codec_u16(&c, &f.op);
    xrt_codec_u64(&c, &f.request);
    xrt_codec_u32(&c, &f.target);
    xrt_codec_u32(&c, &f.status);
    xrt_codec_u32(&c, &f.size);
    xrt_codec_u32(&c, &f.flags);
    if (!c.ok || magic != UINT32_C(0x58525431) || version != XRT_WIRE_VERSION ||
        f.size > XRT_WIRE_MAX_BODY || f.flags > 1 || !f.request)
        return false;
    *out = f;
    return true;
}
static int64_t milliseconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
/* FDs must be nonblocking. A whole-frame deadline prevents trickled bytes from
 * keeping a failed peer or target operation alive indefinitely. */
static enum xrt_wire_result transfer(int fd, void *buffer, size_t size, bool sending,
                                     int64_t deadline, bool header)
{
    size_t at = 0;
    while (at < size) {
        int timeout = -1;
        if (deadline >= 0) {
            int64_t left = deadline - milliseconds();
            if (left <= 0)
                return XRT_WIRE_TIMEOUT;
            timeout = left > INT32_MAX ? INT32_MAX : (int)left;
        }
        struct pollfd p = {.fd = fd, .events = sending ? POLLOUT : POLLIN};
        int ready = poll(&p, 1, timeout);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            return XRT_WIRE_IO;
        }
        if (!ready)
            return XRT_WIRE_TIMEOUT;
        if (p.revents & POLLNVAL)
            return XRT_WIRE_IO;
        ssize_t n;
        if (sending) {
            n = send(fd, (uint8_t *)buffer + at, size - at, MSG_NOSIGNAL);
            if (n < 0 && errno == ENOTSOCK)
                n = write(fd, (uint8_t *)buffer + at, size - at);
        } else
            n = read(fd, (uint8_t *)buffer + at, size - at);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            return XRT_WIRE_IO;
        }
        if (!n)
            return !sending && !at && header ? XRT_WIRE_EOF : XRT_WIRE_INVALID;
        at += (size_t)n;
    }
    return XRT_WIRE_OK;
}
enum xrt_wire_result xrt_wire_read(int fd, struct xrt_wire_frame *frame, void *body,
                                   size_t capacity, int timeout)
{
    uint8_t header[32];
    int64_t deadline = timeout < 0 ? -1 : milliseconds() + timeout;
    enum xrt_wire_result r = transfer(fd, header, sizeof(header), false, deadline, true);
    if (r != XRT_WIRE_OK)
        return r;
    struct xrt_wire_frame f;
    if (!xrt_wire_header_decode(header, &f) || f.size > capacity)
        return XRT_WIRE_INVALID;
    r = transfer(fd, body, f.size, false, deadline, false);
    if (r == XRT_WIRE_OK)
        *frame = f;
    return r;
}
enum xrt_wire_result xrt_wire_write(int fd, const struct xrt_wire_frame *frame, const void *body,
                                    int timeout)
{
    uint8_t header[32];
    if (!xrt_wire_header_encode(frame, header))
        return XRT_WIRE_INVALID;
    int64_t deadline = timeout < 0 ? -1 : milliseconds() + timeout;
    enum xrt_wire_result r = transfer(fd, header, sizeof(header), true, deadline, true);
    return r == XRT_WIRE_OK ? transfer(fd, (void *)body, frame->size, true, deadline, false) : r;
}
