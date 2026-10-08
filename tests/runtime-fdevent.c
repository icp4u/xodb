#include "../src/runtime/xrt_fdevent.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void put16(unsigned char *p, uint16_t n) { memcpy(p, &n, 2); }
static void put32(unsigned char *p, uint32_t n) { memcpy(p, &n, 4); }
static void put64(unsigned char *p, uint64_t n) { memcpy(p, &n, 8); }
static const struct xrt_fdevent_identity who = {
    .pid = 100, .tid = 101, .enter_id = 201, .exit_id = 202, .enter_type = 301, .exit_type = 302};
static void header(unsigned char *p, size_t n, uint32_t type)
{
    memset(p, 0, n);
    put32(p, type);
    put16(p + 6, (uint16_t)n);
}
static void trailer(unsigned char *p, size_t n)
{
    put32(p + n - 24, 100);
    put32(p + n - 20, 101);
    put64(p + n - 16, 1234);
    put64(p + n - 8, 201);
}
static void sample(unsigned char *p, int enter)
{
    size_t n = enter ? 104 : 64;
    header(p, n, 9);
    put32(p + 8, 100);
    put32(p + 12, 101);
    put64(p + 16, 1234);
    put64(p + 24, enter ? 201 : 202);
    put32(p + 32, enter ? 64 : 24);
    put16(p + 36, enter ? 301 : 302);
    put32(p + 40, 101);
    put64(p + 44, 1);
    if (enter)
        for (unsigned i = 0; i < 6; ++i)
            put64(p + 52 + 8 * i, 10 + i);
    else
        put64(p + 52, (uint64_t)-9);
}
int main(void)
{
    unsigned char p[512];
    struct xrt_fdevent_record out;
    sample(p, 1);
    assert(xrt_fdevent_decode(p, 104, &who, &out));
    assert(out.kind == XRT_FDEVENT_ENTER && out.number == 1 && out.time_ns == 1234);
    for (unsigned i = 0; i < 6; ++i)
        assert(out.args[i] == 10 + i);
    for (size_t n = 0; n < 104; ++n)
        assert(!xrt_fdevent_decode(p, n, &who, &out));
    for (unsigned i = 0; i < 4; ++i) {
        sample(p, 1);
        const unsigned offsets[] = {8, 12, 40, 36};
        p[offsets[i]] ^= 1;
        assert(!xrt_fdevent_decode(p, 104, &who, &out));
    }
    sample(p, 1);
    put64(p + 24, 999);
    assert(!xrt_fdevent_decode(p, 104, &who, &out));
    sample(p, 1);
    put32(p + 32, 63);
    assert(!xrt_fdevent_decode(p, 104, &who, &out));
    sample(p, 1);
    put16(p + 6, 100);
    assert(!xrt_fdevent_decode(p, 104, &who, &out));
    sample(p, 0);
    assert(xrt_fdevent_decode(p, 64, &who, &out));
    assert(out.kind == XRT_FDEVENT_EXIT && out.result == -9);
    /* Linux includes four alignment bytes in these live raw_size values. */
    put32(p + 32, 28);
    assert(xrt_fdevent_decode(p, 64, &who, &out) && out.result == -9);
    sample(p, 1);
    put32(p + 32, 68);
    assert(xrt_fdevent_decode(p, 104, &who, &out) && out.args[5] == 15);
    put32(p + 32, 69);
    assert(!xrt_fdevent_decode(p, 104, &who, &out));
    header(p, 48, 2);
    put64(p + 8, 201);
    put64(p + 16, 37);
    trailer(p, 48);
    assert(xrt_fdevent_decode(p, 48, &who, &out) && out.kind == XRT_FDEVENT_LOST && out.lost == 37);
    put32(p + 24, 999);
    assert(!xrt_fdevent_decode(p, 48, &who, &out));
    for (unsigned type = 5; type <= 6; ++type) {
        header(p, 56, type);
        put64(p + 16, 202);
        trailer(p, 56);
        assert(xrt_fdevent_decode(p, 56, &who, &out) && out.kind == XRT_FDEVENT_THROTTLE);
    }
    header(p, 56, 4);
    put32(p + 8, 100);
    put32(p + 16, 101);
    trailer(p, 56);
    assert(xrt_fdevent_decode(p, 56, &who, &out) && out.kind == XRT_FDEVENT_TASK_EXIT);
    put32(p + 16, 102);
    assert(!xrt_fdevent_decode(p, 56, &who, &out));
    header(p, 48, 3);
    put32(p + 8, 100);
    put32(p + 12, 101);
    trailer(p, 48);
    assert(xrt_fdevent_decode(p, 48, &who, &out) && out.kind == XRT_FDEVENT_IGNORE);
    put16(p + 4, 1u << 13);
    assert(xrt_fdevent_decode(p, 48, &who, &out) && out.kind == XRT_FDEVENT_EXEC);
    memset(p + 16, 'a', 8);
    assert(!xrt_fdevent_decode(p, 48, &who, &out));
    header(p, 56, 7);
    trailer(p, 56);
    assert(xrt_fdevent_decode(p, 56, &who, &out) && out.kind == XRT_FDEVENT_FORK);
    header(p, 56, 12345);
    trailer(p, 56);
    assert(!xrt_fdevent_decode(p, 56, &who, &out));
    struct xrt_fdevent_identity bad = who;
    bad.enter_id = bad.exit_id;
    sample(p, 1);
    assert(!xrt_fdevent_decode(p, 104, &bad, &out));
    /* Bounded malformed byte input: sanitizer checks all integer/length reads. */
    uint32_t rng = 0x12345678;
    for (unsigned run = 0; run < 10000; ++run) {
        for (size_t i = 0; i < sizeof(p); ++i) {
            rng = rng * 1664525u + 1013904223u;
            p[i] = (unsigned char)(rng >> 24);
        }
        size_t n = rng % sizeof(p);
        if (n >= 8)
            put16(p + 6, (uint16_t)n);
        (void)xrt_fdevent_decode(p, n, &who, &out);
    }
    puts("fd event decoder: syscall args/results, exact identities, truncation, loss, lifecycle "
         "and 10000 malformed records pass");
    return 0;
}
