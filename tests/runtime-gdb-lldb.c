#include "gdb_lldb.h"
#include "check.h"
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
static void stops(void)
{
    struct xrt_gdb_stop stop;
    const char *bad_access = "T91thread:1001;metype:1;mecount:2;medata:1;medata:10;";
    CHECK(xrt_gdb_stop_parse(bad_access, strlen(bad_access), &stop) == XRT_OK);
    if (getenv("XRT_MACH_STOP_WRONG_RESULT")) stop.codes[1] = 17;
    CHECK(stop.has_exception && stop.exception == 1 && stop.code_count == 2 && stop.codes[1] == 16 && !stop.exec);
    const char *exec = "T05thread:1002;reason:exec;";
    CHECK(xrt_gdb_stop_parse(exec, strlen(exec), &stop) == XRT_OK && stop.exec && !stop.has_exception);
    const char *unknown = "T91metype:ffff;mecount:1;medata:ffffffffffffffff;";
    CHECK(xrt_gdb_stop_parse(unknown, strlen(unknown), &stop) == XRT_OK && stop.exception == 65535 && stop.codes[0] == UINT64_MAX);
    const char *bad[] = {"T91metype:1;", "T91mecount:0;", "T91medata:1;", "T91metype:0;mecount:0;",
        "T91metype:1;metype:1;mecount:0;", "T91metype:1;mecount:2;medata:1;",
        "T91metype:1;mecount:5;", "T91metype:1;mecount:0;mecount:0;", "T91metype:1;mecount:1;medata:-1;",
        "T91reason:exec;reason:exec;", "T91metype:1;mecount:0;reason:exec;", "Txx", "S91"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        CHECK(xrt_gdb_stop_parse(bad[i], strlen(bad[i]), &stop) == XRT_PROTOCOL_ERROR);
    struct xrt_gdb_host h = {0};
    CHECK(xrt_gdb_process_parse(process, strlen(process), &h) == XRT_OK);
    CHECK(h.cputype == 0x100000c && h.pointer_size == 8 && h.has_endian && h.little_endian && h.os == XRT_GDB_OS_DARWIN);
    const char *bad_process[] = {"cputype:100000000;", "cputype:1;cputype:2;", "ptrsize:3;", "ptrsize:8;ptrsize:8;",
        "endian:sideways;", "endian:little;endian:big;", "ostype:macosx;ostype:linux;"};
    for (size_t i = 0; i < sizeof(bad_process) / sizeof(bad_process[0]); ++i)
        CHECK(xrt_gdb_process_parse(bad_process[i], strlen(bad_process[i]), &h) == XRT_PROTOCOL_ERROR);
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
    /* UUID/header/segments are retained; unknown members remain skippable. */
    const char *full = " { \"other\" : [1,2.5e-3,true,null,{\"a\":\"b\\\"c\"}] , \"images\" : [ {\"mach_header\":{\"magic\":4277009103,\"cputype\":16777228,\"cpusubtype\":2,\"filetype\":2},"
        "\"uuid\":\"01234567-89AB-CDEF-0123-456789ABCDEF\","
        "\"segments\":[{\"name\":\"__TEXT\",\"vmaddr\":0,\"vmsize\":4096,\"maxprot\":5}],\"pathname\":\"a\\/b\\u00e9\\n\",\"load_address\":16 } ] } ";
    assert(parse_images(full, rows, 4, &total) == XRT_OK && total == 1);
    assert(rows[0].load_address == 16 && !strcmp(rows[0].path, "a/b??"));
    assert(rows[0].has_uuid && rows[0].uuid[15] == 0xef && rows[0].has_header && rows[0].cpusubtype == 2);
    assert(rows[0].segment_count == 1 && rows[0].segments[0].vmsize == 4096 && rows[0].segments[0].maxprot == 5);
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
        "{\"images\":[{\"load_address\":1 \"x\":1}]}", "{images:[]}",
        "{\"images\":[{\"load_address\":1,\"uuid\":\"bad\"}]}",
        "{\"images\":[{\"load_address\":1,\"mach_header\":{\"cputype\":1}}]}",
        "{\"images\":[{\"load_address\":1,\"segments\":[{\"name\":\"__TEXT\",\"vmaddr\":18446744073709551615,\"vmsize\":1,\"maxprot\":5}]}]}"};
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
static void thread_lists(void)
{
    static const char sample[] = "[{\"tid\":4097,\"qaddr\":8192,\"name\":\"worker\\n\\u001b\",\"registers\":{\"0\":\"01000000\"}},"
        "{\"tid\":4098,\"qaddr\":0,\"reason\":\"none\"}]";
    struct { struct xrt_gdb_thread_info rows[2]; uint64_t canary; } out = {.canary = 771};
    size_t count;
    CHECK(xrt_gdb_threads_parse(sample, sizeof sample - 1, out.rows, 2, &count) == XRT_OK && count == 2);
    CHECK(out.rows[0].remote_tid == 4097 && !out.rows[0].has_dispatch_queue);
    CHECK(out.rows[0].has_name && !strcmp(out.rows[0].name, "worker??"));
    CHECK(!out.rows[1].has_name && !out.rows[1].has_dispatch_queue && out.canary == 771);
    uint64_t queue=0;
    const char extended[]="{\"pthread_t\":1,\"dispatch_queue_t\":8192}";
    CHECK(xrt_gdb_thread_extended_parse(extended,sizeof extended-1,&queue)==XRT_OK && queue==8192);
    if (getenv("XRT_THREAD_INFO_WRONG_RESULT")) queue++;
    CHECK(queue == 8192);
    static const char *bad[] = {"{}", "[{}]", "[{\"tid\":0}]", "[{\"tid\":-1}]", "[{\"tid\":4294967296}]",
        "[{\"tid\":1.0}]", "[{\"tid\":1,\"tid\":2}]", "[{\"tid\":1},{\"tid\":1}]", "[{\"tid\":1,\"name\":null}]",
        "[{\"tid\":1,\"qaddr\":-1}]", "[{\"tid\":1,\"qaddr\":0,\"qaddr\":1}]", "[{\"tid\":1},]", "[]x"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; ++i)
        CHECK(xrt_gdb_threads_parse(bad[i], strlen(bad[i]), out.rows, 2, &count) == XRT_PROTOCOL_ERROR);
    for (size_t n = 0; n < sizeof sample - 1; ++n) {
        CHECK(xrt_gdb_threads_parse(sample, n, out.rows, 2, &count) != XRT_OK);
        CHECK(out.canary == 771);
    }
    char long_name[400];
    memcpy(long_name, "[{\"tid\":1,\"name\":\"", 18);
    memset(long_name + 18, 'a', 300);
    strcpy(long_name + 318, "\"}]");
    CHECK(xrt_gdb_threads_parse(long_name, strlen(long_name), out.rows, 2, &count) == XRT_OK);
    CHECK(strlen(out.rows[0].name) == 127 && out.rows[0].name_truncated);
    size_t size = (XRT_MAX_THREADS + 1) * 24 + 4;
    char *many = malloc(size); CHECK(many);
    for (unsigned n = XRT_MAX_THREADS; n <= XRT_MAX_THREADS + 1; ++n) {
        size_t at = 0; many[at++] = '[';
        for (unsigned i = 0; i < n; ++i) at += (size_t)sprintf(many + at, "%s{\"tid\":%u}", i ? "," : "", i + 1);
        strcpy(many + at, "]");
        CHECK(xrt_gdb_threads_parse(many, strlen(many), out.rows, 2, &count) ==
            (n == XRT_MAX_THREADS ? XRT_OK : XRT_BUFFER_TOO_SMALL));
        CHECK(count == XRT_MAX_THREADS && out.canary == 771);
    }
    free(many);
}
int main(void)
{
    hosts(); stops(); regions(); image_lists(); thread_lists();
    damaged(host); damaged(process); damaged(region); damaged(images);
    puts("GDB LLDB extensions: host, process, region and image replies, bounds and damaged input pass");
}
