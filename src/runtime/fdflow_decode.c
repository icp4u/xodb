#define _GNU_SOURCE 1
#include "xrt_fdflow.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static uint16_t u16(const unsigned char *p) {
  return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}
static uint32_t u32(const unsigned char *p) {
  return (uint32_t)u16(p) | ((uint32_t)u16(p + 2) << 16);
}
static uint64_t u64(const unsigned char *p) {
  return (uint64_t)u32(p) | ((uint64_t)u32(p + 4) << 32);
}
static int64_t i64(const unsigned char *p) {
  uint64_t u = u64(p);
  int64_t v;
  memcpy(&v, &u, 8);
  return v;
}
static const struct xrt_fdflow_source *source(const struct xrt_fdflow_source *s,
                                              uint32_t n, uint64_t id) {
  if (!id)
    return NULL;
  const struct xrt_fdflow_source *found = NULL;
  for (uint32_t i = 0; i < n; ++i)
    if (s[i].id == id) {
      if (found)
        return NULL;
      found = &s[i];
    }
  return found;
}
int xrt_fdflow_decode(const void *data, size_t size,
                      const struct xrt_fdflow_source *sources, uint32_t count,
                      struct xrt_fdflow_record *out) {
  if (!data || !sources || !out || !count || count > XRT_FDFLOW_EVENTS ||
      size < 8 || size > 65535 || size % 8)
    return 0;
  const unsigned char *p = data;
  if (u16(p + 6) != size)
    return 0;
  memset(out, 0, sizeof *out);
  if (u32(p) == 9) { /* TID, TIME, ID, RAW */
    if (size < 40)
      return 0;
    const struct xrt_fdflow_source *s = source(sources, count, u64(p + 24));
    if (!s || !s->type || s->argc > 6 || s->operation > XRT_FDFLOW_WRITE ||
        s->exit > 1)
      return 0;
    if (s->operation == XRT_FDFLOW_RAW && s->argc != (s->exit ? 0u : 6u))
      return 0;
    if (s->operation != XRT_FDFLOW_RAW && !s->exit && !s->argc)
      return 0;
    uint32_t raw = u32(p + 32), need = s->exit ? 24u : 16u + 8u * s->argc;
    if (raw < need || raw - need >= 8 || raw > size - 36 ||
        size - 36 - raw >= 8)
      return 0;
    uint32_t pid = u32(p + 8), tid = u32(p + 12);
    const unsigned char *r = p + 36;
    if (!pid || pid > INT_MAX || !tid || tid > INT_MAX || u32(r + 4) != tid ||
        u16(r) != s->type)
      return 0;
    out->pid = (int32_t)pid;
    out->tid = (int32_t)tid;
    out->time_ns = u64(p + 16);
    out->operation = s->operation;
    if (s->operation == XRT_FDFLOW_RAW)
      out->number = i64(r + 8);
    else {
      if (u32(r + 8) != s->number)
        return 0;
      out->number = s->number;
    }
    out->kind = s->exit ? XRT_FDFLOW_EXIT : XRT_FDFLOW_ENTER;
    if (s->exit)
      out->result = i64(r + 16);
    else
      for (uint32_t i = 0; i < s->argc; ++i)
        out->args[i] = u64(r + 16 + 8 * i);
    return 1;
  }
  /* No task/comm/mmap notifications are enabled. Loss/throttle trailers may
   * describe the CPU's current task, so they never supply target identity. */
  if (size < 32)
    return 0;
  size_t tail = size - 24;
  if (!source(sources, count, u64(p + tail + 16)))
    return 0;
  out->time_ns = u64(p + tail + 8);
  if (u32(p) == 2 && tail == 24 && u64(p + 8) == u64(p + tail + 16)) {
    out->kind = XRT_FDFLOW_LOST;
    out->lost = u64(p + 16);
    return 1;
  }
  if ((u32(p) == 5 || u32(p) == 6) && tail == 32 &&
      u64(p + 16) == u64(p + tail + 16)) {
    out->kind = XRT_FDFLOW_THROTTLED;
    return 1;
  }
  return 0;
}
static char *trim(char *p) {
  p += strspn(p, " \t\r\n");
  size_t n = strlen(p);
  while (n && strchr(" \t\r\n", p[n - 1]))
    p[--n] = 0;
  return p;
}
static int value(const char *p, const char *key, uint64_t *out) {
  p = strstr(p, key);
  if (!p)
    return 0;
  p += strlen(key);
  const char *end = strchr(p, ';');
  if (!end)
    end = p + strlen(p);
  return xrt_perf_unsigned(p, (size_t)(end - p), out);
}
int xrt_fdflow_format(const char *text, size_t size, const char *name,
                      const struct xrt_fdflow_source *s) {
  if (!text || !name || !s || !s->type || s->operation > XRT_FDFLOW_WRITE ||
      s->argc > 6 || s->exit > 1 || size > 16384 || memchr(text, 0, size))
    return 0;
  if (s->operation == XRT_FDFLOW_RAW)
    return xrt_syscall_format(text, size, s->type, !s->exit);
  char *buf = malloc(size + 1);
  if (!buf)
    return 0;
  memcpy(buf, text, size);
  buf[size] = 0;
  const char *common[] = {"unsigned short common_type",
                          "unsigned char common_flags",
                          "unsigned char common_preempt_count",
                          "int common_pid", "int __syscall_nr"};
  const uint32_t offsets[] = {0, 2, 3, 4, 8}, widths[] = {2, 1, 1, 4, 4},
                 signs[] = {0, 0, 0, 1, 1};
  uint32_t seen = 0;
  int have_name = 0, have_id = 0, ok = 1;
  char *save = NULL;
  for (char *raw = strtok_r(buf, "\n", &save); raw && ok;
       raw = strtok_r(NULL, "\n", &save)) {
    char *line = trim(raw);
    if (!strncmp(line, "name:", 5)) {
      ok = !have_name && !strcmp(trim(line + 5), name);
      have_name = 1;
    } else if (!strncmp(line, "ID:", 3)) {
      uint64_t id;
      ok = !have_id && value(line, "ID:", &id) && id == s->type;
      have_id = 1;
    } else if (!strncmp(line, "field:", 6)) {
      char *end = strchr(line, ';');
      if (!end) {
        ok = 0;
        break;
      }
      *end = 0;
      char *field = trim(line + 6);
      uint64_t off, width, sign;
      if (!value(end + 1, "offset:", &off) ||
          !value(end + 1, "size:", &width) ||
          !value(end + 1, "signed:", &sign)) {
        ok = 0;
        break;
      }
      uint32_t i = 0;
      while (i < 5 && strcmp(field, common[i]))
        ++i;
      if (i < 5)
        ok = off == offsets[i] && width == widths[i] && sign == signs[i];
      else if (s->exit) {
        i = 5;
        ok = !strcmp(field, "long ret") && off == 16 && width == 8 && sign == 1;
      } else {
        if (off < 16 || off % 8 || (off - 16) / 8 >= s->argc) {
          ok = 0;
          break;
        }
        i = 5 + (uint32_t)((off - 16) / 8);
        ok = width == 8 && sign <= 1;
        if (i == 5) {
          const char *last = strrchr(field, ' ');
          ok = ok && last && !strcmp(last + 1, "fd");
        }
      }
      if (seen & (1u << i))
        ok = 0;
      seen |= 1u << i;
    }
  }
  uint32_t expected = (1u << (s->exit ? 6u : 5u + s->argc)) - 1;
  free(buf);
  return ok && have_name && have_id && seen == expected;
}
static int number(const char *s, size_t n, size_t *at, uint32_t *out) {
  if (*at >= n || s[*at] < '0' || s[*at] > '9')
    return 0;
  uint32_t v = 0;
  while (*at < n && s[*at] >= '0' && s[*at] <= '9') {
    unsigned digit = (unsigned)(s[(*at)++] - '0');
    if (v > ((uint32_t)INT_MAX - digit) / 10)
      return 0;
    v = v * 10 + digit;
  }
  *out = v;
  return 1;
}
int xrt_fdflow_cpu_list(const char *s, size_t n, int32_t *cpus, uint32_t cap,
                        uint32_t *count, uint32_t *total) {
  if (!s || !cpus || !cap || cap > XRT_PERF_MAX_THREADS || !count || !total ||
      !n || n > 16384)
    return 0;
  *count = *total = 0;
  size_t at = 0;
  uint32_t previous = 0;
  int first = 1;
  while (at < n) {
    uint32_t lo, hi;
    if (!number(s, n, &at, &lo))
      return 0;
    hi = lo;
    if (at < n && s[at] == '-') {
      ++at;
      if (!number(s, n, &at, &hi) || hi < lo)
        return 0;
    }
    if (!first && lo <= previous)
      return 0;
    first = 0;
    previous = hi;
    uint32_t amount = hi - lo + 1, keep = cap - *count;
    if (keep > amount)
      keep = amount;
    for (uint32_t i = 0; i < keep; ++i)
      cpus[(*count)++] = (int32_t)(lo + i);
    *total += amount;
    if (at == n)
      return 1;
    if (s[at] == '\n')
      return at + 1 == n;
    if (s[at++] != ',' || at == n)
      return 0;
  }
  return 0;
}
