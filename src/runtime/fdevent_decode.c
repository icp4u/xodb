#include "xrt_fdevent.h"
#include <string.h>

/* Raw syscall formats were validated by xrt_syscalls_start. Read integer
 * fields through memcpy so hostile record alignment cannot trigger UB. */
static uint16_t u16(const unsigned char *p)
{
    uint16_t v;
    memcpy(&v, p, 2);
    return v;
}
static uint32_t u32(const unsigned char *p)
{
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}
static uint64_t u64(const unsigned char *p)
{
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}
static int64_t i64(const unsigned char *p)
{
    int64_t v;
    memcpy(&v, p, 8);
    return v;
}
static int event_id(uint64_t id, const struct xrt_fdevent_identity *who)
{
    return id == who->enter_id || id == who->exit_id;
}
static int task(const unsigned char *p, const struct xrt_fdevent_identity *who)
{
    return u32(p) == (uint32_t)who->pid && u32(p + 4) == (uint32_t)who->tid;
}

int xrt_fdevent_decode(const void *data, size_t length, const struct xrt_fdevent_identity *who,
                       struct xrt_fdevent_record *out)
{
    if (!data || !who || !out || length < 8 || length > 65535 || length % 8 || who->pid <= 0 ||
        who->tid <= 0 || !who->enter_id || !who->exit_id || who->enter_id == who->exit_id ||
        !who->enter_type || !who->exit_type || who->enter_type == who->exit_type)
        return 0;
    const unsigned char *p = data;
    if (u16(p + 6) != length)
        return 0;
    memset(out, 0, sizeof(*out));
    const uint32_t type = u32(p);
    if (type == 9) { /* PERF_SAMPLE_TID | TIME | ID | RAW */
        if (length < 40 || !task(p + 8, who))
            return 0;
        const uint64_t id = u64(p + 24);
        if (!event_id(id, who))
            return 0;
        const int enter = id == who->enter_id;
        const uint32_t raw = u32(p + 32), need = enter ? 64 : 24;
        /* perf may include up to seven bytes of alignment in raw_size. */
        if (raw < need || raw - need >= 8 || raw > length - 36 || length - 36 - raw >= 8)
            return 0;
        const unsigned char *r = p + 36;
        if (u16(r) != (enter ? who->enter_type : who->exit_type) ||
            u32(r + 4) != (uint32_t)who->tid)
            return 0;
        out->kind = enter ? XRT_FDEVENT_ENTER : XRT_FDEVENT_EXIT;
        out->time_ns = u64(p + 16);
        out->number = i64(r + 8);
        if (enter)
            for (unsigned i = 0; i < 6; ++i)
                out->args[i] = u64(r + 16 + 8 * i);
        else
            out->result = i64(r + 16);
        return 1;
    }
    /* Every non-sample record has a TID | TIME | ID sample-id trailer. */
    if (length < 32)
        return 0;
    const size_t tail = length - 24;
    if (!task(p + tail, who) || !event_id(u64(p + tail + 16), who))
        return 0;
    out->time_ns = u64(p + tail + 8);
    switch (type) {
    case 2: /* LOST */
        if (tail != 24 || !event_id(u64(p + 8), who))
            return 0;
        out->kind = XRT_FDEVENT_LOST;
        out->lost = u64(p + 16);
        return 1;
    case 5:
    case 6: /* THROTTLE / UNTHROTTLE */
        if (tail != 32 || !event_id(u64(p + 16), who))
            return 0;
        out->kind = XRT_FDEVENT_THROTTLE;
        return 1;
    case 4: /* EXIT; pid,ppid,tid,ptid,time */
        if (tail != 32 || u32(p + 8) != (uint32_t)who->pid || u32(p + 16) != (uint32_t)who->tid)
            return 0;
        out->kind = XRT_FDEVENT_TASK_EXIT;
        return 1;
    case 3: /* COMM_EXEC */
        if (tail < 24 || !task(p + 8, who) || !memchr(p + 16, 0, tail - 16))
            return 0;
        out->kind = (u16(p + 4) & (1u << 13)) ? XRT_FDEVENT_EXEC : XRT_FDEVENT_IGNORE;
        return 1;
    case 7: /* FORK; parent task reports a scope change */
        if (tail != 32)
            return 0;
        out->kind = XRT_FDEVENT_FORK;
        return 1;
    default:
        return 0;
    }
}
