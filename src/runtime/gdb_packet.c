#include "gdb_packet.h"

static int hex_nibble(uint8_t byte)
{
    if (byte >= '0' && byte <= '9')
        return byte - '0';
    if (byte >= 'a' && byte <= 'f')
        return byte - 'a' + 10;
    if (byte >= 'A' && byte <= 'F')
        return byte - 'A' + 10;
    return -1;
}
static uint8_t checksum(const uint8_t *data, size_t length)
{
    unsigned sum = 0;
    for (size_t i = 0; i < length; ++i)
        sum += data[i];
    return (uint8_t)sum;
}
static int must_escape(uint8_t byte)
{
    return byte == '#' || byte == '$' || byte == '}' || byte == '*';
}
static int bad_repeat(uint8_t count)
{
    if (count < 32 || count > 126)
        return 1;
    return count == '#' || count == '$';
}
static enum xrt_gdb_decode_status unescape(const uint8_t *body, size_t length, uint8_t *out,
                                           size_t out_cap, size_t *out_len)
{
    size_t o = 0;
    for (size_t i = 0; i < length;) {
        if (body[i] == '}') {
            if (i + 1 >= length)
                return XRT_GDB_BAD_FRAME;
            if (o >= out_cap)
                return XRT_GDB_BUFFER_TOO_SMALL;
            out[o++] = (uint8_t)(body[++i] ^ 0x20);
            ++i;
            continue;
        }
        if (body[i] == '*') {
            if (o == 0 || i + 1 >= length || bad_repeat(body[i + 1]))
                return XRT_GDB_BAD_FRAME;
            const unsigned extra = (unsigned)body[i + 1] - 29;
            if (extra > out_cap - o)
                return XRT_GDB_BUFFER_TOO_SMALL;
            const uint8_t repeated = out[o - 1];
            for (unsigned n = 0; n < extra; ++n)
                out[o++] = repeated;
            i += 2;
            continue;
        }
        if (o >= out_cap)
            return XRT_GDB_BUFFER_TOO_SMALL;
        out[o++] = body[i++];
    }
    *out_len = o;
    return XRT_GDB_OK;
}
enum xrt_gdb_decode_status xrt_gdb_decode(const uint8_t *in, size_t in_len, uint8_t *out,
                                         size_t out_cap, struct xrt_gdb_view *view)
{
    if (!view) return XRT_GDB_BAD_FRAME;
    *view = (struct xrt_gdb_view){0};
    if ((!in && in_len) || (out_cap && !out)) return XRT_GDB_BAD_FRAME;
    if (out_cap > XRT_GDB_PAYLOAD_MAX) out_cap = XRT_GDB_PAYLOAD_MAX;
    if (!in_len)
        return XRT_GDB_NEED_MORE;
    if (in[0] == '+') {
        view->kind = XRT_GDB_ACK;
        view->consumed = 1;
        return XRT_GDB_OK;
    }
    if (in[0] == '-') {
        view->kind = XRT_GDB_NAK;
        view->consumed = 1;
        return XRT_GDB_OK;
    }
    if (in[0] == 0x03) {
        view->kind = XRT_GDB_INTERRUPT;
        view->consumed = 1;
        return XRT_GDB_OK;
    }
    if (in[0] != '$' && in[0] != '%') {
        view->consumed = 1;
        return XRT_GDB_BAD_FRAME;
    }
    enum xrt_gdb_kind kind = in[0] == '%' ? XRT_GDB_NOTIFY : XRT_GDB_PACKET;
    size_t start = 1;
    size_t mark = 0;
    int found = 0;
    for (size_t i = 1; i < in_len && i < XRT_GDB_WIRE_MAX - 2; ++i) {
        /* An escape or RLE count is data, even if it resembles framing.
         * '%' introduces notifications only at the start of a frame. */
        if (in[i] == '}' || in[i] == '*') {
            if (i + 1 == in_len) return XRT_GDB_NEED_MORE;
            ++i;
            continue;
        }
        if (in[i] == '$') {
            kind = XRT_GDB_PACKET;
            start = i + 1;
            continue;
        }
        if (in[i] == '#') {
            mark = i;
            found = 1;
            break;
        }
    }
    if (!found) {
        if (in_len < XRT_GDB_WIRE_MAX) return XRT_GDB_NEED_MORE;
        view->consumed = XRT_GDB_WIRE_MAX;
        return XRT_GDB_BUFFER_TOO_SMALL;
    }
    if (mark + 2 >= in_len)
        return XRT_GDB_NEED_MORE;
    const int hi = hex_nibble(in[mark + 1]);
    const int lo = hex_nibble(in[mark + 2]);
    if (hi < 0 || lo < 0) {
        view->kind = kind;
        view->consumed = mark + 3;
        return XRT_GDB_BAD_CHECKSUM;
    }
    const uint8_t expect = (uint8_t)((hi << 4) | lo);
    if (checksum(in + start, mark - start) != expect) {
        view->kind = kind;
        view->consumed = mark + 3;
        return XRT_GDB_BAD_CHECKSUM;
    }
    size_t length = 0;
    const enum xrt_gdb_decode_status decoded =
        unescape(in + start, mark - start, out, out_cap, &length);
    view->kind = kind;
    view->consumed = mark + 3;
    if (decoded != XRT_GDB_OK)
        return decoded;
    view->length = length;
    return XRT_GDB_OK;
}
enum xrt_gdb_decode_status xrt_gdb_encode(const uint8_t *payload, size_t length, uint8_t *out,
                                         size_t out_cap, size_t *out_len)
{
    if (!out_len) return XRT_GDB_BAD_FRAME;
    *out_len = 0;
    if ((!payload && length) || !out) return XRT_GDB_BAD_FRAME;
    if (length > XRT_GDB_PAYLOAD_MAX) return XRT_GDB_BUFFER_TOO_SMALL;
    size_t body = 0;
    for (size_t i = 0; i < length; ++i)
        body += must_escape(payload[i]) ? 2 : 1;
    if (body + 4 > out_cap)
        return XRT_GDB_BUFFER_TOO_SMALL;
    size_t at = 0;
    out[at++] = '$';
    for (size_t i = 0; i < length; ++i) {
        if (must_escape(payload[i])) {
            out[at++] = '}';
            out[at++] = (uint8_t)(payload[i] ^ 0x20);
        } else {
            out[at++] = payload[i];
        }
    }
    const uint8_t sum = checksum(out + 1, at - 1);
    static const char hex[] = "0123456789abcdef";
    out[at++] = '#';
    out[at++] = (uint8_t)hex[sum >> 4];
    out[at++] = (uint8_t)hex[sum & 0xf];
    *out_len = at;
    return XRT_GDB_OK;
}
