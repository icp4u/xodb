#define _GNU_SOURCE 1
#include "memstat_internal.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *line_next(char **cursor)
{
    char *line = *cursor;
    if (!line || !*line) return NULL;
    char *end = strchr(line, '\n');
    if (end) { *end = 0; *cursor = end + 1; }
    else *cursor = NULL;
    return line;
}
static void buddy(struct xrt_mem_system *s, int root, const struct xrt_mem_limits *l)
{
    size_t length;
    char *text = xrt_mem_text(root, "buddyinfo", l->text_bytes, &length, &s->buddy_status);
    if (!text) return;
    if (s->buddy_status.state == XRT_MEM_INVALID) { free(text); return; }
    /* A bounded last line is not a complete zone. */
    if (s->buddy_status.state == XRT_MEM_PARTIAL && length && text[length - 1] != '\n') {
        char *last = strrchr(text, '\n');
        if (last) last[1] = 0; else text[0] = 0;
    }
    char *cursor = text, *line;
    while ((line = line_next(&cursor))) {
        if (!*line) continue;
        if (s->zone_count == l->zones) {
            xrt_mem_status(&s->buddy_status, XRT_MEM_PARTIAL, 0, "zone limit reached");
            break;
        }
        struct xrt_mem_zone z = {0};
        int used = 0;
        if (sscanf(line, "Node %u, zone %31s %n", &z.node, z.name, &used) != 2 || !used) {
            xrt_mem_status(&s->buddy_status, XRT_MEM_PARTIAL, 0, "invalid buddy zone line");
            continue;
        }
        char *p = line + used;
        int valid = 1;
        while (*p) {
            while (isspace((unsigned char)*p)) ++p;
            if (!*p) break;
            char *end = p;
            while (*end && !isspace((unsigned char)*end)) ++end;
            char saved = *end; *end = 0;
            uint64_t count;
            if (z.orders == XRT_MEM_MAX_ORDERS || !xrt_mem_u64(p, &count) ||
                count > UINT64_MAX >> z.orders ||
                !xrt_mem_add(z.free_blocks, count, &z.free_blocks) ||
                !xrt_mem_add(z.free_pages, count << z.orders, &z.free_pages)) valid = 0;
            *end = saved;
            if (!valid) break;
            z.blocks[z.orders++] = count;
            p = end;
        }
        if (!valid || !z.orders) {
            xrt_mem_status(&s->buddy_status, XRT_MEM_PARTIAL, 0, "invalid or overflowing buddy order counts");
            continue;
        }
        s->zones[s->zone_count++] = z;
    }
    if (!s->zone_count && s->buddy_status.state == XRT_MEM_OK)
        xrt_mem_status(&s->buddy_status, XRT_MEM_UNAVAILABLE, 0, "no buddy zones reported");
    free(text);
}
static int wanted_counter(const char *name)
{
    return !strncmp(name, "thp_", 4) || !strncmp(name, "compact_", 8) ||
        !strncmp(name, "pgmigrate_", 10) || !strncmp(name, "zswp", 4) ||
        !strcmp(name, "nr_anon_transparent_hugepages") || !strcmp(name, "nr_free_pages") ||
        !strcmp(name, "nr_shmem_hugepages") || !strcmp(name, "nr_file_hugepages") ||
        !strcmp(name, "nr_zspages") || !strcmp(name, "nr_zswap") || !strcmp(name, "nr_zswapped");
}
static void vmstat(struct xrt_mem_system *s, int root, const struct xrt_mem_limits *l)
{
    size_t length;
    char *text = xrt_mem_text(root, "vmstat", l->text_bytes, &length, &s->vmstat_status);
    if (!text) return;
    if (s->vmstat_status.state == XRT_MEM_INVALID) { free(text); return; }
    if (s->vmstat_status.state == XRT_MEM_PARTIAL && length && text[length - 1] != '\n') {
        char *last = strrchr(text, '\n');
        if (last) last[1] = 0; else text[0] = 0;
    }
    char *cursor = text, *line;
    while ((line = line_next(&cursor))) {
        char *p = line;
        while (*p && !isspace((unsigned char)*p)) ++p;
        if (!*p) continue;
        *p++ = 0;
        if (!wanted_counter(line)) continue;
        uint64_t value;
        if (strlen(line) >= sizeof(s->counters[0].name) || !xrt_mem_u64(p, &value)) {
            xrt_mem_status(&s->vmstat_status, XRT_MEM_PARTIAL, 0, "invalid vmstat memory counter");
            continue;
        }
        int duplicate = 0;
        for (uint32_t i = 0; i < s->counter_count; ++i)
            if (!strcmp(s->counters[i].name, line)) duplicate = 1;
        if (duplicate) {
            xrt_mem_status(&s->vmstat_status, XRT_MEM_PARTIAL, 0, "duplicate vmstat memory counter");
            continue;
        }
        if (s->counter_count == l->counters) {
            xrt_mem_status(&s->vmstat_status, XRT_MEM_PARTIAL, 0, "vmstat counter limit reached");
            break;
        }
        struct xrt_mem_counter *c = &s->counters[s->counter_count++];
        snprintf(c->name, sizeof(c->name), "%s", line);
        c->value = value;
        c->cumulative = strncmp(line, "nr_", 3) != 0 && strcmp(line, "compact_daemon_running") != 0;
    }
    if (!s->counter_count && s->vmstat_status.state == XRT_MEM_OK)
        xrt_mem_status(&s->vmstat_status, XRT_MEM_UNAVAILABLE, 0, "no memory counters reported");
    free(text);
}
static void setting(struct xrt_mem_system *s, int root, const char *base,
                    const char *key, const char *name, const struct xrt_mem_limits *l,
                    struct xrt_mem_status *group)
{
    if (s->setting_count == l->settings) {
        xrt_mem_status(group, XRT_MEM_PARTIAL, 0, "setting limit reached");
        return;
    }
    char path[256];
    int n = snprintf(path, sizeof(path), "%s/%s", base, key);
    struct xrt_mem_setting *v = &s->settings[s->setting_count++];
    if (n < 0 || (size_t)n >= sizeof(path) || strlen(name) >= sizeof(v->name)) {
        xrt_mem_status(&v->status, XRT_MEM_INVALID, 0, "setting name limit");
        xrt_mem_status(group, XRT_MEM_PARTIAL, 0, "setting name limit");
        return;
    }
    snprintf(v->name, sizeof(v->name), "%s", name);
    size_t length;
    char *text = xrt_mem_text(root, path, sizeof(v->value) - 1, &length, &v->status);
    if (text) {
        while (length && isspace((unsigned char)text[length - 1])) text[--length] = 0;
        if (v->status.state != XRT_MEM_INVALID) memcpy(v->value, text, length + 1);
        free(text);
    }
    if (v->status.state != XRT_MEM_OK && group->state == XRT_MEM_OK)
        xrt_mem_status(group, XRT_MEM_PARTIAL, 0, "some settings unavailable; see each field");
}
static void thp(struct xrt_mem_system *s, int root, const struct xrt_mem_limits *l)
{
    static const char base[] = "kernel/mm/transparent_hugepage";
    int fd = root < 0 ? -1 : openat(root, base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { xrt_mem_error(&s->thp_status, root < 0 ? ENOENT : errno, "transparent hugepage settings"); return; }
    close(fd);
    xrt_mem_status(&s->thp_status, XRT_MEM_OK, 0, "ok");
    const char *keys[] = {"enabled", "defrag", "shmem_enabled", "use_zero_page", "hpage_pmd_size",
        "khugepaged/pages_collapsed", "khugepaged/full_scans", "khugepaged/defrag",
        "khugepaged/pages_to_scan", "khugepaged/scan_sleep_millisecs", "khugepaged/alloc_sleep_millisecs",
        "khugepaged/max_ptes_none", "khugepaged/max_ptes_swap", "khugepaged/max_ptes_shared"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i)
        setting(s, root, base, keys[i], keys[i], l, &s->thp_status);
    fd = openat(root, base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { xrt_mem_status(&s->thp_status, XRT_MEM_PARTIAL, errno, "THP directory changed while sampling"); return; }
    DIR *dir = fdopendir(fd);
    if (!dir) { close(fd); xrt_mem_status(&s->thp_status, XRT_MEM_PARTIAL, errno, "cannot enumerate THP sizes"); return; }
    struct dirent *entry;
    uint32_t visited = 0;
    while ((entry = readdir(dir))) {
        if (++visited > 256) { xrt_mem_status(&s->thp_status, XRT_MEM_PARTIAL, 0, "THP directory entry limit"); break; }
        const char *name = entry->d_name;
        if (strncmp(name, "hugepages-", 10)) continue;
        const char *p = name + 10;
        if (!isdigit((unsigned char)*p)) continue;
        while (isdigit((unsigned char)*p)) ++p;
        if (strcmp(p, "kB") || strlen(name) > 40) continue;
        const char *size_keys[] = {"enabled", "shmem_enabled", "stats/anon_fault_alloc", "stats/anon_fault_fallback", "stats/nr_anon"};
        for (size_t i = 0; i < sizeof(size_keys) / sizeof(size_keys[0]); ++i) {
            char key[96];
            snprintf(key, sizeof(key), "%.40s/%s", name, size_keys[i]);
            setting(s, root, base, key, key, l, &s->thp_status);
        }
    }
    closedir(dir);
}
static void zswap(struct xrt_mem_system *s, int root, const struct xrt_mem_limits *l)
{
    static const char base[] = "module/zswap/parameters";
    int fd = root < 0 ? -1 : openat(root, base, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { xrt_mem_error(&s->zswap_status, root < 0 ? ENOENT : errno, "zswap parameters"); return; }
    close(fd);
    xrt_mem_status(&s->zswap_status, XRT_MEM_OK, 0, "ok");
    const char *keys[] = {"enabled", "max_pool_percent", "accept_threshold_percent", "compressor", "zpool", "shrinker_enabled"};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        char name[96];
        snprintf(name, sizeof(name), "zswap/%s", keys[i]);
        setting(s, root, base, keys[i], name, l, &s->zswap_status);
    }
}
struct xrt_mem_system *xrt_mem_system_read(const struct xrt_mem_roots *roots, const struct xrt_mem_limits *limits)
{
    struct xrt_mem_limits defaults;
    if (!limits) { xrt_mem_limits_default(&defaults); limits = &defaults; }
    if (!xrt_mem_limits_valid(limits)) return NULL;
    struct xrt_mem_system *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    uint64_t cpu = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID);
    s->started_ns = xrt_mem_clock(CLOCK_MONOTONIC);
    long page_size = sysconf(_SC_PAGESIZE);
    s->page_size = page_size > 0 ? (uint64_t)page_size : 0;
    s->zones = calloc(limits->zones, sizeof(*s->zones));
    s->counters = calloc(limits->counters, sizeof(*s->counters));
    s->settings = calloc(limits->settings, sizeof(*s->settings));
    if (!s->zones || !s->counters || !s->settings) { xrt_mem_system_free(s); return NULL; }
    int proc = open(roots && roots->proc ? roots->proc : "/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int proc_error = proc < 0 ? errno : 0;
    int sys = open(roots && roots->sys ? roots->sys : "/sys", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int sys_error = sys < 0 ? errno : 0;
    if (proc < 0) {
        xrt_mem_error(&s->buddy_status, proc_error, "proc source");
        xrt_mem_error(&s->vmstat_status, proc_error, "proc source");
    } else {
        buddy(s, proc, limits);
        vmstat(s, proc, limits);
    }
    if (sys < 0) {
        xrt_mem_error(&s->thp_status, sys_error, "sys source");
        xrt_mem_error(&s->zswap_status, sys_error, "sys source");
    } else {
        thp(s, sys, limits);
        zswap(s, sys, limits);
    }
    if (proc >= 0) close(proc);
    if (sys >= 0) close(sys);
    s->finished_ns = xrt_mem_clock(CLOCK_MONOTONIC);
    s->cpu_ns = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID) - cpu;
    return s;
}
