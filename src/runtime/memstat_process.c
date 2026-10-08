#define _GNU_SOURCE 1
#include "memstat_internal.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *next_line(char **cursor)
{
    char *line = *cursor;
    if (!line || !*line) return NULL;
    char *end = strchr(line, '\n');
    if (end) { *end = 0; *cursor = end + 1; } else *cursor = NULL;
    return line;
}
static void partial_tail(char *text, size_t length, const struct xrt_mem_status *status)
{
    if (status->state != XRT_MEM_PARTIAL || !length || text[length - 1] == '\n') return;
    char *last = strrchr(text, '\n');
    if (last) last[1] = 0; else text[0] = 0;
}
static int identity(int dir, uint64_t *start, char *name, size_t cap, struct xrt_mem_status *status)
{
    size_t length;
    char *text = xrt_mem_text(dir, "stat", 4096, &length, status);
    if (!text) {
        if (status->error == ENOENT || status->error == ESRCH)
            xrt_mem_status(status, XRT_MEM_EXITED, status->error, "process identity no longer readable");
        return 0;
    }
    char *open = strchr(text, '('), *close = strrchr(text, ')');
    int ok = status->state == XRT_MEM_OK && open && close && close > open;
    if (ok) {
        if (name && cap) {
            size_t size = (size_t)(close - open - 1);
            if (size >= cap) size = cap - 1;
            memcpy(name, open + 1, size); name[size] = 0;
        }
        char *p = close + 1;
        for (uint32_t field = 3; field <= 22; ++field) {
            while (isspace((unsigned char)*p)) ++p;
            char *end = p;
            while (*end && !isspace((unsigned char)*end)) ++end;
            if (end == p) { ok = 0; break; }
            if (field == 22) {
                *end = 0;
                ok = xrt_mem_u64(p, start) && *start > 0;
                break;
            }
            p = end;
        }
    }
    free(text);
    if (!ok) xrt_mem_status(status, XRT_MEM_INVALID, 0, "invalid process start identity");
    return ok;
}
static int number(char **cursor, unsigned base, char separator, uint64_t *out)
{
    char *p = *cursor;
    if (!isxdigit((unsigned char)*p) || *p == '-' || *p == '+') return 0;
    char *end;
    errno = 0;
    unsigned long long n = strtoull(p, &end, (int)base);
    if (errno || end == p || (separator ? *end != separator : !isspace((unsigned char)*end))) return 0;
    *out = (uint64_t)n;
    *cursor = end + 1;
    return 1;
}
static int header(char *line, struct xrt_mem_vma *v, char **path)
{
    char *p = line;
    uint64_t major, minor;
    if (!number(&p, 16, '-', &v->start) || !number(&p, 16, 0, &v->end) || v->end <= v->start) return 0;
    while (isspace((unsigned char)*p)) ++p;
    if (strlen(p) < 5 || (p[0] != 'r' && p[0] != '-') || (p[1] != 'w' && p[1] != '-') ||
        (p[2] != 'x' && p[2] != '-') || (p[3] != 'p' && p[3] != 's') || !isspace((unsigned char)p[4])) return 0;
    memcpy(v->permissions, p, 4); p += 5;
    while (isspace((unsigned char)*p)) ++p;
    if (!number(&p, 16, 0, &v->offset)) return 0;
    while (isspace((unsigned char)*p)) ++p;
    if (!number(&p, 16, ':', &major) || !number(&p, 16, 0, &minor) || major > UINT32_MAX || minor > UINT32_MAX) return 0;
    v->dev_major = (uint32_t)major; v->dev_minor = (uint32_t)minor;
    while (isspace((unsigned char)*p)) ++p;
    char *end = p;
    while (isdigit((unsigned char)*end)) ++end;
    if (end == p || (*end && !isspace((unsigned char)*end))) return 0;
    char saved = *end; *end = 0;
    int ok = xrt_mem_u64(p, &v->inode); *end = saved;
    if (!ok) return 0;
    p = end;
    while (isspace((unsigned char)*p)) ++p;
    *path = p;
    return 1;
}
static int metric(char *line, struct xrt_mem_vma *v)
{
    struct field { const char *name; uint64_t flag; size_t offset; };
#define FIELD(name, flag, member) {name, flag, offsetof(struct xrt_mem_vma, member)}
    static const struct field fields[] = {
        FIELD("Rss", XRT_MEM_RSS, rss), FIELD("Pss", XRT_MEM_PSS, pss),
        FIELD("Anonymous", XRT_MEM_ANONYMOUS, anonymous), FIELD("AnonHugePages", XRT_MEM_ANON_HUGE, anon_huge),
        FIELD("FilePmdMapped", XRT_MEM_FILE_PMD, file_pmd), FIELD("ShmemPmdMapped", XRT_MEM_SHMEM_PMD, shmem_pmd),
        FIELD("Swap", XRT_MEM_SWAP, swap), FIELD("Locked", XRT_MEM_LOCKED, locked),
        FIELD("KernelPageSize", XRT_MEM_KERNEL_PAGE, kernel_page), FIELD("MMUPageSize", XRT_MEM_MMU_PAGE, mmu_page),
        FIELD("Private_Hugetlb", XRT_MEM_PRIVATE_HUGETLB, private_hugetlb), FIELD("Shared_Hugetlb", XRT_MEM_SHARED_HUGETLB, shared_hugetlb),
    };
#undef FIELD
    char *colon = strchr(line, ':');
    if (!colon) return 1;
    *colon = 0;
    char *value = colon + 1;
    uint64_t n;
    if (!strcmp(line, "VmFlags")) {
        if (v->known & XRT_MEM_VMFLAGS) return 0;
        v->known |= XRT_MEM_VMFLAGS;
        char *save = NULL;
        for (char *flag = strtok_r(value, " \t", &save); flag; flag = strtok_r(NULL, " \t", &save)) {
            if (!strcmp(flag, "ht")) v->flags |= XRT_MEM_VMA_HUGETLB;
            if (!strcmp(flag, "io") || !strcmp(flag, "pf")) v->flags |= XRT_MEM_VMA_SPECIAL;
        }
        return 1;
    }
    if (!strcmp(line, "THPeligible")) {
        if (v->known & XRT_MEM_ELIGIBLE || !xrt_mem_u64(value, &n) || n > 1) return 0;
        v->thp_eligible = (uint8_t)n; v->known |= XRT_MEM_ELIGIBLE;
        return 1;
    }
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) if (!strcmp(line, fields[i].name)) {
        if (v->known & fields[i].flag) return 0;
        char *end = value + strlen(value);
        while (end > value && isspace((unsigned char)end[-1])) --end;
        if (end - value < 2 || end[-2] != 'k' || end[-1] != 'B') return 0;
        end[-2] = 0;
        if (!xrt_mem_u64(value, &n) || n > UINT64_MAX / 1024) return 0;
        *(uint64_t *)((char *)v + fields[i].offset) = n * 1024;
        v->known |= fields[i].flag;
        break;
    }
    return 1;
}
static void maps(struct xrt_mem_process *s, int dir, const struct xrt_mem_limits *l)
{
    size_t length;
    char *text = xrt_mem_text(dir, "smaps", l->text_bytes, &length, &s->maps_status);
    if (!text) return;
    if (s->maps_status.state == XRT_MEM_INVALID) { free(text); return; }
    partial_tail(text, length, &s->maps_status);
    char *cursor = text, *line;
    struct xrt_mem_vma *current = NULL;
    uint32_t vma_capacity = 0, path_capacity = 0;
    while ((line = next_line(&cursor))) {
        char *dash = strchr(line, '-'), *space = strchr(line, ' ');
        if (dash && space && dash < space) {
            struct xrt_mem_vma v = {0}; char *path;
            current = NULL;
            if (!header(line, &v, &path) || (s->vma_count && v.start < s->vmas[s->vma_count - 1].end)) {
                xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, 0, "invalid, changed or overlapping VMA header");
                continue;
            }
            if (s->vma_count == l->vmas) { xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, 0, "VMA limit reached"); break; }
            struct xrt_mem_vma *grown = xrt_mem_grow(s->vmas, &vma_capacity,
                s->vma_count + 1, l->vmas, sizeof(*s->vmas));
            if (!grown) { xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, ENOMEM, "VMA storage allocation failed"); break; }
            s->vmas = grown;
            if (!xrt_mem_add(s->mapped_bytes, v.end - v.start, &s->mapped_bytes)) {
                xrt_mem_status(&s->maps_status, XRT_MEM_INVALID, 0, "mapped-byte total overflow"); break;
            }
            size_t n = strlen(path);
            if (n + 1 > l->path_bytes - s->path_length) {
                v.flags |= XRT_MEM_PATH_CUT;
                xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, 0, "path storage limit reached");
            } else {
                char *paths = xrt_mem_grow(s->paths, &path_capacity,
                    s->path_length + (uint32_t)n + 1, l->path_bytes, 1);
                if (!paths) {
                    v.flags |= XRT_MEM_PATH_CUT;
                    xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, ENOMEM, "path storage allocation failed");
                } else {
                    s->paths = paths;
                    v.path = s->path_length; v.path_length = (uint32_t)n;
                    memcpy(s->paths + s->path_length, path, n + 1); s->path_length += (uint32_t)n + 1;
                }
            }
            s->vmas[s->vma_count] = v;
            current = &s->vmas[s->vma_count++];
        } else if (current && !(current->flags & XRT_MEM_BAD_METRIC) && !metric(line, current)) {
            current->flags |= XRT_MEM_BAD_METRIC;
            current->known = 0;
            xrt_mem_status(&s->maps_status, XRT_MEM_PARTIAL, 0, "invalid or duplicate smaps metric");
        }
    }
    free(text);
    s->totals_known = XRT_MEM_RSS | XRT_MEM_ANONYMOUS | XRT_MEM_ANON_HUGE | XRT_MEM_SWAP;
    if (!s->vma_count) s->totals_known = 0;
    for (uint32_t i = 0; i < s->vma_count; ++i) {
        const struct xrt_mem_vma *v = &s->vmas[i];
        s->totals_known &= v->known;
        int ok = 1;
        if (v->known & XRT_MEM_RSS) ok &= xrt_mem_add(s->rss, v->rss, &s->rss);
        if (v->known & XRT_MEM_ANONYMOUS) ok &= xrt_mem_add(s->anonymous, v->anonymous, &s->anonymous);
        if (v->known & XRT_MEM_ANON_HUGE) ok &= xrt_mem_add(s->anon_huge, v->anon_huge, &s->anon_huge);
        if (v->known & XRT_MEM_SWAP) ok &= xrt_mem_add(s->swap, v->swap, &s->swap);
        if (v->known & XRT_MEM_ANONYMOUS) {
            if (!(v->known & XRT_MEM_ELIGIBLE)) ok &= xrt_mem_add(s->unknown_eligibility_anonymous, v->anonymous, &s->unknown_eligibility_anonymous);
            else if (v->thp_eligible) {
                ok &= xrt_mem_add(s->eligible_anonymous, v->anonymous, &s->eligible_anonymous);
                if (v->known & XRT_MEM_ANON_HUGE) ok &= xrt_mem_add(s->eligible_anon_huge, v->anon_huge, &s->eligible_anon_huge);
            }
        }
        if (!ok) { xrt_mem_status(&s->maps_status, XRT_MEM_INVALID, 0, "smaps aggregate overflow"); s->totals_known = 0; break; }
    }
    if (s->maps_status.state != XRT_MEM_OK) s->totals_known = 0;
}
static void rollup(struct xrt_mem_process *s, int dir, const struct xrt_mem_limits *l)
{
    size_t length;
    char *text = xrt_mem_text(dir, "smaps_rollup", l->text_bytes < 65536 ? l->text_bytes : 65536, &length, &s->rollup_status);
    if (!text) return;
    if (s->rollup_status.state == XRT_MEM_INVALID) { free(text); return; }
    partial_tail(text, length, &s->rollup_status);
    struct xrt_mem_vma v = {0};
    char *cursor = text, *line;
    int valid = 1;
    while ((line = next_line(&cursor))) if (!metric(line, &v)) {
        valid = 0;
        xrt_mem_status(&s->rollup_status, XRT_MEM_PARTIAL, 0, "invalid rollup metric");
    }
    if (!valid) v = (struct xrt_mem_vma){0};
    s->rollup_rss = v.rss; s->rollup_anonymous = v.anonymous;
    s->rollup_anon_huge = v.anon_huge; s->rollup_swap = v.swap; s->rollup_known = s->rollup_status.state == XRT_MEM_OK ? v.known : 0;
    free(text);
}
static void numa(struct xrt_mem_process *s, int dir, const struct xrt_mem_limits *l)
{
    size_t length;
    char *text = xrt_mem_text(dir, "numa_maps", l->text_bytes, &length, &s->numa_status);
    if (!text) return;
    if (s->numa_status.state == XRT_MEM_INVALID) { free(text); return; }
    partial_tail(text, length, &s->numa_status);
    char *cursor = text, *line;
    while ((line = next_line(&cursor))) {
        char *p = line; uint64_t start;
        if (!number(&p, 16, 0, &start)) continue;
        uint32_t low = 0, high = s->vma_count;
        while (low < high) { uint32_t mid = low + (high - low) / 2; if (s->vmas[mid].start < start) low = mid + 1; else high = mid; }
        if (low == s->vma_count || s->vmas[low].start != start) continue;
        struct xrt_mem_vma *v = &s->vmas[low]; v->numa_available = 1;
        char *save, *token = strtok_r(p, " \t", &save);
        while (token) {
            if (!strncmp(token, "kernelpagesize_kB=", 18)) {
                uint64_t size;
                if (xrt_mem_u64(token + 18, &size) && size && size <= UINT64_MAX / 1024)
                    v->numa_page_size = size * 1024;
            }
            if (token[0] == 'N' && isdigit((unsigned char)token[1])) {
                char *equal = strchr(token, '='); uint64_t node, pages;
                int valid = 0;
                if (equal) { *equal = 0; valid = xrt_mem_u64(token + 1, &node) && node <= UINT32_MAX && xrt_mem_u64(equal + 1, &pages); }
                if (!valid) xrt_mem_status(&s->numa_status, XRT_MEM_PARTIAL, 0, "invalid NUMA node count");
                else if (v->numa_count == 16) { v->flags |= XRT_MEM_NUMA_CUT; xrt_mem_status(&s->numa_status, XRT_MEM_PARTIAL, 0, "per-VMA NUMA node limit"); }
                else {
                    int duplicate = 0;
                    for (uint32_t j = 0; j < v->numa_count; ++j) if (v->numa[j].node == node) duplicate = 1;
                    if (duplicate) {
                        v->flags |= XRT_MEM_NUMA_CUT;
                        xrt_mem_status(&s->numa_status, XRT_MEM_PARTIAL, 0, "duplicate NUMA node count");
                    } else v->numa[v->numa_count++] = (struct xrt_mem_node){(uint32_t)node, pages};
                }
            }
            token = strtok_r(NULL, " \t", &save);
        }
    }
    free(text);
}
static void coverage(struct xrt_mem_process *s, const struct xrt_mem_roots *roots)
{
    int sys = open(roots && roots->sys ? roots->sys : "/sys", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    size_t length = 0;
    struct xrt_mem_status status;
    char *text = xrt_mem_text(sys, "kernel/mm/transparent_hugepage/hpage_pmd_size", 64, &length, &status);
    if (sys >= 0) close(sys);
    uint64_t pmd = 0;
    if (text && status.state == XRT_MEM_OK && xrt_mem_u64(text, &pmd) &&
        pmd >= s->page_size && !(pmd & (pmd - 1))) {
        s->pmd_size = pmd; s->pmd_size_known = 1;
    }
    free(text);
    if (!s->pmd_size_known || s->maps_status.state != XRT_MEM_OK) return;
    s->coverage_numerator_known = s->coverage_denominator_known = 1;
    for (uint32_t i = 0; i < s->vma_count; ++i) {
        const struct xrt_mem_vma *v = &s->vmas[i];
        if (!(v->known & XRT_MEM_ELIGIBLE)) goto unknown;
        if (!v->thp_eligible) continue;
        /* File-backed COW pages are deliberately outside the anonymous-VMA
         * denominator. Shared anonymous mappings use the shmem policy. */
        if (v->inode || v->dev_major || v->dev_minor || v->permissions[3] != 'p') continue;
        if (!(v->known & XRT_MEM_VMFLAGS)) goto unknown;
        if (v->flags & (XRT_MEM_VMA_HUGETLB | XRT_MEM_VMA_SPECIAL)) continue;
        uint64_t first = v->start / pmd + !!(v->start % pmd), last = v->end / pmd;
        uint64_t span = last > first ? (last - first) * pmd : 0;
        if (!xrt_mem_add(s->coverage_denominator, span, &s->coverage_denominator)) goto unknown;
        if (!(v->known & XRT_MEM_ANON_HUGE) || v->anon_huge > span || v->anon_huge % pmd ||
            !xrt_mem_add(s->coverage_numerator, v->anon_huge, &s->coverage_numerator))
            s->coverage_numerator_known = 0;
    }
    return;
unknown:
    s->coverage_numerator_known = s->coverage_denominator_known = 0;
}
struct xrt_mem_process *xrt_mem_process_read(const struct xrt_mem_roots *roots,
    const struct xrt_mem_limits *limits, const struct xrt_mem_request *request)
{
    struct xrt_mem_limits defaults;
    if (!limits) { xrt_mem_limits_default(&defaults); limits = &defaults; }
    if (!xrt_mem_limits_valid(limits) || !request || request->pid <= 0 || (request->flags & ~(XRT_MEM_SKIP_PAGES | XRT_MEM_NUMA)) ||
        ((request->range_start || request->range_end) && request->range_end <= request->range_start)) return NULL;
    const int32_t pid = request->pid;
    const uint64_t expected_start = request->start_ticks;
    struct xrt_mem_process *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->pid = pid; s->started_ns = xrt_mem_clock(CLOCK_MONOTONIC);
    uint64_t cpu = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID);
    long page_size = sysconf(_SC_PAGESIZE); s->page_size = page_size > 0 ? (uint64_t)page_size : 0;
    if (!s->page_size || request->range_start % s->page_size || request->range_end % s->page_size) { free(s); return NULL; }
    s->range_start = request->range_start; s->range_end = request->range_end;
    int root = open(roots && roots->proc ? roots->proc : "/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int root_error = root < 0 ? errno : 0;
    char name[32]; snprintf(name, sizeof(name), "%d", pid);
    int dir = root < 0 ? -1 : openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int dir_error = dir < 0 ? (root < 0 ? root_error : errno) : 0;
    if (root >= 0) close(root);
    struct xrt_mem_status identity_status;
    if (dir < 0) {
        xrt_mem_error(&identity_status, dir_error, "process directory");
        if (root_error == 0 && (dir_error == ENOENT || dir_error == ESRCH)) identity_status.state = XRT_MEM_EXITED;
    }
    else if (identity(dir, &s->start_ticks, s->name, sizeof(s->name), &identity_status)) {
        if (expected_start && expected_start != s->start_ticks)
            xrt_mem_status(&identity_status, XRT_MEM_IDENTITY_CHANGED, 0, "PID start identity differs from request");
        else {
            maps(s, dir, limits);
            if (s->maps_status.state == XRT_MEM_PARTIAL) rollup(s, dir, limits);
            else xrt_mem_status(&s->rollup_status, XRT_MEM_UNAVAILABLE, 0, "rollup not requested; used only for partial smaps");
            if (request->flags & XRT_MEM_NUMA) numa(s, dir, limits);
            else xrt_mem_status(&s->numa_status, XRT_MEM_UNAVAILABLE, 0, "NUMA totals not requested");
            coverage(s, roots);
            if (request->flags & XRT_MEM_SKIP_PAGES)
                xrt_mem_status(&s->pages_status, XRT_MEM_UNAVAILABLE, 0, "page states not requested; metadata only");
            else xrt_mem_pages(s, dir, limits);
            uint64_t after = 0;
            if (identity(dir, &after, NULL, 0, &identity_status) && after != s->start_ticks)
                xrt_mem_status(&identity_status, XRT_MEM_IDENTITY_CHANGED, 0, "PID start identity changed while sampling");
        }
    }
    if (identity_status.state != XRT_MEM_OK) {
        s->maps_status = s->pages_status = s->numa_status = s->rollup_status = identity_status;
        s->vma_count = s->range_count = s->path_length = 0; s->name[0] = 0;
        s->rss = s->anonymous = s->anon_huge = s->swap = s->totals_known = 0;
        s->mapped_bytes = s->scanned_bytes = s->scan_resume = 0;
        s->rollup_rss = s->rollup_anonymous = s->rollup_anon_huge = s->rollup_swap = s->rollup_known = 0;
        s->eligible_anonymous = s->eligible_anon_huge = s->unknown_eligibility_anonymous = 0;
        s->coverage_numerator = s->coverage_denominator = 0;
        s->coverage_numerator_known = s->coverage_denominator_known = 0;
    }
    if (dir >= 0) close(dir);
    s->vmas = xrt_mem_trim(s->vmas, (size_t)s->vma_count * sizeof(*s->vmas));
    s->ranges = xrt_mem_trim(s->ranges, (size_t)s->range_count * sizeof(*s->ranges));
    s->paths = xrt_mem_trim(s->paths, s->path_length);
    if (!s->vmas || !s->ranges || !s->paths) { xrt_mem_process_free(s); return NULL; }
    s->finished_ns = xrt_mem_clock(CLOCK_MONOTONIC);
    s->cpu_ns = xrt_mem_clock(CLOCK_THREAD_CPUTIME_ID) - cpu;
    return s;
}
