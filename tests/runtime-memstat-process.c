#define _GNU_SOURCE 1
#include "memstat_internal.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[512];
static void put(const char *rel, const char *fmt, ...)
{
    char path[1024]; snprintf(path, sizeof(path), "%s/%s", root, rel);
    for (char *p = path + strlen(root) + 1; *p; ++p) if (*p == '/') {
        *p = 0; assert(mkdir(path, 0755) == 0 || errno == EEXIST); *p = '/';
    }
    FILE *f = fopen(path, "w"); assert(f);
    va_list args; va_start(args, fmt); vfprintf(f, fmt, args); va_end(args);
    assert(fclose(f) == 0);
}
static int remove_one(const char *p, const struct stat *st, int type, struct FTW *f)
{ (void)st; (void)type; (void)f; return remove(p); }
static struct xrt_mem_process *read_process(struct xrt_mem_limits *limits, uint64_t birth, uint64_t begin, uint64_t end)
{
    struct xrt_mem_roots roots = {.proc = root, .sys = root};
    struct xrt_mem_request request = {.flags = XRT_MEM_NUMA, .pid = 42, .start_ticks = birth, .range_start = begin, .range_end = end};
    struct xrt_mem_process *s = xrt_mem_process_read(&roots, limits, &request);
    assert(s); return s;
}
int main(void)
{
    umask(022);
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof(root), "%s/xodb-memproc-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    assert(mkdtemp(root)); assert(chmod(root, 0755) == 0);
    const uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    put("kernel/mm/transparent_hugepage/hpage_pmd_size", "2097152\n");
    put("42/stat", "42 (owned ) mapping) S 1 42 42 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 123 40960 10 0\n");
    put("42/smaps", "%llx-%llx rw-p 00000000 00:00 0 [owned]\nRss: 4 kB\nPss: 4 kB\nAnonymous: 4 kB\nAnonHugePages: 0 kB\nSwap: 4 kB\nTHPeligible: 1\nVmFlags: rd wr mr mw me ac sd hg\n"
        "%llx-%llx r--s 00000000 08:01 99 /fixture/shared\nRss: 8 kB\nPss: 4 kB\nAnonymous: 4 kB\nAnonHugePages: 0 kB\nSwap: 0 kB\nTHPeligible: 0\nVmFlags: rd mr ms\n",
        (unsigned long long)page, (unsigned long long)(4 * page), (unsigned long long)(8 * page), (unsigned long long)(10 * page));
    put("42/smaps_rollup", "Rss: 12 kB\nAnonymous: 8 kB\nAnonHugePages: 0 kB\nSwap: 4 kB\n");
    put("42/numa_maps", "%llx default anon=1 N0=2 N1=1 kernelpagesize_kB=4\n%llx default file=/fixture/shared N1=2\n", (unsigned long long)page, (unsigned long long)(8 * page));
    char path[1024]; snprintf(path, sizeof(path), "%s/42/pagemap", root);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644); assert(fd >= 0);
    uint64_t bits[10] = {0};
    bits[1] = (UINT64_C(1) << 63) | (UINT64_C(1) << 56) | (UINT64_C(1) << 55) | 0x12345;
    bits[2] = (UINT64_C(1) << 62) | (UINT64_C(1) << 55) | 0xabc;
    bits[3] = UINT64_C(1) << 55;
    bits[8] = (UINT64_C(1) << 63) | (UINT64_C(1) << 61) | 0xbeef;
    bits[9] = UINT64_C(1) << 63;
    assert(write(fd, bits, sizeof(bits)) == sizeof(bits)); assert(close(fd) == 0);
    struct xrt_mem_limits limits; xrt_mem_limits_default(&limits);
    struct xrt_mem_process *s = read_process(&limits, 0, 0, 0);
    assert(s->maps_status.state == XRT_MEM_OK && s->start_ticks == 123 && !strcmp(s->name, "owned ) mapping"));
    assert(s->vma_count == 2 && s->mapped_bytes == 5 * page && s->rss == 12288 && s->anonymous == 8192 && s->swap == 4096);
    assert(s->totals_known == (XRT_MEM_RSS | XRT_MEM_ANONYMOUS | XRT_MEM_ANON_HUGE | XRT_MEM_SWAP));
    assert(s->eligible_anonymous == 4096 && s->eligible_anon_huge == 0 && s->unknown_eligibility_anonymous == 0);
    assert(s->coverage_denominator_known && s->coverage_numerator_known && !s->coverage_denominator);
    assert(s->rollup_status.state == XRT_MEM_UNAVAILABLE && !s->rollup_known);
    assert(s->numa_status.state == XRT_MEM_OK && s->vmas[0].numa_count == 2 && s->vmas[1].numa_count == 1);
    assert(s->vmas[0].numa_page_size == 4096);
    assert(s->vmas[0].numa_available && s->vmas[0].numa[1].node == 1 && s->vmas[1].numa[0].pages == 2);
    assert(s->pages_status.state == XRT_MEM_OK && s->range_count == 5 && s->scanned_bytes == 5 * page);
    assert(s->ranges[0].categories == (XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_EXCLUSIVE | XRT_MEM_PAGE_SOFT_DIRTY));
    assert(s->ranges[1].categories == (XRT_MEM_PAGE_SWAPPED | XRT_MEM_PAGE_SOFT_DIRTY));
    assert(s->ranges[2].categories == XRT_MEM_PAGE_SOFT_DIRTY);
    assert(s->ranges[3].categories == (XRT_MEM_PAGE_PRESENT | XRT_MEM_PAGE_FILE));
    for (uint32_t i = 0; i < s->range_count; ++i) {
        assert(s->ranges[i].backend == XRT_MEM_BACKEND_PAGEMAP);
        assert(!(s->ranges[i].known & (XRT_MEM_PAGE_HUGE | XRT_MEM_PAGE_ZERO | XRT_MEM_PAGE_WRITTEN)));
    }
    xrt_mem_process_free(s);
    {
        struct xrt_mem_roots roots = {.proc = root, .sys = root};
        struct xrt_mem_request request = {.pid = 42, .flags = XRT_MEM_SKIP_PAGES};
        s = xrt_mem_process_read(&roots, &limits, &request); assert(s);
        assert(s->numa_status.state == XRT_MEM_UNAVAILABLE && !s->vmas[0].numa_available);
        assert(s->rollup_status.state == XRT_MEM_UNAVAILABLE && !s->rollup_known);
        xrt_mem_process_free(s);
        request.pid = 43;
        s = xrt_mem_process_read(&roots, &limits, &request); assert(s);
        assert(s->maps_status.state == XRT_MEM_EXITED && !s->name[0] && !s->vma_count);
        xrt_mem_process_free(s);
        roots.proc = "/nonexistent-memory-fixture-root";
        s = xrt_mem_process_read(&roots, &limits, &request); assert(s);
        assert(s->maps_status.state == XRT_MEM_UNAVAILABLE);
        xrt_mem_process_free(s);
    }
    s = read_process(&limits, 124, 0, 0);
    assert(s->maps_status.state == XRT_MEM_IDENTITY_CHANGED && !s->vma_count && !s->range_count && !s->name[0]);
    xrt_mem_process_free(s);
    s = read_process(&limits, 123, 8 * page, 10 * page);
    assert(s->vma_count == 2 && s->range_count == 2 && s->ranges[0].start == 8 * page && s->scanned_bytes == 2 * page);
    xrt_mem_process_free(s);
    limits.pages = 2;
    s = read_process(&limits, 123, 0, 0);
    assert(s->pages_status.state == XRT_MEM_PARTIAL && s->scanned_bytes == 2 * page && s->scan_resume == 3 * page);
    xrt_mem_process_free(s);
    xrt_mem_limits_default(&limits); limits.ranges = 1;
    s = read_process(&limits, 123, 0, 0);
    assert(s->pages_status.state == XRT_MEM_PARTIAL && s->range_count == 1 && s->scan_resume == 2 * page);
    xrt_mem_process_free(s);
    xrt_mem_limits_default(&limits); limits.path_bytes = 1;
    s = read_process(&limits, 123, 0, 0);
    assert(s->maps_status.state == XRT_MEM_PARTIAL && s->vma_count == 2 && s->vmas[0].flags & XRT_MEM_PATH_CUT);
    assert(s->rollup_status.state == XRT_MEM_OK && s->rollup_rss == 12288 && s->rollup_anon_huge == 0);
    xrt_mem_process_free(s);
    xrt_mem_limits_default(&limits);
    put("42/smaps", "%llx-%llx rw-p 0 00:00 0\nRss: 4 kB\nRss: 8 kB\nAnonymous: 4 kB\nAnonHugePages: 0 kB\n", (unsigned long long)page, (unsigned long long)(4 * page));
    s = read_process(&limits, 123, 0, 0);
    assert(s->maps_status.state == XRT_MEM_PARTIAL && s->vma_count == 1 && !s->vmas[0].known && !s->totals_known && !s->rss);
    assert(s->vmas[0].flags & XRT_MEM_BAD_METRIC);
    xrt_mem_process_free(s);
    const uint64_t h = 2u << 20;
    put("42/smaps", "%llx-%llx rw-p 0 00:00 0 [anon:fixture]\nRss: 4096 kB\nAnonymous: 4096 kB\nAnonHugePages: 2048 kB\nTHPeligible: 1\nVmFlags: rd wr hg\n", (unsigned long long)(h-page), (unsigned long long)(3*h+page));
    s = read_process(&limits, 123, h, 2*h);
    assert(s->coverage_numerator_known && s->coverage_denominator_known);
    assert(s->coverage_denominator == 2*h && s->coverage_numerator == h);
    xrt_mem_process_free(s);
    put("kernel/mm/transparent_hugepage/hpage_pmd_size", "bad\n");
    s = read_process(&limits, 123, h, 2*h);
    assert(!s->pmd_size_known && !s->coverage_denominator_known && !s->coverage_numerator_known);
    xrt_mem_process_free(s);
    /* Large but bounded metadata inventories retain complete coverage. */
    snprintf(path, sizeof(path), "%s/42/smaps", root);
    FILE *many = fopen(path, "w"); assert(many);
    for (unsigned i = 0; i < 20000; ++i) {
        unsigned long long start = (unsigned long long)(i + 1) * 2 * page;
        assert(fprintf(many, "%llx-%llx rw-p 0 00:00 0\nRss: 0 kB\nAnonymous: 0 kB\nAnonHugePages: 0 kB\nSwap: 0 kB\nTHPeligible: 0\nVmFlags: rd wr nh\n", start, start + page) > 0);
    }
    assert(!fclose(many));
    put("kernel/mm/transparent_hugepage/hpage_pmd_size", "2097152\n");
    struct xrt_mem_roots roots = {.proc = root, .sys = root};
    struct xrt_mem_request metadata = {.pid = 42, .flags = XRT_MEM_SKIP_PAGES};
    s = xrt_mem_process_read(&roots, &limits, &metadata); assert(s);
    assert(s->maps_status.state == XRT_MEM_OK && s->vma_count == 20000);
    assert(s->coverage_denominator_known && s->coverage_numerator_known && !s->coverage_denominator && !s->coverage_numerator);
    xrt_mem_process_free(s);
    /* A known kernel gate is mapped, but unobserved; scanning continues after
     * it. The ordinary mapping must still get real fallback page metadata. */
    put("42/smaps", "%llx-%llx --xp 0 00:00 0 [vsyscall]\n"
        "%llx-%llx r--p 0 00:00 0 /fixture/later\n",
        (unsigned long long)page, (unsigned long long)(2 * page),
        (unsigned long long)(8 * page), (unsigned long long)(10 * page));
    s = read_process(&limits, 123, 0, 0);
    assert(s->maps_status.state == XRT_MEM_OK && s->pages_status.state == XRT_MEM_OK);
    assert(s->vma_count == 2 && s->range_count == 3 && s->scanned_bytes == 2 * page);
    assert(s->ranges[0].backend == XRT_MEM_BACKEND_NONE && !s->ranges[0].known && !s->ranges[0].categories);
    assert(s->ranges[0].start == page && s->ranges[0].end == 2 * page);
    assert(s->ranges[1].backend == XRT_MEM_BACKEND_PAGEMAP && s->ranges[1].categories & XRT_MEM_PAGE_PRESENT);
    struct xrt_mem_cell gate;
    assert(xrt_mem_cell_read(s, NULL, page, 2 * page, &gate));
    assert(gate.mapping_known && gate.mapped_bytes == page && !gate.observed_bytes && !gate.known);
    xrt_mem_process_free(s);
    /* Growing reads distinguish EOF at the cap from truncation and retain
     * partial-line and embedded-NUL validation after several growth steps. */
    int dir = open(root, O_RDONLY | O_DIRECTORY); assert(dir >= 0);
    char text[16386]; memset(text, 'x', sizeof(text)); text[sizeof(text) - 1] = 0;
    put("text", "%s", text);
    size_t length; struct xrt_mem_status status;
    char *read = xrt_mem_text(dir, "text", sizeof(text) - 1, &length, &status);
    assert(read && length == sizeof(text) - 1 && status.state == XRT_MEM_OK && !read[length]); free(read);
    read = xrt_mem_text(dir, "text", sizeof(text) - 2, &length, &status);
    assert(read && length == sizeof(text) - 2 && status.state == XRT_MEM_PARTIAL && !read[length]); free(read);
    put("text", "");
    read = xrt_mem_text(dir, "text", limits.text_bytes, &length, &status);
    assert(read && !length && status.state == XRT_MEM_OK && !read[0]); free(read);
    put("text", "abc%cdef", 0);
    read = xrt_mem_text(dir, "text", limits.text_bytes, &length, &status);
    assert(read && length == 7 && status.state == XRT_MEM_INVALID); free(read);
    assert(!close(dir));
    assert(nftw(root, remove_one, 16, FTW_DEPTH | FTW_PHYS) == 0);
    puts("memory process: smaps, rollup, NUMA, identity, fallback flags, PFN omission and scan bounds passed");
    return 0;
}
