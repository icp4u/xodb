#include "gdb_packet.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static void expect(int cond, const char *what)
{
    if (cond)
        return;
    fprintf(stderr, "gdb-packet: %s\n", what);
    ++failures;
}
static void round_trip(const uint8_t *payload, size_t length)
{
    uint8_t wire[1024];
    uint8_t out[512];
    size_t wire_len = 0;
    struct xrt_gdb_view view;
    expect(xrt_gdb_encode(payload, length, wire, sizeof(wire), &wire_len) == XRT_GDB_OK, "encode");
    for (size_t i = 0; i < wire_len; ++i)
        expect(xrt_gdb_decode(wire, i, out, sizeof(out), &view) == XRT_GDB_NEED_MORE &&
                   view.consumed == 0, "every valid prefix needs more");
    memset(out, 0xa5, sizeof(out));
    expect(xrt_gdb_decode(wire, wire_len, out, length, &view) == XRT_GDB_OK, "decode");
    expect(view.kind == XRT_GDB_PACKET && view.consumed == wire_len && view.length == length, "view");
    expect(!length || memcmp(out, payload, length) == 0, "payload");
    if (length < sizeof(out))
        expect(out[length] == 0xa5, "tail");
}
int main(void)
{
    const uint8_t ok[] = {'O', 'K'};
    round_trip(ok, 2);
    const uint8_t special[] = {'#', '$', '}', '*', 'g'};
    round_trip(special, 5);
    round_trip(NULL, 0);
    const uint8_t percent[] = "progress:10%";
    round_trip(percent, sizeof(percent) - 1);
    uint8_t every[256];
    for (unsigned i = 0; i < sizeof(every); ++i) every[i] = (uint8_t)i;
    round_trip(every, sizeof(every));

    const uint8_t rle[] = {'$', '0', '*', ' ', '#', '7', 'a'};
    uint8_t out[16];
    struct xrt_gdb_view view;
    memset(out, 0xa5, sizeof(out));
    expect(xrt_gdb_decode(rle, sizeof(rle), out, sizeof(out), &view) == XRT_GDB_OK, "rle");
    expect(view.length == 4 && memcmp(out, "0000", 4) == 0, "rle bytes");

    uint8_t bad[sizeof(rle)];
    memcpy(bad, rle, sizeof(rle));
    bad[sizeof(bad) - 1] = 'b';
    expect(xrt_gdb_decode(bad, sizeof(bad), out, sizeof(out), &view) == XRT_GDB_BAD_CHECKSUM,
           "checksum");
    expect(view.consumed == sizeof(bad), "checksum consumed");

    const uint8_t partial[] = {'$', 'O', 'K', '#'};
    expect(xrt_gdb_decode(partial, sizeof(partial), out, sizeof(out), &view) == XRT_GDB_NEED_MORE,
           "partial");
    const uint8_t ack[] = {'+'};
    expect(xrt_gdb_decode(ack, 1, out, sizeof(out), &view) == XRT_GDB_OK && view.kind == XRT_GDB_ACK,
           "ack");
    const uint8_t interrupt[] = {0x03};
    expect(xrt_gdb_decode(interrupt, 1, out, sizeof(out), &view) == XRT_GDB_OK &&
               view.kind == XRT_GDB_INTERRUPT,
           "interrupt");
    const uint8_t note[] = {'%', 'O', 'K', '#', '9', 'a'};
    expect(xrt_gdb_decode(note, sizeof(note), out, sizeof(out), &view) == XRT_GDB_OK &&
               view.kind == XRT_GDB_NOTIFY && view.length == 2,
           "notify");

    expect(xrt_gdb_decode(rle, sizeof(rle), out, 3, &view) == XRT_GDB_BUFFER_TOO_SMALL, "short out");

    uint8_t junk[8] = {'x', '$', 'O', 'K', '#', '9', 'a'};
    expect(xrt_gdb_decode(junk, 1, out, sizeof(out), &view) == XRT_GDB_BAD_FRAME && view.consumed == 1,
           "junk");
    expect(xrt_gdb_decode(junk + 1, 6, out, sizeof(out), &view) == XRT_GDB_OK && view.length == 2,
           "after junk");


    /* Every printable RLE count except the two protocol exclusions, including
     * '%', '+', '-', '*', and '}' which are data in this position. */
    for (unsigned count = 32; count <= 126; ++count) {
        if (count == '#' || count == '$') continue;
        uint8_t frame[] = {'$', 'A', '*', (uint8_t)count, '#', 0, 0};
        static const char hex[] = "0123456789abcdef";
        unsigned sum = ('A' + '*' + count) & 255;
        frame[5] = (uint8_t)hex[sum >> 4]; frame[6] = (uint8_t)hex[sum & 15];
        uint8_t repeated[128];
        expect(xrt_gdb_decode(frame, sizeof(frame), repeated, sizeof(repeated), &view) == XRT_GDB_OK,
               "legal RLE count");
        expect(view.length == count - 28, "RLE exact expanded length");
        for (size_t i = 0; i < view.length; ++i) expect(repeated[i] == 'A', "RLE content");
    }
    /* Binary escaping may encode any byte. An escaped '#' is not a trailer. */
    const uint8_t escaped_delimiter[] = {'$', '}', '#', '#', 'a', '0'};
    expect(xrt_gdb_decode(escaped_delimiter, sizeof(escaped_delimiter), out, sizeof(out), &view) ==
               XRT_GDB_OK && view.length == 1 && out[0] == 3, "escaped delimiter");
    size_t size = 999;
    expect(xrt_gdb_encode(ok, SIZE_MAX, out, sizeof(out), &size) == XRT_GDB_BUFFER_TOO_SMALL &&
               size == 0, "oversized encode rejected before reading input");
    uint8_t *large = malloc(XRT_GDB_WIRE_MAX);
    uint8_t *plain = malloc(XRT_GDB_PAYLOAD_MAX);
    uint8_t *decoded = malloc(XRT_GDB_PAYLOAD_MAX + 1);
    expect(large && plain && decoded, "large test allocations");
    if (large && plain && decoded) {
        memset(plain, '*', XRT_GDB_PAYLOAD_MAX);
        expect(xrt_gdb_encode(plain, XRT_GDB_PAYLOAD_MAX, large, XRT_GDB_WIRE_MAX, &size) ==
                   XRT_GDB_OK && size == XRT_GDB_WIRE_MAX, "maximum escaped frame");
        decoded[XRT_GDB_PAYLOAD_MAX] = 0xa5;
        expect(xrt_gdb_decode(large, size, decoded, XRT_GDB_PAYLOAD_MAX, &view) == XRT_GDB_OK &&
                   view.length == XRT_GDB_PAYLOAD_MAX &&
                   memcmp(plain, decoded, XRT_GDB_PAYLOAD_MAX) == 0 &&
                   decoded[XRT_GDB_PAYLOAD_MAX] == 0xa5, "maximum decode bounds");
        memset(large, 'A', XRT_GDB_WIRE_MAX); large[0] = '$';
        expect(xrt_gdb_decode(large, XRT_GDB_WIRE_MAX, decoded, XRT_GDB_PAYLOAD_MAX, &view) ==
                   XRT_GDB_BUFFER_TOO_SMALL && view.consumed == XRT_GDB_WIRE_MAX,
               "unterminated frame bounded");
    }
    free(large); free(plain); free(decoded);

    uint32_t state = 0x12345678;
    uint8_t scratch[128];
    uint8_t guard[160];
    for (int n = 0; n < 2000; ++n) {
        state = state * 1664525u + 1013904223u;
        const size_t len = state % 64;
        for (size_t i = 0; i < len; ++i) {
            state = state * 1664525u + 1013904223u;
            scratch[i] = (uint8_t)state;
        }
        memset(guard, 0xa5, sizeof(guard));
        const enum xrt_gdb_decode_status status =
            xrt_gdb_decode(scratch, len, guard, 128, &view);
        expect(status <= XRT_GDB_BUFFER_TOO_SMALL, "fuzz status");
        expect(view.consumed <= len, "fuzz consumed");
        expect(guard[128] == 0xa5, "fuzz guard");
        if (status == XRT_GDB_OK)
            expect(view.length <= 128, "fuzz length");
    }
    if (failures) {
        fprintf(stderr, "gdb-packet: %d failures\n", failures);
        return 1;
    }
    puts("C gdb packet: checksum, escape, run-length and fuzz passed");
    return 0;
}
