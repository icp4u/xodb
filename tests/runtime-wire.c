#define _GNU_SOURCE 1
#include "xrt_wire.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static void codec(void)
{
    uint8_t bytes[16] = {0};
    uint16_t a = 0x1234;
    uint32_t b = 0x89abcdef;
    uint64_t d = UINT64_C(0x0102030405060708);
    bool yes = true;
    struct xrt_codec c = xrt_codec(bytes, sizeof(bytes), false);
    xrt_codec_u16(&c, &a);
    xrt_codec_u32(&c, &b);
    xrt_codec_u64(&c, &d);
    xrt_codec_bool(&c, &yes);
    assert(c.ok && c.at == 15);
    assert(!memcmp(bytes,
                   (uint8_t[]){0x12, 0x34, 0x89, 0xab, 0xcd, 0xef, 1, 2, 3, 4, 5, 6, 7, 8, 1}, 15));
    for (size_t length = 0; length < 15; ++length) {
        c = xrt_codec(bytes, length, true);
        a = 0;
        b = 0;
        d = 0;
        yes = false;
        xrt_codec_u16(&c, &a);
        xrt_codec_u32(&c, &b);
        xrt_codec_u64(&c, &d);
        xrt_codec_bool(&c, &yes);
        assert(!c.ok && c.at <= length);
    }
    bytes[14] = 2;
    c = xrt_codec(bytes + 14, 1, true);
    yes = false;
    xrt_codec_bool(&c, &yes);
    assert(!c.ok && !yes);
}
static void headers(void)
{
    struct xrt_wire_frame f = {.op = 7,
                               .request = UINT64_C(0x0102030405060708),
                               .target = 5,
                               .status = 0,
                               .size = 6,
                               .flags = 1},
                          out = {0};
    uint8_t b[32];
    assert(xrt_wire_header_encode(&f, b));
    assert(!memcmp(b, "XRT1\0\1\0\7", 8));
    assert(xrt_wire_header_decode(b, &out));
    assert(out.request == f.request && out.target == 5 && out.size == 6 && out.flags == 1);
    for (size_t i = 0; i < 6; ++i) {
        uint8_t old = b[i];
        b[i] ^= 1;
        assert(!xrt_wire_header_decode(b, &out));
        b[i] = old;
    }
    b[28] = 1;
    assert(!xrt_wire_header_decode(b, &out));
    assert(xrt_wire_header_encode(&f, b));
    b[24] = 1;
    assert(!xrt_wire_header_decode(b, &out));
    f.size = XRT_WIRE_MAX_BODY + 1;
    assert(!xrt_wire_header_encode(&f, b));
    f.size = 0;
    f.request = 0;
    assert(!xrt_wire_header_encode(&f, b));
}
static void streams(void)
{
    int p[2];
    assert(!pipe2(p, O_CLOEXEC | O_NONBLOCK));
    struct xrt_wire_frame f = {.op = 1, .request = 1, .size = 4}, out = {0};
    uint8_t body[8] = {0};
    assert(xrt_wire_read(p[0], &out, body, sizeof(body), 10) == XRT_WIRE_TIMEOUT);
    uint8_t frame[36];
    assert(xrt_wire_header_encode(&f, frame));
    memcpy(frame + 32, "data", 4);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        close(p[0]);
        for (size_t i = 0; i < sizeof(frame); ++i) {
            if (write(p[1], frame + i, 1) != 1)
                _exit(1);
            usleep(100);
        }
        close(p[1]);
        _exit(0);
    }
    close(p[1]);
    assert(xrt_wire_read(p[0], &out, body, sizeof(body), 1000) == XRT_WIRE_OK);
    assert(!memcmp(body, "data", 4) && out.request == 1);
    assert(xrt_wire_read(p[0], &out, body, sizeof(body), 1000) == XRT_WIRE_EOF);
    close(p[0]);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(!pipe2(p, O_CLOEXEC | O_NONBLOCK));
    assert(write(p[1], frame, 34) == 34);
    close(p[1]);
    assert(xrt_wire_read(p[0], &out, body, sizeof(body), 100) == XRT_WIRE_INVALID);
    close(p[0]);
    assert(!pipe2(p, O_CLOEXEC | O_NONBLOCK));
    assert(xrt_wire_write(p[1], &f, "data", 100) == XRT_WIRE_OK);
    assert(xrt_wire_read(p[0], &out, body, 3, 100) == XRT_WIRE_INVALID);
    close(p[0]);
    assert(xrt_wire_write(p[1], &f, "data", 100) == XRT_WIRE_IO);
    close(p[1]);
}
int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    codec();
    headers();
    streams();
    puts("C wire: byte-order goldens, bounds, invalid frames, fragmentation, EOF and deadlines "
         "passed");
    return 0;
}
