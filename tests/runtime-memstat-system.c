#define _GNU_SOURCE 1
/* Invented Linux memory sources; no host data enters this fixture. */
#include "xrt_memstat.h"
#include <assert.h>
#include <errno.h>
#include <ftw.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[512], proc[640], sys[640];
static void put(const char *rel, const char *fmt, ...)
{
    char path[1024];
    int n = snprintf(path, sizeof(path), "%s/%s", root, rel);
    assert(n > 0 && (size_t)n < sizeof(path));
    for (char *p = path + strlen(root) + 1; *p; ++p) if (*p == '/') {
        *p = 0; assert(mkdir(path, 0755) == 0 || errno == EEXIST); *p = '/';
    }
    FILE *f = fopen(path, "w"); assert(f);
    va_list args; va_start(args, fmt); vfprintf(f, fmt, args); va_end(args);
    assert(fclose(f) == 0);
}
static int remove_one(const char *p, const struct stat *st, int type, struct FTW *f)
{
    (void)st; (void)type; (void)f; return remove(p);
}
static struct xrt_mem_system *sample(const struct xrt_mem_limits *limits)
{
    struct xrt_mem_roots roots = {.proc = proc, .sys = sys};
    struct xrt_mem_system *s = xrt_mem_system_read(&roots, limits);
    assert(s); return s;
}
static const struct xrt_mem_setting *setting(const struct xrt_mem_system *s, const char *name)
{
    for (uint32_t i = 0; i < s->setting_count; ++i)
        if (!strcmp(s->settings[i].name, name)) return &s->settings[i];
    return NULL;
}
int main(void)
{
    umask(022);
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof(root), "%s/xodb-memstat-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    assert(mkdtemp(root)); assert(chmod(root, 0755) == 0);
    snprintf(proc, sizeof(proc), "%s/proc", root);
    snprintf(sys, sizeof(sys), "%s/sys", root);
    struct xrt_mem_limits limits; xrt_mem_limits_default(&limits);
    struct xrt_mem_fragmentation f;
    struct xrt_mem_zone z = {.orders = 3, .blocks = {4, 1, 1}};
    assert(xrt_mem_fragmentation(&z, 2, &f));
    assert(f.suitable_blocks == 1 && f.suitable_pages == 4 && f.index_permille == -1000 && f.unusable_permille == 600);
    assert(xrt_mem_fragmentation(&z, 1, &f));
    assert(f.suitable_blocks == 3 && f.suitable_pages == 6 && f.unusable_permille == 400);
    z = (struct xrt_mem_zone){.orders = 3, .blocks = {8, 0, 0}};
    assert(xrt_mem_fragmentation(&z, 2, &f) && f.index_permille == 625 && f.unusable_permille == 1000);
    z.blocks[0] = 1;
    assert(xrt_mem_fragmentation(&z, 2, &f) && f.index_permille == -250 && !f.suitable_blocks);
    z = (struct xrt_mem_zone){.orders = 3};
    assert(xrt_mem_fragmentation(&z, 2, &f) && f.index_permille == 0 && !f.suitable_pages);
    assert(!xrt_mem_fragmentation(&z, 3, &f));
    z.blocks[2] = UINT64_MAX;
    assert(!xrt_mem_fragmentation(&z, 2, &f));

    put("proc/buddyinfo", "Node 0, zone Normal 4 1 1\nNode 1, zone Movable 8 0 0\n");
    put("proc/vmstat", "nr_free_pages 18\nthp_fault_alloc 12\nthp_fault_fallback 0\ncompact_success 3\nzswpout 5\nunrelated 99\n");
    put("sys/kernel/mm/transparent_hugepage/enabled", "always madvise [never]\n");
    put("sys/kernel/mm/transparent_hugepage/hpage_pmd_size", "2097152\n");
    put("sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled", "always [inherit] madvise never\n");
    put("sys/kernel/mm/transparent_hugepage/hugepages-64kB/stats/anon_fault_alloc", "7\n");
    put("sys/module/zswap/parameters/enabled", "N\n");
    struct xrt_mem_system *s = sample(&limits);
    assert(s->buddy_status.state == XRT_MEM_OK && s->zone_count == 2);
    assert(s->zones[0].free_pages == 10 && s->zones[0].free_blocks == 6);
    assert(s->zones[1].node == 1 && s->zones[1].free_pages == 8);
    assert(s->vmstat_status.state == XRT_MEM_OK && s->counter_count == 5);
    assert(!s->counters[0].cumulative && s->counters[1].cumulative && s->counters[2].value == 0);
    const struct xrt_mem_setting *v = setting(s, "enabled");
    assert(v && v->status.state == XRT_MEM_OK && !strcmp(v->value, "always madvise [never]"));
    assert(s->thp_status.state == XRT_MEM_PARTIAL); /* Other fixture settings absent. */
    v = setting(s, "hugepages-64kB/stats/anon_fault_alloc");
    assert(v && !strcmp(v->value, "7"));
    v = setting(s, "zswap/enabled");
    assert(v && v->status.state == XRT_MEM_OK && !strcmp(v->value, "N"));
    assert(s->finished_ns >= s->started_ns && s->page_size > 0);
    xrt_mem_system_free(s);

    limits.zones = 1; limits.counters = 1; limits.settings = 1;
    s = sample(&limits);
    assert(s->zone_count == 1 && s->buddy_status.state == XRT_MEM_PARTIAL);
    assert(s->counter_count == 1 && s->vmstat_status.state == XRT_MEM_PARTIAL);
    assert(s->setting_count == 1 && s->thp_status.state == XRT_MEM_PARTIAL && s->zswap_status.state == XRT_MEM_PARTIAL);
    xrt_mem_system_free(s);
    xrt_mem_limits_default(&limits);
    put("proc/buddyinfo", "Node 0, zone Normal 18446744073709551615 1\nNode 1, zone Movable 1 0 0\n");
    put("proc/vmstat", "thp_fault_alloc -1\ncompact_success 2\ncompact_success 3\n");
    s = sample(&limits);
    assert(s->buddy_status.state == XRT_MEM_PARTIAL && s->zone_count == 1 && s->zones[0].node == 1);
    assert(s->vmstat_status.state == XRT_MEM_PARTIAL && s->counter_count == 1 && s->counters[0].value == 2);
    xrt_mem_system_free(s);
    limits.text_bytes = 12;
    s = sample(&limits);
    assert(s->buddy_status.state == XRT_MEM_PARTIAL && s->zone_count == 0);
    assert(s->vmstat_status.state == XRT_MEM_PARTIAL && s->counter_count == 0);
    xrt_mem_system_free(s);
    limits.vmas = 0;
    assert(!xrt_mem_system_read(NULL, &limits));
    assert(nftw(root, remove_one, 16, FTW_DEPTH | FTW_PHYS) == 0);
    puts("memory system: bounded sources, optional fields, fragmentation and malformed input passed");
    return 0;
}
