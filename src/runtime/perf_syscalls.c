#define _GNU_SOURCE 1
#include "xrt_perf.h"
#include <errno.h>
#include <linux/perf_event.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static char *trim(char *s)
{
    s += strspn(s, " \t\r\n");
    size_t n = strlen(s);
    while (n && strchr(" \t\r\n", s[n - 1]))
        s[--n] = 0;
    return s;
}
static bool value(const char *line, const char *key, uint64_t expected)
{
    const char *from = strstr(line, key);
    if (!from)
        return false;
    from += strlen(key);
    const char *end = strchr(from, ';');
    if (!end)
        end = from + strlen(from);
    uint64_t n;
    return xrt_perf_unsigned(from, (size_t)(end - from), &n) && n == expected;
}
bool xrt_syscall_format(const char *text, size_t size, uint32_t id, bool enter)
{
    if (!id || id > UINT16_MAX || size > 16384 || memchr(text, 0, size))
        return false;
    char *buf = malloc(size + 1);
    if (!buf)
        return false;
    memcpy(buf, text, size);
    buf[size] = 0;
    const char *fields[] = {"unsigned short common_type",
                            "unsigned char common_flags",
                            "unsigned char common_preempt_count",
                            "int common_pid",
                            "long id",
                            enter ? "unsigned long args[6]" : "long ret"};
    const unsigned offsets[] = {0, 2, 3, 4, 8, 16}, sizes[] = {2, 1, 1, 4, 8, enter ? 48 : 8},
                   signs[] = {0, 0, 0, 1, 1, enter ? 0 : 1};
    bool seen[6] = {0}, seen_name = false, seen_id = false, ok = true;
    char *save = NULL;
    for (char *raw = strtok_r(buf, "\n", &save); raw && ok; raw = strtok_r(NULL, "\n", &save)) {
        char *line = trim(raw);
        if (!strncmp(line, "name:", 5)) {
            ok = !seen_name && !strcmp(trim(line + 5), enter ? "sys_enter" : "sys_exit");
            seen_name = true;
        } else if (!strncmp(line, "ID:", 3)) {
            ok = !seen_id && value(line, "ID:", id);
            seen_id = true;
        } else if (!strncmp(line, "field:", 6)) {
            char *end = strchr(line, ';');
            if (!end) {
                ok = false;
                break;
            }
            *end = 0;
            const char *field = trim(line + 6);
            unsigned i = 0;
            while (i < 6 && strcmp(field, fields[i]))
                ++i;
            ok = i < 6 && !seen[i] && value(end + 1, "offset:", offsets[i]) &&
                 value(end + 1, "size:", sizes[i]) && value(end + 1, "signed:", signs[i]);
            if (i < 6)
                seen[i] = true;
        }
    }
    for (unsigned i = 0; i < 6; ++i)
        ok = ok && seen[i];
    free(buf);
    return ok && seen_name && seen_id;
}
static bool metadata(bool enter, uint16_t *out, struct xrt_perf_failure *f)
{
    const char *id_path = enter ? "/sys/kernel/tracing/events/raw_syscalls/sys_enter/id"
                                : "/sys/kernel/tracing/events/raw_syscalls/sys_exit/id";
    const char *fmt_path = enter ? "/sys/kernel/tracing/events/raw_syscalls/sys_enter/format"
                                 : "/sys/kernel/tracing/events/raw_syscalls/sys_exit/format";
    char id_text[64];
    size_t size;
    uint64_t id;
    if (!xrt_perf_read_file(id_path, id_text, sizeof(id_text), &size)) {
        xrt_perf_fail(f, "syscalls.metadata.read", errno, -1, id_path);
        return false;
    }
    if (!xrt_perf_unsigned(id_text, size, &id) || !id || id > UINT16_MAX) {
        xrt_perf_fail(f, "syscalls.metadata.id", 0, -1, id_path);
        return false;
    }
    char *format = malloc(16384);
    if (!format) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "syscall format");
        return false;
    }
    bool ok = xrt_perf_read_file(fmt_path, format, 16384, &size);
    if (!ok)
        xrt_perf_fail(f, "syscalls.metadata.read", errno, -1, fmt_path);
    else if (!xrt_syscall_format(format, size, (uint32_t)id, enter)) {
        ok = false;
        xrt_perf_fail(f, "syscalls.metadata.format", 0, -1,
                      "unsupported fields, widths, signedness or ID");
    }
    free(format);
    if (ok)
        *out = (uint16_t)id;
    return ok;
}
static struct xrt_perf *start(int32_t pid, const int32_t *tids, size_t count, uint16_t *entry,
                                    uint16_t *exit, struct xrt_perf_failure *f, bool loss)
{
#if !defined(__x86_64__)
    xrt_perf_fail(f, "syscalls.architecture", 0, -1,
                  "raw syscall decoding currently supports native Linux x86-64");
    return NULL;
#endif
    if (pid <= 0 || !tids || !count || count > 32) {
        xrt_perf_fail(f, "syscalls.scope", 0, -1, "select 1..32 explicit threads");
        return NULL;
    }
    for (size_t i = 0; i < count; ++i) {
        if (tids[i] <= 0) {
            xrt_perf_fail(f, "syscalls.scope", 0, tids[i], "invalid selected TID");
            return NULL;
        }
        for (size_t j = 0; j < i; ++j)
            if (tids[i] == tids[j]) {
                xrt_perf_fail(f, "syscalls.scope", 0, tids[i], "duplicate selected TID");
                return NULL;
            }
    }
    if (!metadata(true, entry, f) || !metadata(false, exit, f))
        return NULL;
    if (*entry == *exit) {
        xrt_perf_fail(f, "syscalls.metadata.id", 0, -1,
                      "entry and exit tracepoint IDs are identical");
        return NULL;
    }
    struct xrt_perf_attr attrs[2] = {0};
    for (unsigned i = 0; i < 2; ++i) {
        attrs[i].size = 96;
        attrs[i].type = PERF_TYPE_TRACEPOINT;
        attrs[i].config = i ? *exit : *entry;
        attrs[i].sample_period = 1;
        attrs[i].read_format = loss ? PERF_FORMAT_LOST : 0;
        attrs[i].sample_type =
            PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_ID | PERF_SAMPLE_RAW;
        attrs[i].flags = 1 | (UINT64_C(1) << 18) | (UINT64_C(1) << 25);
        attrs[i].clockid = CLOCK_MONOTONIC;
        if (!i)
            attrs[i].flags |= (UINT64_C(1) << 9) | (UINT64_C(1) << 13) | (UINT64_C(1) << 24);
    }
    struct xrt_perf *p = xrt_perf_create(16, 32, UINT64_MAX);
    if (!p) {
        xrt_perf_fail(f, "alloc", errno, -1, "syscall collector");
        return NULL;
    }
    for (size_t i = 0; i < count; ++i)
        if (!xrt_perf_add(p, tids[i], attrs, 2, NULL, NULL, f))
            goto fail;
    if (!xrt_perf_enable(p, f))
        goto fail;
    return p;
fail:
    if (f)
        f->opened_then_closed += (uint16_t)xrt_perf_fd_count(p);
    xrt_perf_destroy(p);
    return NULL;
}

struct xrt_perf *xrt_syscalls_start(int32_t pid, const int32_t *tids, size_t count, uint16_t *entry,
                                    uint16_t *exit, struct xrt_perf_failure *f)
{
    return start(pid, tids, count, entry, exit, f, false);
}
struct xrt_perf *xrt_syscalls_start_loss(int32_t pid, const int32_t *tids, size_t count, uint16_t *entry,
                                         uint16_t *exit, struct xrt_perf_failure *f)
{
    struct xrt_perf_failure attempt = {0};
    struct xrt_perf *p = start(pid, tids, count, entry, exit, &attempt, true);
    /* Older kernels reject this read-format bit. Rollback above is complete;
     * the fallback still exposes loss accounting as unavailable to the caller. */
    if (!p && attempt.error == EINVAL && attempt.syscall && !strcmp(attempt.syscall, "perf_event_open"))
        p = start(pid, tids, count, entry, exit, &attempt, false);
    if (!p && f) *f = attempt;
    return p;
}
