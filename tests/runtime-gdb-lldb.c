#include "gdb_lldb.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Reply shapes recorded from Apple's debugserver (process identities synthetic). */
static const char host[] = "cputype:16777228;cpusubtype:2;addressing_bits:47;ostype:macosx;"
    "watchpoint_exceptions_received:before;vendor:apple;os_version:26.6.0;maccatalyst_version:26.6;"
    "endian:little;ptrsize:8;vm-page-size:16384;";
static const char process[] = "pid:4d2;parent-pid:4d1;real-uid:3e8;real-gid:3e8;effective-uid:3e8;"
    "effective-gid:3e8;cputype:100000c;cpusubtype:0;ptrsize:8;ostype:macosx;vendor:apple;endian:little;";
static const char region[] = "start:104aec000;size:30000;permissions:rw;"
    "dirty-pages:104aec000,104af0000,104af4000;type:malloc-metadata;";
static const char images[] = "{\"images\":[{\"load_address\":4307566592,\"mod_date\":0,"
    "\"pathname\":\"/tmp/xodb-fixture/fixture\"},{\"load_address\":6554304512,\"mod_date\":0,"
    "\"pathname\":\"/usr/lib/libobjc.A.dylib\"}]}";

static enum xrt_status parse_region(const char *text, bool cut, uint64_t asked, struct xrt_gdb_region *out)
{
    return xrt_gdb_region_parse(text, strlen(text), cut, asked, out);
}
static enum xrt_status parse_images(const char *text, struct xrt_gdb_image *out, size_t capacity, size_t *total)
{
    return xrt_gdb_images_parse(text, strlen(text), out, capacity, total);
}
static void hosts(void)
{
    struct xrt_gdb_host h = {0};
    assert(xrt_gdb_host_parse(host, strlen(host), &h) == XRT_OK);
    assert(h.os == XRT_GDB_OS_DARWIN && h.cputype == 0x0100000c && h.address_bits == 47);
    assert(xrt_gdb_process_parse(process, strlen(process), &h) == XRT_OK && h.pid == 0x4d2);
    const char *linux_host = "ostype:linux;vendor:pc;ptrsize:8";
    assert(xrt_gdb_host_parse(linux_host, strlen(linux_host), &h) == XRT_OK && h.os == XRT_GDB_OS_LINUX);
    const char *other = "ostype:plan9;";
    assert(xrt_gdb_host_parse(other, strlen(other), &h) == XRT_OK && h.os == XRT_GDB_OS_UNKNOWN);
    const char *bad[] = {"vendor", ":apple;", "cputype:x;", "cputype:4294967296;", "cputype:1;cputype:1;",
        "addressing_bits:0;", "addressing_bits:65;", "vendor:apple;vendor:apple;", "ostype:a;ostype:b;",
        "cputype:184467440737095516160;"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        assert(xrt_gdb_host_parse(bad[i], strlen(bad[i]), &h) == XRT_PROTOCOL_ERROR);
    const char *bad_process[] = {"pid:0;", "pid:;", "pid:80000000;", "pid:1;pid:2;", "pid:zz;", "pid"};
    for (size_t i = 0; i < sizeof(bad_process) / sizeof(bad_process[0]); ++i)
        assert(xrt_gdb_process_parse(bad_process[i], strlen(bad_process[i]), &h) == XRT_PROTOCOL_ERROR);
    assert(xrt_gdb_host_parse("vendor:apple;\0x", 15, &h) == XRT_PROTOCOL_ERROR);
    assert(xrt_gdb_host_parse("", 0, &h) == XRT_PROTOCOL_ERROR);
}
static void regions(void)
{
    struct xrt_gdb_region r;
    assert(parse_region(region, false, 0x104aec000, &r) == XRT_OK);
    assert(r.start == 0x104aec000 && r.size == 0x30000 && r.mapped && r.read && r.write && !r.execute);
    assert(!strcmp(r.type, "malloc-metadata") && !r.name[0]);
    assert(parse_region(region, false, 0x104aec000 + 0x2ffff, &r) == XRT_OK);
    /* The reply must cover the address asked, or a walk could loop or skip. */
    assert(parse_region(region, false, 0x104aec000 + 0x30000, &r) == XRT_PROTOCOL_ERROR);
    assert(parse_region(region, false, 0x104aebfff, &r) == XRT_PROTOCOL_ERROR);
    assert(parse_region("start:0;size:100b70000;", false, 0, &r) == XRT_OK && !r.mapped && r.size == 0x100b70000);
    /* End of the address space: a start without a size. */
    assert(parse_region("start:ffffffffffffffff;", false, UINT64_MAX, &r) == XRT_OK && !r.size);
    assert(parse_region("start:ffffffffffff0000;size:10000;", false, 0xffffffffffff0000, &r) == XRT_OK);
    assert(parse_region("start:ffffffffffff0000;size:10001;", false, 0xffffffffffff0000, &r) == XRT_PROTOCOL_ERROR);
    assert(parse_region("start:1000;size:1000;permissions:rx;name:2f746d702f6101ff;", false, 0x1000, &r) == XRT_OK);
    assert(!strcmp(r.name, "/tmp/a??") && r.execute);
    /* A raw prefix of an oversized reply: the incomplete last pair is dropped. */
    assert(parse_region("start:1000;size:1000;permissions:rw;dirty-pages:1000,20", true, 0x1000, &r) == XRT_OK);
    assert(r.size == 0x1000 && r.write);
    assert(parse_region("start:1000;si", true, 0x1000, &r) == XRT_PROTOCOL_ERROR);
    assert(parse_region("start:1000;size:1000;name:}]", true, 0x1000, &r) == XRT_PROTOCOL_ERROR);
    assert(parse_region("start:1000;size:10* ;", true, 0x1000, &r) == XRT_PROTOCOL_ERROR);
    const char *bad[] = {"size:1000;", "start:1000;size:0;", "start:1000;start:1000;size:1;",
        "start:1000;size:1000;size:1000;", "start:1000;size:1000;permissions:rwxr;",
        "start:1000;size:1000;permissions:rr;", "start:1000;size:1000;permissions:q;",
        "start:1000;size:1000;permissions:r;permissions:r;", "start:1000;size:1000;name:abc;",
        "start:1000;size:1000;name:zz;", "start:1000;size:1000;name:41;name:41;",
        "start:10000000000000000;size:1;", "start:1000;size:1000;junk", "start:g;size:1;", "E08"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        assert(parse_region(bad[i], false, 0x1000, &r) == XRT_PROTOCOL_ERROR);
    char longname[1200] = "start:1000;size:1000;name:";
    for (size_t i = strlen(longname); i < sizeof(longname) - 2; ++i) longname[i] = "41"[i & 1];
    longname[sizeof(longname) - 2] = ';'; longname[sizeof(longname) - 1] = 0;
    assert(parse_region(longname, false, 0x1000, &r) == XRT_OK && strlen(r.name) == sizeof(r.name) - 1);
}
static void image_lists(void)
{
    struct xrt_gdb_image rows[4]; size_t total;
    assert(parse_images(images, rows, 4, &total) == XRT_OK && total == 2);
    assert(rows[0].load_address == 4307566592u && !strcmp(rows[0].path, "/tmp/xodb-fixture/fixture"));
    assert(rows[1].load_address == 6554304512u && !rows[1].path_truncated);
    /* More rows than the caller holds: counted, never stored. */
    rows[1].load_address = 7;
    assert(parse_images(images, rows, 1, &total) == XRT_OK && total == 2 && rows[1].load_address == 7);
    assert(parse_images(images, NULL, 0, &total) == XRT_OK && total == 2);
    /* Load commands and unknown members are skipped, whatever their shape. */
    const char *full = " { \"other\" : [1,2.5e-3,true,null,{\"a\":\"b\\\"c\"}] , \"images\" : [ {\"mach_header\":{\"magic\":4277009103},"
        "\"segments\":[{\"name\":\"__TEXT\",\"vmaddr\":0}],\"pathname\":\"a\\/b\\u00e9\\n\",\"load_address\":16 } ] } ";
    assert(parse_images(full, rows, 4, &total) == XRT_OK && total == 1);
    assert(rows[0].load_address == 16 && !strcmp(rows[0].path, "a/b??"));
    assert(parse_images("{\"images\":[]}", rows, 4, &total) == XRT_OK && !total);
    char longpath[900]; int n = snprintf(longpath, sizeof(longpath), "{\"images\":[{\"load_address\":1,\"pathname\":\"");
    memset(longpath + n, 'p', 600); strcpy(longpath + n + 600, "\"}]}");
    assert(parse_images(longpath, rows, 4, &total) == XRT_OK && rows[0].path_truncated);
    assert(strlen(rows[0].path) == sizeof(rows[0].path) - 1);
    const char *bad[] = {"", "[]", "{}", "{\"images\":{}}", "{\"images\":[{}]}", "{\"images\":[1]}",
        "{\"images\":[{\"pathname\":\"a\"}]}", "{\"images\":[{\"load_address\":-1}]}",
        "{\"images\":[{\"load_address\":1.0}]}", "{\"images\":[{\"load_address\":1e3}]}",
        "{\"images\":[{\"load_address\":\"1\"}]}", "{\"images\":[{\"load_address\":18446744073709551616}]}",
        "{\"images\":[{\"load_address\":01}]}", "{\"images\":[{\"load_address\":1,\"load_address\":1}]}",
        "{\"images\":[{\"load_address\":1,\"pathname\":\"a\",\"pathname\":\"b\"}]}",
        "{\"images\":[{\"load_address\":1}],\"images\":[]}", "{\"images\":[{\"load_address\":1},]}",
        "{\"images\":[{\"load_address\":1}]}x", "{\"images\":[{\"load_address\":1}]", "{\"images\":[{\"load_address\":1,\"pathname\":\"a",
        "{\"images\":[{\"load_address\":1,\"pathname\":\"a\\q\"}]}", "{\"images\":[{\"load_address\":1,\"pathname\":\"a\\u00g0\"}]}",
        "{\"images\":[{\"load_address\":1,\"pathname\":\"a\tb\"}]}", "{\"images\":[{\"load_address\":1,\"x\":tru}]}",
        "{\"images\":[{\"load_address\":1 \"x\":1}]}", "{images:[]}"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        assert(parse_images(bad[i], rows, 4, &total) == XRT_PROTOCOL_ERROR);
    /* Nesting is bounded: depth 12 inside an image is accepted, depth 40 is not. */
    for (unsigned depth = 12; depth <= 40; depth += 28) {
        char nested[256] = "{\"images\":[{\"load_address\":1,\"x\":"; size_t at = strlen(nested);
        for (unsigned i = 0; i < depth; ++i) nested[at++] = '[';
        for (unsigned i = 0; i < depth; ++i) nested[at++] = ']';
        strcpy(nested + at, "}]}");
        assert(parse_images(nested, rows, 4, &total) == (depth == 12 ? XRT_OK : XRT_PROTOCOL_ERROR));
    }
    /* The image count is capped even when the caller stores none. */
    size_t size = 20 * (XRT_GDB_IMAGES_MAX + 1) + 32;
    char *many = malloc(size); assert(many);
    for (unsigned count = XRT_GDB_IMAGES_MAX; count <= XRT_GDB_IMAGES_MAX + 1; ++count) {
        size_t at = (size_t)sprintf(many, "{\"images\":[");
        for (unsigned i = 0; i < count; ++i) at += (size_t)sprintf(many + at, "%s{\"load_address\":1}", i ? "," : "");
        strcpy(many + at, "]}");
        assert(parse_images(many, rows, 4, &total) == (count == XRT_GDB_IMAGES_MAX ? XRT_OK : XRT_BUFFER_TOO_SMALL));
        assert(total == XRT_GDB_IMAGES_MAX);
    }
    free(many);
}
/* Every prefix and many damaged copies of the recorded replies: any status is
 * fine, but no read past the given length (the copy is exact-sized, for the
 * sanitizer and allocator to notice) and no row past the capacity. */
static uint32_t state = 0x9e3779b9;
static uint32_t random32(void) { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state; }
static void damaged(const char *sample)
{
    size_t size = strlen(sample);
    for (unsigned round = 0; round < 20000 + size; ++round) {
        size_t length = round < size ? round : size;
        char *copy = malloc(length ? length : 1); assert(copy);
        memcpy(copy, sample, length);
        if (round >= size) {
            for (unsigned flips = 1 + random32() % 4; flips; --flips)
                copy[random32() % length] = (char)(random32() % 3 ? "{}[]\",:;\\0-eu\t*}"[random32() % 16] : (char)random32());
            if (random32() % 4 == 0) length = random32() % (length + 1);
        }
        struct xrt_gdb_host h = {0}; struct xrt_gdb_region r; size_t total = 99;
        struct { struct xrt_gdb_image rows[2]; uint64_t canary; } out = {.canary = UINT64_C(0xa5a5a5a5a5a5a5a5)};
        (void)xrt_gdb_host_parse(copy, length, &h);
        (void)xrt_gdb_process_parse(copy, length, &h);
        assert(h.address_bits <= 64 && h.pid <= INT32_MAX);
        if (xrt_gdb_region_parse(copy, length, random32() & 1, 0x104aec000, &r) == XRT_OK) {
            assert(memchr(r.name, 0, sizeof(r.name)) && memchr(r.type, 0, sizeof(r.type)));
            assert(!r.size || (r.start <= 0x104aec000 && 0x104aec000 - r.start < r.size));
        }
        enum xrt_status status = xrt_gdb_images_parse(copy, length, out.rows, 2, &total);
        assert(out.canary == UINT64_C(0xa5a5a5a5a5a5a5a5) && total <= XRT_GDB_IMAGES_MAX);
        if (status == XRT_OK) for (size_t i = 0; i < total && i < 2; ++i)
            assert(memchr(out.rows[i].path, 0, sizeof(out.rows[i].path)));
        free(copy);
    }
}
int main(void)
{
    hosts(); regions(); image_lists();
    damaged(host); damaged(process); damaged(region); damaged(images);
    puts("GDB LLDB extensions: host, process, region and image replies, bounds and damaged input pass");
}
