#define _GNU_SOURCE 1
#include "xrt_perf.h"
#include <errno.h>
#include <linux/perf_event.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
/* Off-CPU stacks. One sched_switch tracepoint per target thread, period 1,
 * with the outgoing callchain. The matching switch-in is the later record
 * whose next pid is that thread. This file does not open PERF_RECORD_SWITCH. */
static char *trim(char *s)
{
    s += strspn(s, " \t\r\n");
    size_t n = strlen(s);
    while (n && strchr(" \t\r\n", s[n - 1]))
        s[--n] = 0;
    return s;
}
static bool number_until(const char *from, uint64_t *out)
{
    const char *end = strchr(from, ';');
    if (!end)
        end = from + strlen(from);
    return xrt_perf_unsigned(from, (size_t)(end - from), out);
}
static bool field_at(const char *line, const char *name, unsigned *offset, unsigned *size)
{
    if (strncmp(line, "field:", 6))
        return false;
    const char *body = line + 6;
    const char *semi = strchr(body, ';');
    if (!semi)
        return false;
    char name_buf[64];
    size_t n = (size_t)(semi - body);
    if (n >= sizeof(name_buf))
        return false;
    memcpy(name_buf, body, n);
    name_buf[n] = 0;
    char *field = trim(name_buf);
    const char *id = strrchr(field, ' ');
    if (!id || strcmp(id + 1, name))
        return false;
    const char *off_at = strstr(semi, "offset:");
    const char *sz_at = strstr(semi, "size:");
    uint64_t off = 0, sz = 0;
    if (!off_at || !sz_at || !number_until(off_at + 7, &off) || !number_until(sz_at + 5, &sz))
        return false;
    if (off > 512 || sz > 16)
        return false;
    *offset = (unsigned)off;
    *size = (unsigned)sz;
    return true;
}
bool xrt_offcpu_format(const char *text, size_t size, uint32_t id, struct xrt_offcpu_layout *out)
{
    if (!text || !out || !id || id > UINT16_MAX || size > 16384 || memchr(text, 0, size))
        return false;
    char *buf = malloc(size + 1);
    if (!buf)
        return false;
    memcpy(buf, text, size);
    buf[size] = 0;
    bool seen_name = false, seen_id = false, ok = true;
    unsigned prev_off = 0, next_off = 0, state_off = 0, state_sz = 0;
    bool prev = false, next = false, state = false;
    char *save = NULL;
    for (char *raw = strtok_r(buf, "\n", &save); raw && ok; raw = strtok_r(NULL, "\n", &save)) {
        char *line = trim(raw);
        if (!strncmp(line, "name:", 5)) {
            ok = !seen_name && !strcmp(trim(line + 5), "sched_switch");
            seen_name = true;
        } else if (!strncmp(line, "ID:", 3)) {
            uint64_t got = 0;
            const char *p = strstr(line, "ID:");
            ok = !seen_id && p && xrt_perf_unsigned(p + 3, strlen(p + 3), &got) && got == id;
            seen_id = true;
        } else if (!strncmp(line, "field:", 6)) {
            unsigned off = 0, sz = 0;
            if (field_at(line, "prev_pid", &off, &sz) && sz == 4) {
                prev = !prev;
                prev_off = off;
            } else if (field_at(line, "next_pid", &off, &sz) && sz == 4) {
                next = !next;
                next_off = off;
            } else if (field_at(line, "prev_state", &off, &sz) && (sz == 4 || sz == 8)) {
                state = !state;
                state_off = off;
                state_sz = sz;
            }
        }
    }
    free(buf);
    ok = ok && seen_name && seen_id && prev && next && state;
    if (!ok)
        return false;
    out->id = (uint16_t)id;
    out->prev_pid_off = (uint16_t)prev_off;
    out->next_pid_off = (uint16_t)next_off;
    out->prev_state_off = (uint16_t)state_off;
    out->prev_state_size = (uint8_t)state_sz;
    return true;
}
static bool metadata(struct xrt_offcpu_layout *out, struct xrt_perf_failure *f)
{
    const char *id_path = "/sys/kernel/tracing/events/sched/sched_switch/id";
    const char *fmt_path = "/sys/kernel/tracing/events/sched/sched_switch/format";
    char id_text[64];
    size_t size = 0;
    uint64_t id = 0;
    if (!xrt_perf_read_file(id_path, id_text, sizeof(id_text), &size)) {
        xrt_perf_fail(f, "offcpu.tracefs", errno, -1,
                      "off-CPU stacks need read access to the sched_switch tracepoint id under tracefs; this program does not change that");
        return false;
    }
    if (!xrt_perf_unsigned(id_text, size, &id) || !id || id > UINT16_MAX) {
        xrt_perf_fail(f, "offcpu.tracefs", 0, -1, id_path);
        return false;
    }
    char *format = malloc(16384);
    if (!format) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "sched_switch format");
        return false;
    }
    bool ok = xrt_perf_read_file(fmt_path, format, 16384, &size);
    if (!ok)
        xrt_perf_fail(f, "offcpu.tracefs", errno, -1,
                      "off-CPU stacks need read access to the sched_switch tracepoint format under tracefs; this program does not change that");
    else if (!xrt_offcpu_format(format, size, (uint32_t)id, out)) {
        ok = false;
        xrt_perf_fail(f, "offcpu.format", 0, -1, "sched_switch field layout is not usable");
    }
    free(format);
    return ok;
}
struct xrt_perf *xrt_offcpu_start(const int32_t *tids, size_t count, uint8_t data_pages,
                                  uint64_t ring_budget, struct xrt_offcpu_layout *layout,
                                  struct xrt_perf_failure *f)
{
    if (!tids || !count || count > 64 || !layout || data_pages < 1 || data_pages > 16) {
        xrt_perf_fail(f, "offcpu.scope", 0, -1, "select 1..64 threads and a 1..16 page ring");
        return NULL;
    }
    for (size_t i = 0; i < count; ++i) {
        if (tids[i] <= 0) {
            xrt_perf_fail(f, "offcpu.scope", 0, tids[i], "invalid selected TID");
            return NULL;
        }
        for (size_t j = 0; j < i; ++j)
            if (tids[i] == tids[j]) {
                xrt_perf_fail(f, "offcpu.scope", 0, tids[i], "duplicate selected TID");
                return NULL;
            }
    }
    const char *hook = getenv("XODB_TEST_OFF_CPU");
    if (hook && !strcmp(hook, "deny")) {
        xrt_perf_fail(f, "perf_event_open", EPERM, -1,
                      "off-CPU stacks need perf_event_paranoid -1 (raw tracepoint data), or root, and a readable sched_switch tracepoint; this program does not change that setting");
        return NULL;
    }
    if (!metadata(layout, f))
        return NULL;
    struct xrt_perf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_TRACEPOINT;
    attr.config = layout->id;
    attr.sample_period = 1;
    attr.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_CALLCHAIN | PERF_SAMPLE_RAW;
    /* Disabled until enable. sample_id_all. use_clockid. context_switch: a
     * per-task tracepoint fires only while its task is current, so the
     * sched_switch that brings the task back in is never in this ring. The
     * PERF_RECORD_SWITCH switch-in carries that timestamp. No freq bit: period
     * 1 is every switch. Kernel callchain stays. */
    attr.flags = 1 | (UINT64_C(1) << 18) | (UINT64_C(1) << 25) | (UINT64_C(1) << 26);
    attr.clockid = CLOCK_MONOTONIC;
    attr.sample_max_stack = 64;
    struct xrt_perf *p = xrt_perf_create(data_pages, 64, ring_budget ? ring_budget : UINT64_MAX);
    if (!p) {
        xrt_perf_fail(f, "alloc", errno, -1, "off-CPU collector");
        return NULL;
    }
    for (size_t i = 0; i < count; ++i)
        if (!xrt_perf_add(p, tids[i], &attr, 1, NULL, NULL, f)) {
            if (f && (f->error == EPERM || f->error == EACCES))
                f->detail = "off-CPU stacks need perf_event_paranoid -1 (raw tracepoint data), or root, and a readable sched_switch tracepoint; this program does not change that setting";
            goto fail;
        }
    if (!xrt_perf_enable(p, f))
        goto fail;
    return p;
fail:
    if (f)
        f->opened_then_closed += (uint16_t)xrt_perf_fd_count(p);
    xrt_perf_destroy(p);
    return NULL;
}
