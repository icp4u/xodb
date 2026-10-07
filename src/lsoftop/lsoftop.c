/* lsof-top: live open files and descriptor activity in a terminal.
 * Plain termios and ANSI sequences: alternate screen, synchronized output and
 * line-diffed frames. Data comes from the runtime's /proc scanner. */
#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "lsoftop.h"
#include "xrt_fdscan.h"
#include <errno.h>
#include <fcntl.h>
#include <langinfo.h>
#include <locale.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

enum view { V_FILES, V_PROCS, V_LEAKS, V_DELETED, V_FDS, V_HOLDERS, VIEWS };
static const char *const view_names[VIEWS] = { "files", "processes", "leaks", "deleted", "fds", "holders" };
static const char *const view_titles[4] = { "Files", "Processes", "Leaks", "Deleted" };
#define SORTS 5
static const char *const sort_names[VIEWS][SORTS] = {
    { "io", "holders", "fds", "size", NULL },
    { "churn", "fds", "growth", "io", "pid" },
    { "growth", "rate", "fds", NULL, NULL },
    { "size", "holders", NULL, NULL, NULL },
    { "fd", "io", "pos", NULL, NULL },
    { "pid", "io", NULL, NULL, NULL },
};
enum { MAX_PIDS = 4096, FILTER = 128, USERS = 64 };
enum key { K_UP = 256, K_DOWN, K_LEFT, K_RIGHT, K_PGUP, K_PGDN, K_HOME, K_END, K_BTAB, K_ESC };
enum color { C_NONE, C_DIM, C_ACCENT, C_TITLE, C_GOOD, C_WARN, C_ALERT, C_KIND };

struct buf {
    char *b;
    size_t n, cap;
};
struct row {
    struct buf b;
    int col, width;
    int selected; /* the selection band: every pen keeps it */
    int graphic;  /* inside a sparkline, kind bar or progress bar */
};
struct user {
    uint32_t uid;
    char name[33];
};
/* Idle files of one kind held by the same set of processes share a row. */
struct group {
    uint64_t set;
    uint32_t kind, count, fds, first; /* first: a member file index */
};
#define GROUP 0x80000000u
struct ui {
    struct xrt_fdscan *scan;
    struct xrt_fd_snapshot snap;
    const struct xrt_fd_file *files;
    uint32_t nfiles;
    double interval;
    int view, back;
    int sel[VIEWS], top[VIEWS], sort[VIEWS], reverse[VIEWS];
    uint64_t sel_key[VIEWS];
    char filter[VIEWS][FILTER];
    int editing, frozen, help, help_top, quit, from_holders;
    int budget_default; /* the scan budget follows the period */
    int32_t focus_pid;
    uint64_t focus_start, focus_device, focus_inode;
    uint32_t focus_sample;
    int cols, lines;
    int color; /* 0, 16 or 256 */
    int attrs, utf8, redact, ascii;
    uint32_t *list, nlist, list_cap;
    struct group *groups;
    uint32_t ngroups, groups_cap;
    uint32_t *idle, idle_cap;
    int spark_width; /* per-row sparklines widen when there is room */
    int expanded; /* the Files view lists one group's members */
    uint64_t expanded_set;
    uint32_t expanded_kind;
    struct row *frame;
    struct buf *shown;
    int frame_lines;
    struct buf out;
    char message[160];
    uint64_t message_ns; /* when the message was set; it fades after three seconds */
    uint64_t started, cpu_wall, cpu_used;
    double cpu_percent;
    struct user users[USERS];
    int nusers;
    char host[256], short_host[256];
};

/* ---------------------------------------------------------------- buffers */
static void bput(struct buf *b, const char *s, size_t n)
{
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->n + n + 1)
            cap *= 2;
        char *grown = realloc(b->b, cap);
        if (!grown)
            return; /* drop output rather than crash; the next frame redraws */
        b->b = grown;
        b->cap = cap;
    }
    memcpy(b->b + b->n, s, n);
    b->n += n;
    b->b[b->n] = 0;
}
static void bstr(struct buf *b, const char *s)
{
    bput(b, s, strlen(s));
}
static void bprintf(struct buf *b, const char *format, ...) __attribute__((format(printf, 2, 3)));
static void bprintf(struct buf *b, const char *format, ...)
{
    char text[512];
    va_list args;
    va_start(args, format);
    int n = vsnprintf(text, sizeof(text), format, args);
    va_end(args);
    if (n > 0)
        bput(b, text, (size_t)n < sizeof(text) ? (size_t)n : sizeof(text) - 1);
}

/* ------------------------------------------------------------------ cells */
static void pen(struct ui *u, struct row *r, enum color c, int kind, const char *extra)
{
    if (!u->attrs)
        return;
    bstr(&r->b, "\x1b[0");
    /* The selection is a mid-tone band in 256 colours, where graphics keep
     * their colours on it; reverse video otherwise, without graphics. */
    const char *base = !r->selected ? NULL : u->color == 256 ? (r->graphic ? "48;5;24" : "48;5;24;38;5;231") : "7";
    if (base) {
        bstr(&r->b, ";");
        bstr(&r->b, base);
    }
    if (extra) {
        bstr(&r->b, ";");
        bstr(&r->b, extra);
    }
    /* Mid-tone colours read on dark and light backgrounds alike. */
    static const char *const kind256[XRT_FD_KINDS] = { NULL, "38;5;32", "38;5;133", "38;5;30", "38;5;136", "38;5;98", "38;5;66", "38;5;244" };
    static const char *const kind16[XRT_FD_KINDS] = { NULL, "34", "35", "36", "33", "35", "32", "2" };
    const char *code = NULL;
    if (r->selected && (!r->graphic || u->color != 256) && c != C_TITLE)
        c = C_NONE; /* one band: in 16 colours and none, graphics take its colours too */
    switch (c) {
    case C_NONE: break;
    case C_DIM: code = u->color == 256 ? "38;5;244" : "2"; break;
    case C_ACCENT: code = u->color == 256 ? "38;5;31" : u->color ? "36" : NULL; break;
    case C_TITLE: code = u->color == 256 ? "1;38;5;231;48;5;31" : u->color ? "1;37;46" : "1;7"; break;
    case C_GOOD: code = u->color == 256 ? "38;5;71" : u->color ? "32" : NULL; break;
    case C_WARN: code = u->color == 256 ? "38;5;172" : u->color ? "33" : "1"; break;
    case C_ALERT: code = u->color == 256 ? "38;5;167" : u->color ? "31" : "1"; break;
    case C_KIND:
        if (kind >= 0 && kind < XRT_FD_KINDS)
            code = u->color == 256 ? kind256[kind] : u->color ? kind16[kind] : NULL;
        else if (kind == XRT_FD_KINDS) /* deleted */
            code = u->color == 256 ? "38;5;167" : u->color ? "31" : NULL;
        break;
    }
    if (code) {
        bstr(&r->b, ";");
        bstr(&r->b, code);
    }
    bstr(&r->b, "m");
}

/* Decodes one sanitized character: returns bytes consumed; *w is its width. */
static size_t glyph(const struct ui *u, const unsigned char *s, size_t n, int *w, int *bad)
{
    *bad = 0;
    if (s[0] < 0x80) {
        *w = 1;
        *bad = s[0] < 0x20 || s[0] == 0x7f;
        return 1;
    }
    if (!u->utf8) {
        *w = 1;
        *bad = 1;
        return 1;
    }
    mbstate_t state;
    memset(&state, 0, sizeof(state));
    wchar_t wc;
    const size_t got = mbrtowc(&wc, (const char *)s, n, &state);
    if (got == (size_t)-1 || got == (size_t)-2 || got == 0) {
        *w = 1;
        *bad = 1;
        return 1;
    }
    const int width = wcwidth(wc);
    if (width < 1) {
        *w = 1;
        *bad = 1;
        return got;
    }
    *w = width;
    return got;
}

static int room(const struct row *r)
{
    return r->width - r->col;
}

/* Writes exactly `width` columns of sanitized text, cut with an ellipsis:
 * at the start when cut_left (paths keep their names), else at the end. */
static void cell(struct ui *u, struct row *r, const char *text, size_t n, int width, int right, int cut_left)
{
    if (width > room(r))
        width = room(r);
    if (width <= 0)
        return;
    if (n > 4096)
        n = 4096;
    const unsigned char *s = (const unsigned char *)text;
    int total = 0, w, bad;
    for (size_t i = 0; i < n;) {
        i += glyph(u, s + i, n - i, &w, &bad);
        total += w;
    }
    const char *ellipsis = u->utf8 ? "\xe2\x80\xa6" : "~";
    size_t from = 0, to = n;
    int used = total, mark = 0;
    if (total > width) {
        mark = 1;
        const int keep = width - 1;
        used = 0;
        if (cut_left) {
            /* Find the shortest suffix start whose width fits. */
            size_t i = 0;
            int skipped = 0;
            while (i < n && total - skipped > keep) {
                i += glyph(u, s + i, n - i, &w, &bad);
                skipped += w;
            }
            from = i;
            used = total - skipped;
        } else {
            size_t i = 0;
            while (i < n) {
                const size_t step = glyph(u, s + i, n - i, &w, &bad);
                if (used + w > keep)
                    break;
                used += w;
                i += step;
            }
            to = i;
        }
        used += 1;
    }
    int pad = width - used;
    if (right)
        for (; pad > 0; pad--)
            bput(&r->b, " ", 1);
    if (mark && cut_left)
        bstr(&r->b, ellipsis);
    for (size_t i = from; i < to;) {
        const size_t step = glyph(u, s + i, to - i, &w, &bad);
        if (bad)
            bput(&r->b, "?", 1);
        else
            bput(&r->b, (const char *)s + i, step);
        i += step;
    }
    if (mark && !cut_left)
        bstr(&r->b, ellipsis);
    for (; pad > 0; pad--)
        bput(&r->b, " ", 1);
    r->col += width;
}
static void put(struct ui *u, struct row *r, const char *text, int width, int right)
{
    cell(u, r, text, strlen(text), width, right, 0);
}
static int text_width(const struct ui *u, const char *text)
{
    int total = 0, w, bad;
    for (size_t i = 0, n = strlen(text); i < n;) {
        i += glyph(u, (const unsigned char *)text + i, n - i, &w, &bad);
        total += w;
    }
    return total;
}
static void puts_(struct ui *u, struct row *r, const char *text)
{
    cell(u, r, text, strlen(text), text_width(u, text), 0, 0);
}
static void space(struct ui *u, struct row *r, int n)
{
    cell(u, r, "", 0, n, 0, 0);
}

/* --------------------------------------------------------------- numbers */
static void human(char *out, size_t cap, double v)
{
    static const char units[] = "BKMGTP";
    int k = 0;
    while (v >= 1000 && k < 5) {
        v /= 1024;
        k++;
    }
    if (k == 0)
        snprintf(out, cap, "%.0f", v);
    else
        snprintf(out, cap, v < 10 ? "%.1f%c" : "%.0f%c", v, units[k]);
}
static void count(char *out, size_t cap, uint64_t v)
{
    if (v >= 10000000) {
        snprintf(out, cap, "%.1fM", (double)v / 1e6);
        return;
    }
    char digits[24];
    const int n = snprintf(digits, sizeof(digits), "%llu", (unsigned long long)v);
    size_t o = 0;
    for (int i = 0; i < n && o + 2 < cap; i++) {
        if (i && (n - i) % 3 == 0)
            out[o++] = ',';
        out[o++] = digits[i];
    }
    out[o] = 0;
}
static double seconds(uint64_t ns)
{
    return (double)ns / 1e9;
}

/* ------------------------------------------------------------- sparklines */
static void spark(struct ui *u, struct row *r, const float *v, uint32_t n, int width, enum color c)
{
    if (width > room(r))
        width = room(r);
    if (width <= 0)
        return;
    static const char *const blocks[8] = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84",
                                          "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" };
    static const char ascii[8] = { '_', '.', ':', '-', '=', '+', '*', '#' };
    r->graphic = 1;
    const uint32_t shown = n < (uint32_t)width ? n : (uint32_t)width;
    /* Scaled against half again the window's peak, so a steady rate draws
     * at two thirds and spikes stand out instead of a solid bar. */
    float lo = 0, hi = 0;
    for (uint32_t i = n - shown; i < n; i++)
        if (v[i] > hi)
            hi = v[i];
    hi *= 1.5f;
    pen(u, r, C_DIM, 0, NULL);
    for (int i = 0; i < width - (int)shown; i++)
        bput(&r->b, " ", 1);
    for (uint32_t i = n - shown; i < n; i++) {
        /* Seven eighths at most, so stacked rows stay visually apart. */
        int level = 0;
        if (hi > lo && v[i] > 0)
            level = 1 + (int)((v[i] - lo) / (hi - lo) * 5.999f);
        if (level > 6)
            level = 6;
        pen(u, r, level && u->color ? c : C_DIM, 0, NULL); /* no colour: dim, not the loudest thing */
        if (u->utf8 && !u->ascii)
            bstr(&r->b, blocks[level]);
        else
            bput(&r->b, &ascii[level], 1);
    }
    r->graphic = 0;
    pen(u, r, C_NONE, 0, NULL);
    r->col += width;
}
static void spark_u32(struct ui *u, struct row *r, const uint32_t *v, uint32_t n, int width, enum color c)
{
    float f[XRT_FD_HISTORY];
    uint32_t lo = UINT32_MAX;
    for (uint32_t i = 0; i < n; i++)
        if (v[i] < lo)
            lo = v[i];
    /* fd counts: show movement above the window's floor. */
    for (uint32_t i = 0; i < n; i++)
        f[i] = (float)(v[i] - lo);
    spark(u, r, f, n, width, c);
}

/* A stacked bar of fd kinds, one colour per kind. */
static void kindbar(struct ui *u, struct row *r, const uint32_t *kinds, int width)
{
    if (width > room(r))
        width = room(r);
    if (width <= 0)
        return;
    uint64_t total = 0;
    for (int k = 0; k < XRT_FD_KINDS; k++)
        total += kinds[k];
    static const char letters[XRT_FD_KINDS] = { 'f', 'd', 's', 'p', 'a', 'm', 'v', 'o' };
    int cells[XRT_FD_KINDS] = {0}, used = 0;
    if (total) {
        /* Largest remainder: every present kind gets at least one cell when it fits. */
        double rest[XRT_FD_KINDS];
        for (int k = 0; k < XRT_FD_KINDS; k++) {
            const double exact = (double)kinds[k] * width / (double)total;
            cells[k] = (int)exact;
            rest[k] = exact - cells[k];
            used += cells[k];
        }
        while (used < width) {
            int best = -1;
            for (int k = 0; k < XRT_FD_KINDS; k++)
                if (kinds[k] && (best < 0 || rest[k] > rest[best]))
                    best = k;
            if (best < 0)
                break;
            cells[best]++;
            rest[best] = -1;
            used++;
        }
    }
    r->graphic = 1;
    for (int k = 0; k < XRT_FD_KINDS; k++) {
        if (!cells[k])
            continue;
        if (k == XRT_FD_REGULAR)
            pen(u, r, C_DIM, 0, NULL);
        else
            pen(u, r, C_KIND, k, NULL);
        for (int i = 0; i < cells[k]; i++) {
            if (u->color && u->utf8 && !u->ascii)
                bstr(&r->b, "\xe2\x96\x86"); /* lower three quarters: rows stay apart */
            else
                bput(&r->b, &letters[k], 1);
        }
    }
    r->graphic = 0;
    pen(u, r, C_NONE, 0, NULL);
    for (int i = used; i < width; i++)
        bput(&r->b, " ", 1);
    r->col += width;
}

/* Offset within size as eighth-block progress. */
static void progress(struct ui *u, struct row *r, uint64_t pos, int64_t size, int width)
{
    if (width > room(r))
        width = room(r);
    if (width <= 0)
        return;
    if (size <= 0) {
        space(u, r, width);
        return;
    }
    double f = (double)pos / (double)size;
    if (f > 1)
        f = 1;
    const int eighths = (int)(f * width * 8 + 0.5);
    static const char *const part[8] = { "", "\xe2\x96\x8f", "\xe2\x96\x8e", "\xe2\x96\x8d", "\xe2\x96\x8c",
                                        "\xe2\x96\x8b", "\xe2\x96\x8a", "\xe2\x96\x89" };
    r->graphic = 1;
    pen(u, r, C_ACCENT, 0, NULL);
    int col = 0;
    for (; col < eighths / 8; col++)
        bstr(&r->b, u->utf8 && !u->ascii ? "\xe2\x96\x88" : "#");
    if (col < width && eighths % 8) {
        bstr(&r->b, u->utf8 && !u->ascii ? part[eighths % 8] : "+");
        col++;
    }
    pen(u, r, C_DIM, 0, NULL);
    for (; col < width; col++)
        bstr(&r->b, u->utf8 && !u->ascii ? "\xc2\xb7" : ".");
    r->graphic = 0;
    pen(u, r, C_NONE, 0, NULL);
    r->col += width;
}

/* -------------------------------------------------------------- redaction */
static const char *user_name(struct ui *u, uint32_t uid)
{
    for (int i = 0; i < u->nusers; i++)
        if (u->users[i].uid == uid)
            return u->users[i].name;
    struct user *e = u->nusers < USERS ? &u->users[u->nusers++] : &u->users[USERS - 1];
    e->uid = uid;
    struct passwd pw, *found = NULL;
    char scratch[1024];
    if (!getpwuid_r(uid, &pw, scratch, sizeof(scratch), &found) && found)
        snprintf(e->name, sizeof(e->name), "%s", found->pw_name);
    else
        snprintf(e->name, sizeof(e->name), "%u", uid);
    return e->name;
}
static void shown_user(struct ui *u, uint32_t uid, char *out, size_t cap)
{
    const char *name = user_name(u, uid);
    if (!u->redact || uid == 0) {
        snprintf(out, cap, "%s", name);
        return;
    }
    for (int i = 0; i < u->nusers; i++)
        if (u->users[i].uid == uid) {
            snprintf(out, cap, "user%d", i + 1);
            return;
        }
    snprintf(out, cap, "user");
}
static int word(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}
/* Replaces whole tokens only: a host "ion" must not turn "connection" into
 * "connecthost". */
static void replace_all(char *s, size_t cap, const char *from, const char *to)
{
    const size_t fn = strlen(from), tn = strlen(to);
    if (fn < 2)
        return;
    for (char *at = strstr(s, from); at; at = strstr(at, from)) {
        if ((at > s && word(at[-1])) || word(at[fn])) {
            at++;
            continue;
        }
        const size_t tail = strlen(at + fn);
        if ((size_t)(at - s) + tn + tail + 1 > cap) {
            *at = 0; /* no room: truncate rather than leave it unredacted */
            return;
        }
        memmove(at + tn, at + fn, tail + 1);
        memcpy(at, to, tn);
        at += tn;
    }
}
static int hex(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
static int alnum(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
/* cut: s may have been truncated (a 15-byte comm), so a run that reaches
 * its end needs only one colon. */
static void scrub_addresses(char *s, size_t cap, int cut)
{
    /* IPv6: a whole-word run of hex digits and colons with at least two
     * colons and one digit, plus any %zone, becomes x:x::x. Once two colons
     * are seen dots also continue the run, so an embedded IPv4 tail
     * (2001:db8::10.0.0.1) goes with its prefix; this pass runs first. */
    for (char *p = s; *p; p++) {
        if (!(hex(*p) || *p == ':') || (p > s && (alnum(p[-1]) || p[-1] == ':')))
            continue;
        char *q = p;
        int colons = 0, digits = 0;
        while (hex(*q) || *q == ':' || (*q == '.' && colons >= 2)) {
            colons += *q == ':';
            digits += hex(*q);
            q++;
        }
        if (*q == '%')
            for (q++; alnum(*q) || *q == '_' || *q == '.' || *q == '-'; q++)
                ;
        if (colons < (cut && !*q ? 1 : 2) || !digits || alnum(*q))
            continue;
        const size_t tail = strlen(q);
        if ((size_t)(p - s) + 6 + tail + 1 > cap) {
            *p = 0; /* no room: truncate rather than leave it unredacted */
            return;
        }
        memmove(p + 6, q, tail + 1);
        memcpy(p, "x:x::x", 6);
        p += 5;
    }
    /* Dotted IPv4 quads become x.x.x.x. */
    for (char *p = s; *p; p++) {
        if (*p < '0' || *p > '9' || (p > s && ((p[-1] >= '0' && p[-1] <= '9') || p[-1] == '.')))
            continue;
        char *q = p;
        int dots = 0;
        while ((*q >= '0' && *q <= '9') || *q == '.')
            dots += *q++ == '.';
        if (dots == 3 && q[-1] != '.') {
            memmove(p + 7, q, strlen(q) + 1);
            memcpy(p, "x.x.x.x", 7);
            p += 6;
        }
    }
}
/* Redacted names: system paths stay, other paths keep only their name. */
static void scrub_cut(struct ui *u, char *s, size_t cap, int cut);
static void scrub(struct ui *u, char *s, size_t cap)
{
    scrub_cut(u, s, cap, 0);
}
static void scrub_cut(struct ui *u, char *s, size_t cap, int cut)
{
    if (!u->redact)
        return;
    static const char *const keep[] = { "/dev/", "/usr/", "/lib", "/bin/", "/sbin/", "/etc/", "/proc/", "/sys/", "/memfd:", "/run/" };
    static const char *const exact[] = { "/", "/tmp", "/var/tmp" };
    if (s[0] == '/') {
        int kept = 0;
        for (size_t i = 0; i < sizeof(keep) / sizeof(keep[0]); i++)
            kept |= !strncmp(s, keep[i], strlen(keep[i]));
        for (size_t i = 0; i < sizeof(exact) / sizeof(exact[0]); i++)
            kept |= !strcmp(s, exact[i]) || (!strncmp(s, exact[i], strlen(exact[i])) && !strcmp(s + strlen(exact[i]), " (deleted)"));
        if (!kept) {
            const char *name = strrchr(s, '/');
            char tail[1024];
            snprintf(tail, sizeof(tail), "%s", name + 1);
            snprintf(s, cap, "%s/%s", u->utf8 ? "\xe2\x80\xa6" : "...", tail);
        }
    }
    if (u->host[0])
        replace_all(s, cap, u->host, "host");
    if (u->short_host[0])
        replace_all(s, cap, u->short_host, "host");
    for (int i = 0; i < u->nusers; i++)
        if (strcmp(u->users[i].name, "root") && u->users[i].name[0] > '9') {
            char alias[16];
            snprintf(alias, sizeof(alias), "user%d", i + 1);
            replace_all(s, cap, u->users[i].name, alias);
        }
    scrub_addresses(s, cap, cut);
}
static const char *link_text(struct ui *u, const struct xrt_fd *f, char *out, size_t cap)
{
    snprintf(out, cap, "%s", f->link_length ? u->snap.strings + f->link : (f->flags & XRT_FD_LINK_CUT) ? "(name not kept: limit)" : "?");
    if (f->flags & XRT_FD_DELETED) {
        const size_t n = strlen(out);
        if (n > 10 && !strcmp(out + n - 10, " (deleted)"))
            out[n - 10] = 0;
    }
    scrub(u, out, cap);
    return out;
}
static const char *command(struct ui *u, const struct xrt_fd_process *p, char *out, size_t cap)
{
    out[0] = 0;
    if (!p->cmdline_length) {
        snprintf(out, cap, "[%s]", p->comm);
        scrub(u, out, cap);
        return out;
    }
    const char *args = u->snap.strings + p->cmdline;
    if (u->redact) {
        /* argv[0] only, cut at its first space: programs that rewrite their
         * title (sshd, postgres) put their arguments there. */
        snprintf(out, cap, "%.*s", (int)strcspn(args, " "), args);
        scrub(u, out, cap);
        const char *name = strrchr(out, '/');
        if (name)
            memmove(out, name + 1, strlen(name + 1) + 1);
        if ((strlen(args) + 1 < p->cmdline_length || strchr(args, ' ')) && strlen(out) + 4 < cap)
            strcat(out, u->utf8 ? " \xe2\x80\xa6" : " ...");
        return out;
    }
    size_t o = 0;
    for (uint32_t i = 0; i < p->cmdline_length && o + 1 < cap; i++)
        out[o++] = args[i] ? args[i] : ' ';
    while (o && out[o - 1] == ' ')
        o--;
    out[o] = 0;
    return out;
}
static const char *comm(struct ui *u, const struct xrt_fd_process *p, char *out, size_t cap)
{
    snprintf(out, cap, "%s", p->comm);
    if (u->redact)
        scrub_cut(u, out, cap, strlen(p->comm) == sizeof(p->comm) - 1);
    return out;
}

/* ------------------------------------------------------------------ model */
static const struct xrt_fd_process *owner(const struct ui *u, uint32_t fd_index)
{
    uint32_t lo = 0, hi = u->snap.process_count;
    while (lo < hi) {
        const uint32_t mid = lo + (hi - lo) / 2;
        const struct xrt_fd_process *p = &u->snap.processes[mid];
        if (fd_index < p->first)
            hi = mid;
        else if (fd_index >= p->first + p->count)
            lo = mid + 1;
        else
            return p;
    }
    return NULL;
}
static const struct xrt_fd_process *focused(const struct ui *u)
{
    for (uint32_t i = 0; i < u->snap.process_count; i++) {
        const struct xrt_fd_process *p = &u->snap.processes[i];
        if (p->pid == u->focus_pid && p->start == u->focus_start)
            return p;
    }
    return NULL;
}
static double p_churn(const struct xrt_fd_process *p)
{
    return p->churn_rate;
}
static double p_io(const struct xrt_fd_process *p)
{
    return (double)p->read_rate + p->write_rate;
}
static double p_slope(const struct xrt_fd_process *p)
{
    const struct xrt_fd_history *h = &p->history;
    if (h->samples < 2 || h->ms[h->samples - 1] == h->ms[0])
        return 0;
    return ((double)h->fds[h->samples - 1] - (double)h->fds[0]) * 60000.0 / (double)(h->ms[h->samples - 1] - h->ms[0]);
}
static uint64_t file_key(const struct xrt_fd_file *f)
{
    return f->device * 0x9e3779b97f4a7c15ull ^ f->inode;
}

static struct ui *G; /* qsort context; one UI per process */
static int cmp_double(double a, double b)
{
    return (a < b) - (a > b); /* descending */
}
static int cmp_u64(uint64_t a, uint64_t b)
{
    return (a < b) - (a > b);
}
static int by_view(const void *a, const void *b)
{
    const uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    const struct ui *u = G;
    const int s = u->sort[u->view];
    int c = 0;
    switch (u->view) {
    case V_PROCS:
    case V_LEAKS: {
        const struct xrt_fd_process *p = &u->snap.processes[x], *q = &u->snap.processes[y];
        if (u->view == V_LEAKS) {
            if (s == 0)
                c = cmp_u64(xrt_fd_growth(p), xrt_fd_growth(q));
            else if (s == 1)
                c = cmp_double(p_slope(p), p_slope(q));
            else
                c = cmp_u64(p->count, q->count);
            if (!c)
                c = cmp_u64(p->flags & XRT_FDP_LEAKING, q->flags & XRT_FDP_LEAKING);
        } else if (s == 0)
            c = cmp_double(p_churn(p), p_churn(q));
        else if (s == 1)
            c = cmp_u64(p->count, q->count);
        else if (s == 2)
            c = cmp_u64(xrt_fd_growth(p), xrt_fd_growth(q));
        else if (s == 3)
            c = cmp_double(p_io(p), p_io(q));
        else
            c = -cmp_u64((uint64_t)p->pid, (uint64_t)q->pid);
        if (!c)
            c = cmp_u64(p->count, q->count);
        if (!c)
            c = -cmp_u64((uint64_t)p->pid, (uint64_t)q->pid);
        break;
    }
    case V_FILES:
    case V_DELETED: {
        /* Active files first, then idle ones and groups, largest group first. */
        const struct xrt_fd_file *f = &u->files[x & GROUP ? u->groups[x & ~GROUP].first : x];
        const struct xrt_fd_file *g = &u->files[y & GROUP ? u->groups[y & ~GROUP].first : y];
        const uint32_t xn = x & GROUP ? u->groups[x & ~GROUP].count : 1, yn = y & GROUP ? u->groups[y & ~GROUP].count : 1;
        const uint32_t xf = x & GROUP ? u->groups[x & ~GROUP].fds : f->fds, yf = y & GROUP ? u->groups[y & ~GROUP].fds : g->fds;
        if (u->view == V_DELETED)
            c = s == 0 ? cmp_u64((uint64_t)f->size, (uint64_t)g->size) : cmp_u64(f->holders, g->holders);
        else {
            c = cmp_u64(f->rate > 0, g->rate > 0);
            if (!c && s == 0)
                c = f->rate > 0 ? cmp_double(f->rate, g->rate) : cmp_u64(xn, yn);
            else if (!c && s == 1)
                c = cmp_u64(f->holders, g->holders);
            else if (!c && s == 2)
                c = cmp_u64(xf, yf);
            else if (!c)
                c = cmp_u64((uint64_t)f->size, (uint64_t)g->size);
        }
        if (!c)
            c = cmp_u64(xf, yf);
        if (!c)
            c = -cmp_u64(x, y);
        break;
    }
    case V_FDS:
    case V_HOLDERS: {
        const struct xrt_fd *f = &u->snap.fds[x], *g = &u->snap.fds[y];
        if (u->view == V_FDS && s == 1)
            c = cmp_double(f->rate, g->rate);
        else if (u->view == V_FDS && s == 2)
            c = cmp_u64(f->pos, g->pos);
        else if (u->view == V_HOLDERS && s == 1)
            c = cmp_double(f->rate, g->rate);
        if (!c)
            c = -cmp_u64(x, y);
        break;
    }
    }
    return u->reverse[u->view] ? -c : c;
}

static int contains(const char *hay, const char *needle)
{
    return !needle[0] || strcasestr(hay, needle) != NULL;
}
static int match_process(struct ui *u, const struct xrt_fd_process *p, const char *filter)
{
    if (!filter[0])
        return 1;
    char text[700], line[512], user[40], name[32];
    shown_user(u, p->uid, user, sizeof(user));
    snprintf(text, sizeof(text), "%d %s %s %s", p->pid, comm(u, p, name, sizeof(name)), user, command(u, p, line, sizeof(line)));
    return contains(text, filter);
}
static int match_fd(struct ui *u, const struct xrt_fd *f, const char *filter)
{
    if (!filter[0])
        return 1;
    char text[4200], link[4096];
    snprintf(text, sizeof(text), "%d %s %s", f->fd, xrt_fd_kind_name(f->kind), link_text(u, f, link, sizeof(link)));
    return contains(text, filter);
}

static int list_push(struct ui *u, uint32_t v)
{
    if (u->nlist == u->list_cap) {
        const uint32_t cap = u->list_cap ? u->list_cap * 2 : 1024;
        uint32_t *grown = realloc(u->list, cap * sizeof(*grown));
        if (!grown)
            return 0;
        u->list = grown;
        u->list_cap = cap;
    }
    u->list[u->nlist++] = v;
    return 1;
}
static uint64_t row_key(const struct ui *u, uint32_t v)
{
    switch (u->view) {
    case V_PROCS:
    case V_LEAKS: return v < u->snap.process_count ? (uint64_t)(uint32_t)u->snap.processes[v].pid : 0;
    case V_FILES:
    case V_DELETED:
        if (v & GROUP)
            return (u->groups[v & ~GROUP].set * 31 + u->groups[v & ~GROUP].kind) | 1;
        return file_key(&u->files[v]);
    case V_FDS: return (uint64_t)(uint32_t)u->snap.fds[v].fd;
    case V_HOLDERS: {
        const struct xrt_fd_process *p = owner(u, v);
        return ((uint64_t)(p ? (uint32_t)p->pid : 0) << 32) | (uint32_t)u->snap.fds[v].fd;
    }
    }
    return 0;
}

static int by_group(const void *a, const void *b)
{
    const struct xrt_fd_file *f = &G->files[*(const uint32_t *)a], *g = &G->files[*(const uint32_t *)b];
    if (f->kind != g->kind)
        return f->kind < g->kind ? -1 : 1;
    if (f->holder_set != g->holder_set)
        return f->holder_set < g->holder_set ? -1 : 1;
    return (*(const uint32_t *)a > *(const uint32_t *)b) - (*(const uint32_t *)a < *(const uint32_t *)b);
}
static int grow_groups(struct ui *u)
{
    const uint32_t cap = u->groups_cap ? u->groups_cap * 2 : 256;
    struct group *grown = realloc(u->groups, cap * sizeof(*grown));
    if (!grown)
        return 0;
    u->groups = grown;
    u->groups_cap = cap;
    return 1;
}

static void build(struct ui *u)
{
    u->nlist = 0;
    const char *filter = u->filter[u->view];
    if (u->view == V_PROCS || u->view == V_LEAKS) {
        for (uint32_t i = 0; i < u->snap.process_count; i++) {
            const struct xrt_fd_process *p = &u->snap.processes[i];
            if (u->view == V_LEAKS && !xrt_fd_growth(p))
                continue;
            if (match_process(u, p, filter) && !list_push(u, i))
                break;
        }
    } else if (u->view == V_FILES || u->view == V_DELETED) {
        uint32_t nidle = 0;
        u->ngroups = 0;
        for (uint32_t i = 0; i < u->nfiles; i++) {
            const struct xrt_fd_file *f = &u->files[i];
            if (u->view == V_DELETED && (!(f->flags & XRT_FD_DELETED) || f->kind != XRT_FD_REGULAR))
                continue;
            if (u->view == V_FILES && u->expanded &&
                (f->rate > 0 || f->kind != u->expanded_kind || f->holder_set != u->expanded_set || (f->flags & XRT_FD_DELETED)))
                continue;
            if (filter[0]) {
                const struct xrt_fd_process *p = owner(u, f->sample);
                char text[4200], link[4096], name[32];
                snprintf(text, sizeof(text), "%s %s %s", xrt_fd_kind_name((enum xrt_fd_kind)f->kind),
                         link_text(u, &u->snap.fds[f->sample], link, sizeof(link)), p ? comm(u, p, name, sizeof(name)) : "");
                if (!contains(text, filter))
                    continue;
            }
            if (u->view == V_FILES && !u->expanded && f->rate <= 0 && !(f->flags & XRT_FD_DELETED)) {
                if (nidle == u->idle_cap) {
                    const uint32_t cap = u->idle_cap ? u->idle_cap * 2 : 1024;
                    uint32_t *grown = realloc(u->idle, cap * sizeof(*grown));
                    if (!grown)
                        break;
                    u->idle = grown;
                    u->idle_cap = cap;
                }
                u->idle[nidle++] = i;
                continue;
            }
            if (!list_push(u, i))
                break;
        }
        /* Collapse idle files sharing a kind and holder set. */
        G = u;
        if (nidle > 1)
            qsort(u->idle, nidle, sizeof(*u->idle), by_group);
        for (uint32_t i = 0; i < nidle;) {
            const struct xrt_fd_file *f = &u->files[u->idle[i]];
            uint32_t j = i, fds = 0;
            for (; j < nidle && u->files[u->idle[j]].kind == f->kind && u->files[u->idle[j]].holder_set == f->holder_set; j++)
                fds += u->files[u->idle[j]].fds;
            if (j - i == 1) {
                for (uint32_t k = i; k < j; k++)
                    list_push(u, u->idle[k]);
            } else if (u->ngroups < u->groups_cap || grow_groups(u)) {
                u->groups[u->ngroups] = (struct group){ .set = f->holder_set, .kind = f->kind, .count = j - i, .fds = fds, .first = u->idle[i] };
                list_push(u, GROUP | u->ngroups++);
            }
            i = j;
        }
    } else if (u->view == V_FDS) {
        const struct xrt_fd_process *p = focused(u);
        for (uint32_t i = 0; p && i < p->count; i++)
            if (match_fd(u, &u->snap.fds[p->first + i], filter) && !list_push(u, p->first + i))
                break;
    } else {
        for (uint32_t i = 0; i < u->snap.process_count; i++) {
            const struct xrt_fd_process *p = &u->snap.processes[i];
            for (uint32_t k = 0; k < p->count; k++) {
                const uint32_t at = p->first + k;
                const struct xrt_fd *f = &u->snap.fds[at];
                const int same = f->kind == XRT_FD_ANON ? at == u->focus_sample && f->inode == u->focus_inode
                                                        : (f->flags & XRT_FD_STAT) && f->device == u->focus_device && f->inode == u->focus_inode;
                if (same && match_process(u, p, filter) && !list_push(u, at))
                    break;
            }
        }
    }
    G = u;
    if (u->nlist > 1) /* qsort must not see a NULL base, even for zero items */
        qsort(u->list, u->nlist, sizeof(*u->list), by_view);
    /* Keep the selection on the same item across refreshes. */
    int *sel = &u->sel[u->view];
    if (u->sel_key[u->view]) {
        for (uint32_t i = 0; i < u->nlist; i++)
            if (row_key(u, u->list[i]) == u->sel_key[u->view]) {
                *sel = (int)i;
                break;
            }
    }
    if (*sel >= (int)u->nlist)
        *sel = u->nlist ? (int)u->nlist - 1 : 0;
    if (*sel < 0)
        *sel = 0;
}

/* ------------------------------------------------------------------ frame */
static void frame_reset(struct ui *u)
{
    for (int i = 0; i < u->frame_lines; i++) {
        u->frame[i].b.n = 0;
        if (u->frame[i].b.b)
            u->frame[i].b.b[0] = 0;
        u->frame[i].col = 0;
        u->frame[i].width = u->cols;
        u->frame[i].selected = u->frame[i].graphic = 0;
    }
}
static void finish(struct ui *u, struct row *r)
{
    if (room(r) > 0)
        space(u, r, room(r));
    pen(u, r, C_NONE, 0, NULL);
}

static void header(struct ui *u)
{
    struct row *r = &u->frame[0];
    char a[96], b[32];
    pen(u, r, C_TITLE, 0, NULL);
    puts_(u, r, " lsof-top ");
    pen(u, r, C_NONE, 0, NULL);
    pen(u, r, C_DIM, 0, NULL);
    snprintf(a, sizeof(a), "  poll %gs", u->interval);
    puts_(u, r, a);
    pen(u, r, C_NONE, 0, NULL);
    count(b, sizeof(b), u->snap.process_count);
    snprintf(a, sizeof(a), "   procs %s", b);
    puts_(u, r, a);
    if (u->snap.hidden) {
        pen(u, r, C_DIM, 0, NULL);
        snprintf(a, sizeof(a), " + %u hidden", u->snap.hidden);
        puts_(u, r, a);
        pen(u, r, C_NONE, 0, NULL);
    }
    count(b, sizeof(b), u->snap.fd_count);
    snprintf(a, sizeof(a), "   fds %s", b);
    puts_(u, r, a);
    if (u->snap.stale || u->snap.unscanned || u->snap.dropped_fds || u->snap.dropped_processes || u->snap.cut_strings) {
        pen(u, r, C_WARN, 0, NULL);
        snprintf(a, sizeof(a), "   partial: %u stale %u unscanned %u+%u dropped", u->snap.stale, u->snap.unscanned,
                 u->snap.dropped_processes, u->snap.dropped_fds);
        puts_(u, r, a);
        pen(u, r, C_NONE, 0, NULL);
    }
    /* What deleted files pin and our own cost follow the counts; run time
     * (never wall-clock time, so captures carry no time zone) sits right. */
    uint32_t deleted = 0;
    int64_t pinned = 0;
    for (uint32_t i = 0; i < u->nfiles; i++)
        if ((u->files[i].flags & XRT_FD_DELETED) && u->files[i].kind == XRT_FD_REGULAR) {
            deleted++;
            pinned += u->files[i].size;
        }
    char when[32];
    const uint64_t t = (u->snap.taken_ns - u->started) / 1000000000u;
    if (u->frozen)
        snprintf(when, sizeof(when), " FROZEN ");
    else
        snprintf(when, sizeof(when), " +%02u:%02u:%02u ", (unsigned)(t / 3600), (unsigned)(t / 60 % 60), (unsigned)(t % 60));
    const int keep_time = text_width(u, when);
    human(b, sizeof(b), (double)pinned);
    if (deleted)
        snprintf(a, sizeof(a), "   deleted-open %u pin %s", deleted, b);
    else
        snprintf(a, sizeof(a), "   deleted-open 0");
    if (room(r) > text_width(u, a) + keep_time) {
        pen(u, r, deleted ? C_KIND : C_DIM, XRT_FD_KINDS, deleted ? "1" : NULL);
        puts_(u, r, a);
    }
    snprintf(a, sizeof(a), "   scan %.1fms %.1f%% cpu", seconds(u->snap.scan_ns) * 1e3, u->cpu_percent);
    if (room(r) > text_width(u, a) + keep_time) {
        pen(u, r, C_DIM, 0, NULL);
        puts_(u, r, a);
    }
    if (room(r) >= keep_time) {
        space(u, r, room(r) - keep_time);
        pen(u, r, u->frozen ? C_WARN : C_DIM, 0, u->frozen ? "1" : NULL);
        puts_(u, r, when);
    }
    finish(u, r);

    /* Meters: the latest value, its recent history, and the peak it is
     * scaled against. */
    r = &u->frame[1];
    float v[120];
    const int narrow = u->cols < 100, value = narrow ? 8 : 9, peak = u->cols < 140 ? 0 : 9;
    int w = (u->cols - 2 - 4 * (5 + value + 2) - 3 * peak) / 4;
    w = w < 4 ? 4 : w > 24 ? 24 : w;
    struct {
        const char *label;
        enum xrt_fd_metric metric;
        enum color color;
        int bytes;
    } m[] = { { "read", XRT_FD_METRIC_READ, C_GOOD, 1 }, { "write", XRT_FD_METRIC_WRITE, C_WARN, 1 },
              { "churn", XRT_FD_METRIC_CHURN, C_ACCENT, 0 }, { "fds", XRT_FD_METRIC_FDS, C_ACCENT, 0 } };
    space(u, r, 1);
    for (size_t i = 0; i < sizeof(m) / sizeof(m[0]); i++) {
        const uint32_t n = xrt_fdscan_totals(u->scan, m[i].metric, v, 120);
        const float last = n ? v[n - 1] : 0;
        float top = 0;
        for (uint32_t k = 0; k < n; k++)
            if (v[k] > top)
                top = v[k];
        if (m[i].metric == XRT_FD_METRIC_FDS) {
            /* Show movement above the window's floor. */
            float lo = n ? v[0] : 0;
            for (uint32_t k = 0; k < n; k++)
                if (v[k] < lo)
                    lo = v[k];
            for (uint32_t k = 0; k < n; k++)
                v[k] -= lo;
        }
        pen(u, r, C_DIM, 0, NULL);
        put(u, r, m[i].label, 5, 0);
        pen(u, r, C_NONE, 0, "1");
        if (!u->snap.interval_ns && m[i].metric != XRT_FD_METRIC_FDS)
            snprintf(a, sizeof(a), "-");
        else if (m[i].bytes) {
            human(b, sizeof(b), last);
            snprintf(a, sizeof(a), "%s/s", b);
        } else if (m[i].metric == XRT_FD_METRIC_FDS) {
            count(b, sizeof(b), u->snap.fd_count);
            snprintf(a, sizeof(a), "%s", b);
        } else
            snprintf(a, sizeof(a), "%.0f/s", last);
        put(u, r, a, value, 1);
        space(u, r, 1);
        pen(u, r, C_NONE, 0, NULL);
        spark(u, r, v, n, w, m[i].color);
        if (peak && m[i].metric != XRT_FD_METRIC_FDS) {
            pen(u, r, C_DIM, 0, NULL);
            if (m[i].bytes)
                human(b, sizeof(b), top);
            else
                snprintf(b, sizeof(b), "%.0f", top);
            snprintf(a, sizeof(a), " pk %s", b);
            put(u, r, a, peak, 0);
        }
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
    }
    finish(u, r);

    r = &u->frame[2];
    space(u, r, 1);
    const int top = u->view >= V_FDS ? u->back : u->view;
    for (int i = 0; i < 4; i++) {
        snprintf(a, sizeof(a), " %d %s ", i + 1, view_titles[i]);
        pen(u, r, i == top ? C_ACCENT : C_DIM, 0, i == top ? "1;7" : NULL);
        puts_(u, r, a);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
    }
    if (u->view >= V_FDS) {
        pen(u, r, C_ACCENT, 0, "1");
        const struct xrt_fd_process *p = focused(u);
        char name[32];
        if (u->view == V_FDS)
            snprintf(a, sizeof(a), u->utf8 ? " \xe2\x96\xb8 fds of %d %s" : " > fds of %d %s", u->focus_pid, p ? comm(u, p, name, sizeof(name)) : "(exited)");
        else
            snprintf(a, sizeof(a), u->utf8 ? " \xe2\x96\xb8 holders" : " > holders");
        puts_(u, r, a);
        pen(u, r, C_NONE, 0, NULL);
    } else if (u->view == V_FILES && u->expanded) {
        pen(u, r, C_ACCENT, 0, "1");
        snprintf(a, sizeof(a), u->utf8 ? " \xe2\x96\xb8 %s group" : " > %s group", xrt_fd_kind_name((enum xrt_fd_kind)u->expanded_kind));
        puts_(u, r, a);
        pen(u, r, C_NONE, 0, NULL);
    }
    {
        const char *sort = sort_names[u->view][u->sort[u->view]];
        snprintf(a, sizeof(a), "sort %s %s ", sort, u->reverse[u->view] ? (u->utf8 ? "\xe2\x96\xb2" : "^") : (u->utf8 ? "\xe2\x96\xbc" : "v"));
        char f[FILTER + 16] = "";
        if (u->filter[u->view][0])
            snprintf(f, sizeof(f), "filter \"%s\"  ", u->filter[u->view]);
        const int need = text_width(u, a) + text_width(u, f);
        if (room(r) > need + 1) {
            space(u, r, room(r) - need);
            pen(u, r, C_WARN, 0, NULL);
            puts_(u, r, f);
            pen(u, r, C_DIM, 0, NULL);
            puts_(u, r, a);
        }
    }
    finish(u, r);
}

struct column {
    const char *title;
    int width, right;
};
static void titles(struct ui *u, struct row *r, const struct column *c, int n)
{
    pen(u, r, C_DIM, 0, "1");
    space(u, r, 1);
    for (int i = 0; i < n; i++) {
        put(u, r, c[i].title, c[i].width ? c[i].width : room(r), c[i].right);
        if (i + 1 < n)
            space(u, r, 1);
    }
    finish(u, r);
}

static const char *target_of(const struct ui *u, const struct xrt_fd *f)
{
    return f->kind == XRT_FD_PIPE || f->kind == XRT_FD_SOCKET ? xrt_fd_kind_name((enum xrt_fd_kind)f->kind) : u->snap.strings + f->link;
}
static int by_string(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}
/* The commonest target in a process's fd table, by one sort. */
static const char *commonest(struct ui *u, const struct xrt_fd_process *p, uint32_t *n)
{
    *n = 0;
    if (!p->count)
        return NULL;
    const char **names = malloc(p->count * sizeof(*names));
    if (!names)
        return NULL;
    for (uint32_t i = 0; i < p->count; i++)
        names[i] = target_of(u, &u->snap.fds[p->first + i]);
    if (p->count > 1)
        qsort(names, p->count, sizeof(*names), by_string);
    const char *best = NULL;
    for (uint32_t i = 0; i < p->count;) {
        uint32_t j = i + 1;
        while (j < p->count && !strcmp(names[j], names[i]))
            j++;
        if (j - i > *n) {
            *n = j - i;
            best = names[i];
        }
        i = j;
    }
    free(names);
    return best; /* points into the snapshot, not into names */
}

/* Holder columns give way on narrow terminals: the name shortens before the pid. */
static int holders_width(const struct ui *u)
{
    return u->cols < 100 ? 18 : 26;
}

static void process_row(struct ui *u, struct row *r, const struct xrt_fd_process *p, int leaks)
{
    char a[64], user[40], name[32], line[1024];
    snprintf(a, sizeof(a), "%d", p->pid);
    put(u, r, a, 7, 1);
    space(u, r, 1);
    if (!leaks || u->cols >= 100) { /* narrow Leaks gives USER's room to what accumulates */
        shown_user(u, p->uid, user, sizeof(user));
        pen(u, r, C_DIM, 0, NULL);
        put(u, r, user, 8, 0);
        space(u, r, 1);
    }
    pen(u, r, C_NONE, 0, "1");
    put(u, r, comm(u, p, name, sizeof(name)), 15, 0);
    pen(u, r, C_NONE, 0, NULL);
    space(u, r, 1);
    count(a, sizeof(a), p->count);
    put(u, r, a, 6, 1);
    space(u, r, 1);
    const uint32_t growth = xrt_fd_growth(p);
    if (leaks) {
        snprintf(a, sizeof(a), "+%u", growth);
        pen(u, r, (p->flags & XRT_FDP_LEAKING) ? C_ALERT : C_WARN, 0, "1");
        put(u, r, a, 7, 1);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
        const int narrow = u->cols < 100;
        if (!narrow) {
            snprintf(a, sizeof(a), "%+.0f", p_slope(p));
            put(u, r, a, 7, 1);
            space(u, r, 1);
        }
        spark_u32(u, r, p->history.fds, p->history.samples, narrow ? 8 : 20, (p->flags & XRT_FDP_LEAKING) ? C_ALERT : C_WARN);
        space(u, r, 1);
        /* What is accumulating: kinds above the window's low point, then the
         * commonest target over the whole table. */
        struct buf grew = {0};
        for (int k = 0; k < XRT_FD_KINDS; k++)
            if (p->grew[k])
                bprintf(&grew, "%s+%u %s", grew.n ? " " : "", p->grew[k], xrt_fd_kind_name((enum xrt_fd_kind)k));
        pen(u, r, C_WARN, 0, NULL);
        put(u, r, grew.b ? grew.b : "", narrow ? 18 : 30, 0);
        free(grew.b);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
        uint32_t best_n = 0;
        const char *best = commonest(u, p, &best_n);
        if (best) {
            char shown[960];
            snprintf(shown, sizeof(shown), "%s", best);
            scrub(u, shown, sizeof(shown));
            snprintf(line, sizeof(line), u->utf8 ? "%s \xc3\x97%u" : "%s x%u", shown, best_n);
            cell(u, r, line, strlen(line), room(r), 0, 1);
        }
        return;
    }
    if (p->d_count)
        snprintf(a, sizeof(a), "%+d", p->d_count);
    else if (growth)
        snprintf(a, sizeof(a), "+%u", growth);
    else
        a[0] = 0;
    pen(u, r, p->d_count > 0 || (p->flags & XRT_FDP_LEAKING) ? C_WARN : p->d_count < 0 ? C_GOOD : C_DIM, 0, NULL);
    put(u, r, a, 6, 1);
    pen(u, r, C_NONE, 0, NULL);
    space(u, r, 1);
    const int fresh = !p->interval_ns && !(p->flags & XRT_FDP_STALE);
    if (fresh)
        snprintf(a, sizeof(a), "-");
    else
        snprintf(a, sizeof(a), "%.0f", p_churn(p));
    pen(u, r, p_churn(p) > 0 ? C_ACCENT : C_DIM, 0, NULL);
    put(u, r, a, 7, 1);
    pen(u, r, C_NONE, 0, NULL);
    space(u, r, 1);
    for (int side = 0; side < 2; side++) {
        const double v = side ? p->write_rate : p->read_rate;
        if (p->flags & XRT_FDP_NO_IO)
            snprintf(a, sizeof(a), "n/a");
        else if (fresh)
            snprintf(a, sizeof(a), "-");
        else
            human(a, sizeof(a), v);
        pen(u, r, v > 0 ? (side ? C_WARN : C_GOOD) : C_DIM, 0, NULL);
        put(u, r, a, 7, 1);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
    }
    kindbar(u, r, p->kinds, 10);
    space(u, r, 1);
    const int s = u->sort[V_PROCS];
    if (s == 0) {
        float f[XRT_FD_HISTORY];
        for (uint32_t i = 0; i < p->history.samples; i++)
            f[i] = (float)p->history.churn[i];
        spark(u, r, f, p->history.samples, u->spark_width, C_ACCENT);
    } else if (s == 3)
        spark(u, r, p->history.io, p->history.samples, u->spark_width, C_GOOD);
    else
        spark_u32(u, r, p->history.fds, p->history.samples, u->spark_width, C_WARN);
    space(u, r, 1);
    pen(u, r, C_DIM, 0, NULL);
    put(u, r, command(u, p, line, sizeof(line)), room(r), 0);
}

static void access_mode(const struct xrt_fd *f, char *out)
{
    strcpy(out, "");
    if (!(f->flags & XRT_FD_INFO))
        return;
    switch (f->open_flags & O_ACCMODE) {
    case O_RDONLY: strcpy(out, "r"); break;
    case O_WRONLY: strcpy(out, "w"); break;
    default: strcpy(out, "rw"); break;
    }
}
static void flag_letters(const struct xrt_fd *f, char *out)
{
    size_t n = 0;
    if (f->flags & XRT_FD_INFO) {
        if (f->open_flags & O_APPEND)
            out[n++] = 'A';
        if (f->open_flags & O_NONBLOCK)
            out[n++] = 'N';
        if (f->open_flags & O_CLOEXEC)
            out[n++] = 'C';
        if (f->open_flags & O_DIRECT)
            out[n++] = 'D';
        if (f->open_flags & O_SYNC)
            out[n++] = 'S';
        if (f->open_flags & O_PATH)
            out[n++] = 'P';
    }
    out[n] = 0;
}
static void kind_cell(struct ui *u, struct row *r, const struct xrt_fd *f, int width)
{
    char a[32];
    const char *name = xrt_fd_kind_name((enum xrt_fd_kind)f->kind);
    if (f->kind == XRT_FD_ANON && f->link_length > 11) {
        /* anon_inode:[eventfd] -> eventfd */
        const char *t = u->snap.strings + f->link + 11;
        snprintf(a, sizeof(a), "%.*s", (int)strcspn(t + (*t == '['), "]"), t + (*t == '['));
        name = a;
    }
    pen(u, r, C_KIND, (f->flags & XRT_FD_DELETED) ? XRT_FD_KINDS : f->kind, NULL);
    put(u, r, name, width, 0);
    pen(u, r, C_NONE, 0, NULL);
}

static void fd_row(struct ui *u, struct row *r, const struct xrt_fd *f, const struct xrt_fd_process *p, int holders)
{
    char a[64], link[4096];
    if (holders) {
        char user[40], name[32];
        snprintf(a, sizeof(a), "%d", p ? p->pid : 0);
        put(u, r, a, 7, 1);
        space(u, r, 1);
        shown_user(u, p ? p->uid : 0, user, sizeof(user));
        pen(u, r, C_DIM, 0, NULL);
        put(u, r, user, 8, 0);
        pen(u, r, C_NONE, 0, "1");
        space(u, r, 1);
        put(u, r, p ? comm(u, p, name, sizeof(name)) : "", 15, 0);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
    }
    snprintf(a, sizeof(a), "%d", f->fd);
    put(u, r, a, 5, 1);
    space(u, r, 1);
    kind_cell(u, r, f, 9);
    space(u, r, 1);
    access_mode(f, a);
    put(u, r, a, 4, 0);
    space(u, r, 1);
    char flags[8];
    flag_letters(f, flags);
    pen(u, r, C_DIM, 0, NULL);
    put(u, r, flags, 5, 0);
    pen(u, r, C_NONE, 0, NULL);
    space(u, r, 1);
    const int positional = (f->flags & XRT_FD_INFO) && (f->kind == XRT_FD_REGULAR || f->kind == XRT_FD_MEMFD || f->kind == XRT_FD_DEVICE);
    if (positional)
        human(a, sizeof(a), (double)f->pos);
    else
        strcpy(a, "");
    put(u, r, a, 7, 1);
    space(u, r, 1);
    (void)p;
    if (f->rate > 0) {
        human(a, sizeof(a), f->rate);
        strcat(a, "/s");
    } else
        strcpy(a, "");
    pen(u, r, f->rate > 0 ? C_GOOD : C_DIM, 0, "1");
    put(u, r, a, 9, 1);
    pen(u, r, C_NONE, 0, NULL);
    space(u, r, 1);
    if (f->kind == XRT_FD_REGULAR || f->kind == XRT_FD_MEMFD)
        human(a, sizeof(a), (double)f->size);
    else
        strcpy(a, "");
    put(u, r, a, 6, 1);
    space(u, r, 1);
    if (!holders) {
        if (positional && f->kind != XRT_FD_DEVICE)
            progress(u, r, f->pos, f->size, 10);
        else
            space(u, r, 10);
        space(u, r, 1);
    }
    pen(u, r, C_KIND, (f->flags & XRT_FD_DELETED) ? XRT_FD_KINDS : f->kind == XRT_FD_REGULAR ? -1 : f->kind, NULL);
    link_text(u, f, link, sizeof(link));
    if (f->flags & XRT_FD_DELETED)
        strncat(link, " (deleted)", sizeof(link) - strlen(link) - 1);
    /* anon_inode:[eventfd] -> [eventfd]: KIND already names it, and a cut
     * on the left would leave "…inode:[eventfd]". */
    const char *shown = f->kind == XRT_FD_ANON && !strncmp(link, "anon_inode:", 11) ? link + 11 : link;
    cell(u, r, shown, strlen(shown), room(r), 0, 1);
    pen(u, r, C_NONE, 0, NULL);
}

static void file_row(struct ui *u, struct row *r, const struct xrt_fd_file *f, int deleted)
{
    char a[64], link[4096], name[32];
    const struct xrt_fd *sample = &u->snap.fds[f->sample];
    const struct xrt_fd_process *p = owner(u, f->sample);
    if (deleted) {
        human(a, sizeof(a), (double)f->size);
        pen(u, r, C_ALERT, 0, "1");
        put(u, r, a, 7, 1);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
        human(a, sizeof(a), (double)f->disk);
        put(u, r, a, 7, 1);
        space(u, r, 1);
    } else {
        if (f->rate > 0) {
            human(a, sizeof(a), f->rate);
            strcat(a, "/s");
        } else
            strcpy(a, "");
        pen(u, r, f->rate > 0 ? C_GOOD : C_DIM, 0, "1");
        put(u, r, a, 9, 1);
        pen(u, r, C_NONE, 0, NULL);
        space(u, r, 1);
        strcpy(a, f->read_rate > 0 && f->write_rate > 0 ? "rw" : f->read_rate > 0 ? "r" : f->write_rate > 0 ? "w" : f->rate > 0 ? "rw" : "");
        put(u, r, a, 2, 0);
        space(u, r, 1);
        kind_cell(u, r, sample, 9);
        space(u, r, 1);
        if (f->kind == XRT_FD_REGULAR || f->kind == XRT_FD_MEMFD)
            human(a, sizeof(a), (double)f->size);
        else
            strcpy(a, "");
        put(u, r, a, 6, 1);
        space(u, r, 1);
    }
    snprintf(a, sizeof(a), "%u", f->fds);
    put(u, r, a, 4, 1);
    space(u, r, 1);
    char who[96], tail[32];
    if (f->holders > 1)
        snprintf(tail, sizeof(tail), "[%d] +%u", p ? p->pid : 0, f->holders - 1);
    else
        snprintf(tail, sizeof(tail), "[%d]", p ? p->pid : 0);
    /* The command name gives way before the pid does. */
    const int hw = holders_width(u);
    snprintf(who, sizeof(who), "%.*s%s", (int)((size_t)hw - strlen(tail) > 15 ? 15 : (size_t)hw - strlen(tail)), p ? comm(u, p, name, sizeof(name)) : "?", tail);
    put(u, r, who, hw, 0);
    space(u, r, 1);
    pen(u, r, C_KIND, (f->flags & XRT_FD_DELETED) ? XRT_FD_KINDS : f->kind == XRT_FD_REGULAR ? -1 : f->kind, NULL);
    link_text(u, sample, link, sizeof(link));
    cell(u, r, link, strlen(link), room(r), 0, 1);
    pen(u, r, C_NONE, 0, NULL);
}

/* "38 pipes" held by the same processes, with the pipe's peers named. */
static void group_row(struct ui *u, struct row *r, const struct group *g)
{
    static const char *const plural[XRT_FD_KINDS] = { "files", "dirs", "sockets", "pipes", "anon fds", "memfds", "devices", "others" };
    const struct xrt_fd_file *f = &u->files[g->first];
    const struct xrt_fd_process *p = owner(u, f->sample);
    char a[64], name[32], other[32], text[256];
    space(u, r, 9 + 1 + 2 + 1);
    kind_cell(u, r, &u->snap.fds[f->sample], 9);
    space(u, r, 1 + 6 + 1);
    snprintf(a, sizeof(a), "%u", g->fds);
    put(u, r, a, 4, 1);
    space(u, r, 1);
    char tail[32];
    if (f->holders > 1)
        snprintf(tail, sizeof(tail), "[%d] +%u", p ? p->pid : 0, f->holders - 1);
    else
        snprintf(tail, sizeof(tail), "[%d]", p ? p->pid : 0);
    char who[96];
    const int hw = holders_width(u);
    snprintf(who, sizeof(who), "%.*s%s", (int)((size_t)hw - strlen(tail) > 15 ? 15 : (size_t)hw - strlen(tail)), p ? comm(u, p, name, sizeof(name)) : "?", tail);
    put(u, r, who, hw, 0);
    space(u, r, 1);
    /* Peers: the other holder of the sample, found by device and inode. */
    const struct xrt_fd_process *q = NULL;
    for (uint32_t i = 0; f->holders == 2 && i < u->snap.process_count && !q; i++) {
        const struct xrt_fd_process *c = &u->snap.processes[i];
        if (c == p)
            continue;
        for (uint32_t k = 0; k < c->count; k++) {
            const struct xrt_fd *x = &u->snap.fds[c->first + k];
            if ((x->flags & XRT_FD_STAT) && x->device == f->device && x->inode == f->inode && x->kind != XRT_FD_ANON) {
                q = c;
                break;
            }
        }
    }
    const char *arrow = u->utf8 ? "\xe2\x86\x94" : "<->";
    if (q)
        snprintf(text, sizeof(text), "%u %s %s %s[%d] %s %s[%d]", g->count, plural[g->kind], u->utf8 ? "\xc2\xb7" : "-",
                 p ? comm(u, p, name, sizeof(name)) : "?", p ? p->pid : 0, arrow, comm(u, q, other, sizeof(other)), q->pid);
    else if (f->holders == 1 && (g->kind == XRT_FD_PIPE || g->kind == XRT_FD_SOCKET))
        snprintf(text, sizeof(text), "%u %s %s both ends in %s[%d]", g->count, plural[g->kind], u->utf8 ? "\xc2\xb7" : "-",
                 p ? comm(u, p, name, sizeof(name)) : "?", p ? p->pid : 0);
    else
        snprintf(text, sizeof(text), g->kind == XRT_FD_REGULAR || g->kind == XRT_FD_MEMFD ? "%u idle %s" : "%u %s, no offset data",
                 g->count, plural[g->kind]);
    pen(u, r, C_KIND, (int)g->kind == XRT_FD_REGULAR ? -1 : (int)g->kind, "1");
    const int hint = text_width(u, text) + 10 <= room(r);
    put(u, r, text, hint ? text_width(u, text) : room(r), 0);
    if (hint) {
        pen(u, r, C_DIM, 0, NULL);
        put(u, r, "  (Enter)", room(r), 0);
    }
    pen(u, r, C_NONE, 0, NULL);
}

static const char *const help_text[] = {
    "lsof-top: open files and descriptor activity, polled from /proc",
    "",
    "  1-4, Tab, Shift-Tab   Files, Processes, Leaks, Deleted",
    "  Up/Down j/k PgUp/PgDn Home/End   move the selection",
    "  Enter     open: a process's fd table, or a file's holders",
    "  Esc, Backspace, Left   back",
    "  /         filter this view (Enter keeps it, Esc clears it)",
    "  s / r     cycle the sort key / reverse it",
    "  space     freeze or resume sampling",
    "  + / -     slower or faster sampling",
    "  q         quit;  ? toggles this help",
    "",
    "Columns",
    "  CHURN/s   fd-set changes per second between samples: an open and close",
    "            inside one interval is invisible to polling",
    "  READ/WRITE /proc/PID/io rchar and wchar per second (all IO, any fd)",
    "  IO/s      file offset advance per second (seekable files only)",
    "  MODE      r, w or rw access",
    "  CHANGE    fds opened minus closed since the last sample",
    "  GROWTH    fds above the lowest count in the last 32 samples",
    "  Files     files of one kind without offset movement, held by the same",
    "            processes, share a row; pipes and sockets have no offsets at all",
    "  FLAGS     A append  N nonblock  C cloexec  D direct  S sync  P path",
    "  KINDS     bar of fd kinds; without colour f file d dir s socket p pipe",
    "            a anon m memfd v device o other",
    "",
    "Other users' processes are counted as hidden: /proc denies their fd tables.",
};

/* Fills a sparse Processes view: what the whole system holds right now. */
static void summary(struct ui *u, int line, int last)
{
    char a[160], b[32];
    struct row *r;
    const int label = 9;
    if (line > last)
        return;
    r = &u->frame[line++];
    space(u, r, 2);
    pen(u, r, C_DIM, 0, "1");
    put(u, r, "system", label, 0);
    pen(u, r, C_NONE, 0, NULL);
    kindbar(u, r, u->snap.kinds, 30);
    for (int k = 0; k < XRT_FD_KINDS; k++)
        if (u->snap.kinds[k] && room(r) > 16) {
            count(b, sizeof(b), u->snap.kinds[k]);
            snprintf(a, sizeof(a), "  %s %s", b, xrt_fd_kind_name((enum xrt_fd_kind)k));
            pen(u, r, C_KIND, k == XRT_FD_REGULAR ? -1 : k, NULL);
            puts_(u, r, a);
        }
    finish(u, r);
    if (line > last)
        return;
    r = &u->frame[line++];
    space(u, r, 2);
    pen(u, r, C_DIM, 0, "1");
    put(u, r, "busiest", label, 0);
    pen(u, r, C_NONE, 0, NULL);
    int shown = 0;
    for (uint32_t i = 0; i < u->nfiles && shown < 3 && u->files[i].rate > 0; i++, shown++) {
        char link[4096], rate_text[32];
        const struct xrt_fd_file *f = &u->files[i];
        link_text(u, &u->snap.fds[f->sample], link, sizeof(link));
        human(rate_text, sizeof(rate_text), f->rate);
        snprintf(a, sizeof(a), "%s%.60s %s/s", shown ? "   " : "", link, rate_text);
        pen(u, r, C_GOOD, 0, NULL);
        if (room(r) > text_width(u, a))
            puts_(u, r, a);
    }
    if (!shown) {
        pen(u, r, C_DIM, 0, NULL);
        put(u, r, "no file offsets moved in the last interval", room(r), 0);
    }
    finish(u, r);
    if (line > last)
        return;
    r = &u->frame[line++];
    space(u, r, 2);
    pen(u, r, C_DIM, 0, "1");
    put(u, r, "unseen", label, 0);
    pen(u, r, C_DIM, 0, NULL);
    if (u->snap.hidden)
        snprintf(a, sizeof(a), "%u processes of other users are hidden: /proc denies their fd tables; run as that user to see them",
                 u->snap.hidden);
    else
        snprintf(a, sizeof(a), "none hidden: every listed process's fd table is readable");
    put(u, r, a, room(r), 0);
    finish(u, r);
    if (line > last || !u->snap.kernel_threads)
        return;
    r = &u->frame[line];
    space(u, r, 2 + label);
    pen(u, r, C_DIM, 0, NULL);
    snprintf(a, sizeof(a), "%u kernel threads hold no fds and are left out", u->snap.kernel_threads);
    put(u, r, a, room(r), 0);
    finish(u, r);
}

static void body(struct ui *u)
{
    const int top_line = 3, last = u->lines - 2;
    if (u->help) {
        const int lines = (int)(sizeof(help_text) / sizeof(help_text[0])), shown = last - top_line;
        if (u->help_top > lines - shown)
            u->help_top = lines - shown;
        if (u->help_top < 0)
            u->help_top = 0;
        for (int i = top_line; i <= last; i++) {
            struct row *r = &u->frame[i];
            const int k = i - top_line - 1 + u->help_top;
            if (i == last && u->help_top + shown < lines) {
                space(u, r, 2);
                pen(u, r, C_DIM, 0, NULL);
                put(u, r, u->utf8 ? "\xe2\x86\x93 more: j/k or arrows scroll" : "more: j/k scroll", room(r), 0);
                finish(u, r);
                continue;
            }
            if (k >= 0 && k < (int)(sizeof(help_text) / sizeof(help_text[0]))) {
                space(u, r, 2);
                pen(u, r, k == 0 || !strcmp(help_text[k], "Columns") ? C_ACCENT : C_NONE, 0, k == 0 ? "1" : NULL);
                put(u, r, help_text[k], room(r), 0);
            }
            finish(u, r);
        }
        return;
    }
    struct row *t = &u->frame[top_line];
    /* Per-row sparklines take the width the command column can spare. */
    u->spark_width = u->cols - 84 - 30;
    u->spark_width = u->spark_width < 12 ? 12 : u->spark_width > 30 ? 30 : u->spark_width;
    switch (u->view) {
    case V_PROCS: {
        const struct column c[] = { { "PID", 7, 1 }, { "USER", 8, 0 }, { "COMMAND", 15, 0 }, { "FDS", 6, 1 }, { "CHANGE", 6, 1 }, { "CHURN/s", 7, 1 },
                                    { "READ/s", 7, 1 }, { "WRITE/s", 7, 1 }, { "KINDS", 10, 0 },
                                    { u->sort[V_PROCS] == 0 ? "CHURN TREND" : u->sort[V_PROCS] == 3 ? "IO TREND" : "FDS TREND", u->spark_width, 0 }, { "CMD", 0, 0 } };
        titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    case V_LEAKS: {
        const struct column c[] = { { "PID", 7, 1 }, { "USER", 8, 0 }, { "COMMAND", 15, 0 }, { "FDS", 6, 1 }, { "GROWTH", 7, 1 }, { "PER MIN", 7, 1 },
                                    { "FD COUNT", 20, 0 }, { "ACCUMULATING", 30, 0 }, { "MOST COMMON", 0, 0 } };
        const struct column n[] = { { "PID", 7, 1 }, { "COMMAND", 15, 0 }, { "FDS", 6, 1 }, { "GROWTH", 7, 1 },
                                    { "TREND", 8, 0 }, { "ACCUMULATING", 18, 0 }, { "MOST COMMON", 0, 0 } };
        if (u->cols < 100)
            titles(u, t, n, (int)(sizeof(n) / sizeof(n[0])));
        else
            titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    case V_FILES: {
        const struct column c[] = { { "IO/s", 9, 1 }, { "", 2, 0 }, { "KIND", 9, 0 }, { "SIZE", 6, 1 }, { "FDS", 4, 1 }, { "HOLDERS", holders_width(u), 0 }, { "PATH", 0, 0 } };
        titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    case V_DELETED: {
        const struct column c[] = { { "PINNED", 7, 1 }, { "ON DISK", 7, 1 }, { "FDS", 4, 1 }, { "HOLDERS", holders_width(u), 0 }, { "PATH (deleted)", 0, 0 } };
        titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    case V_FDS: {
        const struct column c[] = { { "FD", 5, 1 }, { "KIND", 9, 0 }, { "MODE", 4, 0 }, { "FLAGS", 5, 0 }, { "OFFSET", 7, 1 }, { "IO/s", 9, 1 }, { "SIZE", 6, 1 }, { "PROGRESS", 10, 0 }, { "TARGET", 0, 0 } };
        titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    case V_HOLDERS: {
        const struct column c[] = { { "PID", 7, 1 }, { "USER", 8, 0 }, { "COMMAND", 15, 0 }, { "FD", 5, 1 }, { "KIND", 9, 0 }, { "MODE", 4, 0 }, { "FLAGS", 5, 0 }, { "OFFSET", 7, 1 }, { "IO/s", 9, 1 }, { "SIZE", 6, 1 }, { "TARGET", 0, 0 } };
        titles(u, t, c, (int)(sizeof(c) / sizeof(c[0])));
        break;
    }
    }
    const int height = last - top_line;
    int *sel = &u->sel[u->view], *top = &u->top[u->view];
    if (*sel < *top)
        *top = *sel;
    if (*sel >= *top + height)
        *top = *sel - height + 1;
    if (*top > (int)u->nlist - height)
        *top = (int)u->nlist - height;
    if (*top < 0)
        *top = 0;
    if (!u->nlist) {
        struct row *r = &u->frame[top_line + 2];
        const char *empty = u->view == V_FDS && !focused(u) ? "process exited" : u->filter[u->view][0] ? "nothing matches the filter" :
                            u->view == V_LEAKS ? "no process has grown its fd count yet" : u->view == V_DELETED ? "no deleted files are held open" : "nothing to show";
        pen(u, r, C_DIM, 0, NULL);
        space(u, r, 2);
        put(u, r, empty, room(r), 0);
        finish(u, r);
    }
    for (int i = 0; i < height && *top + i < (int)u->nlist; i++) {
        struct row *r = &u->frame[top_line + 1 + i];
        const uint32_t v = u->list[*top + i];
        r->selected = *top + i == *sel;
        pen(u, r, r->selected ? C_ACCENT : C_NONE, 0, r->selected ? "1" : NULL);
        /* A marker as well as the band, for terminals without colour. */
        puts_(u, r, !r->selected ? " " : u->utf8 ? "\xe2\x96\xb8" : ">");
        pen(u, r, C_NONE, 0, NULL);
        switch (u->view) {
        case V_PROCS: process_row(u, r, &u->snap.processes[v], 0); break;
        case V_LEAKS: process_row(u, r, &u->snap.processes[v], 1); break;
        case V_FILES:
            if (v & GROUP)
                group_row(u, r, &u->groups[v & ~GROUP]);
            else
                file_row(u, r, &u->files[v], 0);
            break;
        case V_DELETED: file_row(u, r, &u->files[v], 1); break;
        case V_FDS: fd_row(u, r, &u->snap.fds[v], focused(u), 0); break;
        case V_HOLDERS: fd_row(u, r, &u->snap.fds[v], owner(u, v), 1); break;
        }
        finish(u, r);
    }
    if (u->nlist)
        u->sel_key[u->view] = row_key(u, u->list[*sel]);
    if (u->view == V_PROCS && (int)u->nlist + 9 <= height && !u->filter[u->view][0])
        summary(u, top_line + (int)u->nlist + 3, last);
}

static void footer(struct ui *u)
{
    struct row *r = &u->frame[u->lines - 1];
    if (u->editing) {
        pen(u, r, C_ACCENT, 0, "1");
        puts_(u, r, " / ");
        pen(u, r, C_NONE, 0, NULL);
        puts_(u, r, u->filter[u->view]);
        pen(u, r, C_NONE, 0, "7");
        puts_(u, r, " ");
        pen(u, r, C_DIM, 0, NULL);
        puts_(u, r, "   Enter keep  Esc clear");
        finish(u, r);
        return;
    }
    if (u->message[0] && u->snap.taken_ns > u->message_ns + 3000000000ull && !u->frozen)
        u->message[0] = 0;
    const int fixed = 16; /* " ? help  q quit " */
    if (u->message[0]) {
        space(u, r, 1);
        pen(u, r, C_WARN, 0, u->frozen ? "1" : NULL);
        put(u, r, u->message, room(r) - fixed > 0 ? room(r) - fixed : 0, 0);
    }
    /* Help and quit always show, at the right; the others drop from the end
     * of the list as the terminal narrows. */
    static const char *const keys[][2] = { { "Tab", "view" }, { "\xe2\x86\x91\xe2\x86\x93", "select" }, { "Enter", "open" }, { "Esc", "back" },
                                           { "/", "filter" }, { "s", "sort" }, { "space", "freeze" }, { "r", "reverse" },
                                           { "+-", "rate" } };
    for (size_t i = 0; !u->message[0] && i < sizeof(keys) / sizeof(keys[0]); i++) {
        const char *k = keys[i][0];
        if (!u->utf8 && i == 1)
            k = "j/k";
        if (room(r) - fixed < text_width(u, k) + (int)strlen(keys[i][1]) + 3)
            break;
        space(u, r, 1);
        pen(u, r, C_ACCENT, 0, "1");
        puts_(u, r, k);
        pen(u, r, C_DIM, 0, NULL);
        space(u, r, 1);
        puts_(u, r, keys[i][1]);
        space(u, r, 1);
    }
    if (room(r) > fixed)
        space(u, r, room(r) - fixed);
    for (int i = 0; i < 2 && room(r) > 0; i++) {
        space(u, r, 1);
        pen(u, r, C_ACCENT, 0, "1");
        puts_(u, r, i ? "q" : "?");
        pen(u, r, C_DIM, 0, NULL);
        space(u, r, 1);
        puts_(u, r, i ? "quit" : "help");
        space(u, r, 1);
    }
    finish(u, r);
}

static void compose(struct ui *u)
{
    frame_reset(u);
    if (u->cols < 60 || u->lines < 10) {
        struct row *r = &u->frame[0];
        put(u, r, "too small (60x10)", room(r), 0);
        return;
    }
    build(u);
    header(u);
    body(u);
    footer(u);
}

/* --------------------------------------------------------------- terminal */
static struct termios saved_tty;
static volatile sig_atomic_t tty_active, got_winch, got_quit, got_stop;
static const char enter_screen[] = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J";
static const char leave_screen[] = "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l";

static void write_all(int fd, const char *s, size_t n)
{
    while (n) {
        const ssize_t w = write(fd, s, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0 && errno == EAGAIN) {
            struct pollfd p = { .fd = fd, .events = POLLOUT };
            poll(&p, 1, 100);
            continue;
        }
        if (w <= 0)
            return;
        s += w;
        n -= (size_t)w;
    }
}
/* Async-signal-safe: also used by the crash handlers. */
static void restore_tty(void)
{
    if (!tty_active)
        return;
    tty_active = 0;
    write_all(STDOUT_FILENO, leave_screen, sizeof(leave_screen) - 1);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_tty);
}
static int enter_tty(void)
{
    struct termios raw = saved_tty;
    raw.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw))
        return -1;
    tty_active = 1;
    write_all(STDOUT_FILENO, enter_screen, sizeof(enter_screen) - 1);
    return 0;
}
static void on_crash(int sig)
{
    restore_tty();
    signal(sig, SIG_DFL);
    raise(sig);
}
static void on_signal(int sig)
{
    if (sig == SIGWINCH)
        got_winch = 1;
    else if (sig == SIGTSTP)
        got_stop = 1;
    else
        got_quit = sig;
}

static void size_from_tty(struct ui *u)
{
    struct winsize ws;
    if (!ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) && ws.ws_col && ws.ws_row) {
        u->cols = ws.ws_col;
        u->lines = ws.ws_row;
    }
    if (u->cols > 1000)
        u->cols = 1000;
    if (u->lines > 500)
        u->lines = 500;
}
static int resize(struct ui *u)
{
    for (int i = 0; i < u->frame_lines; i++) {
        free(u->frame[i].b.b);
        free(u->shown[i].b);
    }
    free(u->frame);
    free(u->shown);
    u->frame_lines = u->lines;
    u->frame = calloc((size_t)u->lines, sizeof(*u->frame));
    u->shown = calloc((size_t)u->lines, sizeof(*u->shown));
    return u->frame && u->shown ? 0 : -1;
}

/* Emit only the lines that changed, inside one synchronized update. */
static void present(struct ui *u, int full)
{
    u->out.n = 0;
    bstr(&u->out, "\x1b[?2026h");
    if (full)
        bstr(&u->out, "\x1b[0m\x1b[2J");
    for (int i = 0; i < u->lines; i++) {
        struct buf *line = &u->frame[i].b, *was = &u->shown[i];
        const char *now = line->b ? line->b : "";
        if (!full && was->b && !strcmp(was->b, now))
            continue;
        /* Erase first, then draw: rows are full width and autowrap is off, so
         * an erase after the row would take its last column with it. */
        bprintf(&u->out, "\x1b[%d;1H\x1b[0m\x1b[2K", i + 1);
        bstr(&u->out, now);
        bstr(&u->out, "\x1b[0m");
        was->n = 0;
        bstr(was, now);
    }
    bstr(&u->out, "\x1b[?2026l");
    write_all(STDOUT_FILENO, u->out.b, u->out.n);
}

/* ------------------------------------------------------------------ input */
/* A key, 0 for an unknown sequence, -1 when nothing is waiting, -2 when the
 * terminal has gone away. */
static int pushed = -1; /* a key read past a lone Esc, delivered next */
static int read_key(void)
{
    if (pushed >= 0) {
        const int k = pushed;
        pushed = -1;
        return k;
    }
    unsigned char c;
    const ssize_t got = read(STDIN_FILENO, &c, 1);
    if (got == 0 || (got < 0 && errno != EAGAIN && errno != EINTR))
        return -2;
    if (got != 1)
        return -1;
    if (c != 0x1b)
        return c;
    unsigned char s[8];
    size_t n = 0;
    struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
    while (n < sizeof(s) && poll(&p, 1, n ? 5 : 30) == 1 && read(STDIN_FILENO, &s[n], 1) == 1) {
        n++;
        if (n >= 2 && ((s[n - 1] >= 'A' && s[n - 1] <= 'Z') || s[n - 1] == '~'))
            break;
        if (n == 1 && s[0] != '[' && s[0] != 'O')
            break;
    }
    if (n == 1 && s[0] != '[' && s[0] != 'O') {
        pushed = s[0]; /* Esc then a typed key, not a sequence */
        return K_ESC;
    }
    if (n < 2)
        return K_ESC;
    switch (s[n - 1]) {
    case 'A': return K_UP;
    case 'B': return K_DOWN;
    case 'C': return K_RIGHT;
    case 'D': return K_LEFT;
    case 'H': return K_HOME;
    case 'F': return K_END;
    case 'Z': return K_BTAB;
    case '~':
        if (s[1] == '5')
            return K_PGUP;
        if (s[1] == '6')
            return K_PGDN;
        if (s[1] == '1' || s[1] == '7')
            return K_HOME;
        if (s[1] == '4' || s[1] == '8')
            return K_END;
        break;
    default: break;
    }
    return 0;
}

static void open_selected(struct ui *u)
{
    if (!u->nlist || u->sel[u->view] < 0 || u->sel[u->view] >= (int)u->nlist)
        return;
    const uint32_t v = u->list[u->sel[u->view]];
    if ((v & GROUP) && u->view != V_FILES)
        return;
    if ((u->view == V_PROCS || u->view == V_LEAKS) && v >= u->snap.process_count)
        return;
    switch (u->view) {
    case V_PROCS:
    case V_LEAKS:
    case V_HOLDERS: {
        const struct xrt_fd_process *p = u->view == V_HOLDERS ? owner(u, v) : &u->snap.processes[v];
        if (!p)
            return;
        u->from_holders = u->view == V_HOLDERS;
        if (u->view != V_HOLDERS)
            u->back = u->view;
        u->focus_pid = p->pid;
        u->focus_start = p->start;
        u->view = V_FDS;
        u->sel[V_FDS] = u->top[V_FDS] = 0;
        u->sel_key[V_FDS] = 0;
        xrt_fdscan_detail(u->scan, p->pid);
        break;
    }
    case V_FILES:
    case V_DELETED: {
        if (v & GROUP) {
            u->expanded = 1;
            u->expanded_kind = u->groups[v & ~GROUP].kind;
            u->expanded_set = u->groups[v & ~GROUP].set;
            u->sel[V_FILES] = u->top[V_FILES] = 0;
            u->sel_key[V_FILES] = 0;
            break;
        }
        const struct xrt_fd_file *f = &u->files[v];
        u->back = u->view;
        u->focus_device = f->device;
        u->focus_inode = f->inode;
        u->focus_sample = f->sample;
        u->view = V_HOLDERS;
        u->sel[V_HOLDERS] = u->top[V_HOLDERS] = 0;
        u->sel_key[V_HOLDERS] = 0;
        break;
    }
    case V_FDS: break;
    }
}

static void key(struct ui *u, int k)
{
    u->message[0] = 0;
    /* Keys typed ahead in one read may follow a view switch: the list must
     * belong to the view they act on, not the one last drawn. */
    if (!u->editing)
        build(u);
    if (u->editing) {
        char *f = u->filter[u->view];
        const size_t n = strlen(f);
        if (k == '\r' || k == '\n')
            u->editing = 0;
        else if (k == K_ESC) {
            f[0] = 0;
            u->editing = 0;
        } else if ((k == 127 || k == 8) && n)
            f[n - 1] = 0;
        else if (k >= 0x20 && k < 0x7f && n + 1 < FILTER) {
            f[n] = (char)k;
            f[n + 1] = 0;
        }
        u->sel[u->view] = 0;
        u->sel_key[u->view] = 0;
        return;
    }
    if (u->help && k != -1) {
        if (k == 'j' || k == K_DOWN || k == K_PGDN || k == 'k' || k == K_UP || k == K_PGUP) {
            const int step = k == K_PGDN || k == K_PGUP ? u->lines - 6 : 1;
            u->help_top += k == 'j' || k == K_DOWN || k == K_PGDN ? step : -step;
            return;
        }
        u->help = 0;
        u->help_top = 0;
        if (k == '?' || k == K_ESC)
            return;
    }
    const int page = u->lines - 6 > 1 ? u->lines - 6 : 1;
    int *sel = &u->sel[u->view];
    const int moved = *sel;
    switch (k) {
    case 'q':
    case 3: u->quit = 1; break;
    case '?': u->help = 1; break;
    case ' ':
        u->frozen = !u->frozen;
        snprintf(u->message, sizeof(u->message), u->frozen ? "frozen: sampling paused (space resumes)" : "sampling resumed");
        u->message_ns = u->snap.taken_ns;
        break;
    case '/': u->editing = 1; break;
    case 's': {
        int s = u->sort[u->view] + 1;
        if (s >= SORTS || !sort_names[u->view][s])
            s = 0;
        u->sort[u->view] = s;
        break;
    }
    case 'r': u->reverse[u->view] = !u->reverse[u->view]; break;
    case '+':
    case '-': {
        static const double steps[] = { 0.25, 0.5, 1, 2, 5, 10 };
        int i = 0;
        while (i < 5 && steps[i] < u->interval)
            i++;
        i += k == '+' ? 1 : -1;
        u->interval = steps[i < 0 ? 0 : i > 5 ? 5 : i];
        if (u->budget_default)
            xrt_fdscan_budget(u->scan, (uint32_t)(u->interval * 500));
        snprintf(u->message, sizeof(u->message), "sampling every %gs", u->interval);
        u->message_ns = u->snap.taken_ns;
        break;
    }
    case '\t': u->view = u->view >= V_FDS ? u->back : (u->view + 1) % 4; break;
    case K_BTAB: u->view = u->view >= V_FDS ? u->back : (u->view + 3) % 4; break;
    case '1':
    case '2':
    case '3':
    case '4': u->view = k - '1'; break;
    case K_UP:
    case 'k': (*sel)--; break;
    case K_DOWN:
    case 'j': (*sel)++; break;
    case K_PGUP: *sel -= page; break;
    case K_PGDN: *sel += page; break;
    case K_HOME:
    case 'g': *sel = 0; break;
    case K_END:
    case 'G': *sel = (int)u->nlist - 1; break;
    case '\r':
    case '\n':
    case K_RIGHT: open_selected(u); break;
    case K_ESC:
    case 127:
    case 8:
    case K_LEFT:
        if (u->view == V_FDS && u->from_holders) {
            u->view = V_HOLDERS;
            u->from_holders = 0;
        }
        else if (u->view >= V_FDS)
            u->view = u->back;
        else if (u->filter[u->view][0])
            u->filter[u->view][0] = 0;
        else if (u->view == V_FILES && u->expanded) {
            u->expanded = 0;
            u->sel_key[V_FILES] = 0;
        }
        break;
    default: break;
    }
    if (u->view < V_FDS)
        xrt_fdscan_detail(u->scan, 0);
    if (*sel != moved) {
        if (*sel >= (int)u->nlist)
            *sel = (int)u->nlist - 1;
        if (*sel < 0)
            *sel = 0;
        u->sel_key[u->view] = u->nlist ? row_key(u, u->list[*sel]) : 0;
    }
}

/* ------------------------------------------------------------------- json */
static void jstr(struct ui *u, struct buf *b, const char *s, size_t n)
{
    bput(b, "\"", 1);
    for (size_t i = 0; i < n;) {
        const unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') {
            bput(b, "\\", 1);
            bput(b, s + i, 1);
            i++;
        } else if (c == '\n' || c == '\t' || c == '\r') {
            bstr(b, c == '\n' ? "\\n" : c == '\t' ? "\\t" : "\\r");
            i++;
        } else if (c < 0x20 || c == 0x7f) {
            bprintf(b, "\\u%04x", c);
            i++;
        } else if (c < 0x80) {
            bput(b, s + i, 1);
            i++;
        } else {
            /* Only well-formed UTF-8 passes; anything else becomes U+FFFD. */
            size_t len = c >= 0xf0 && c < 0xf5 ? 4 : c >= 0xe0 && c < 0xf0 ? 3 : c >= 0xc2 && c < 0xe0 ? 2 : 0;
            int ok = len && i + len <= n;
            for (size_t k = 1; ok && k < len; k++)
                ok = ((unsigned char)s[i + k] & 0xc0) == 0x80;
            if (ok && len == 3) {
                const unsigned char d = (unsigned char)s[i + 1];
                ok = !(c == 0xe0 && d < 0xa0) && !(c == 0xed && d >= 0xa0);
            }
            if (ok && len == 4) {
                const unsigned char d = (unsigned char)s[i + 1];
                ok = !(c == 0xf0 && d < 0x90) && !(c == 0xf4 && d >= 0x90);
            }
            if (ok) {
                bput(b, s + i, len);
                i += len;
            } else {
                bstr(b, "\\ufffd");
                i++;
            }
        }
    }
    bput(b, "\"", 1);
    (void)u;
}
static void jkinds(struct buf *b, const uint32_t *kinds)
{
    bstr(b, "{");
    for (int k = 0; k < XRT_FD_KINDS; k++)
        bprintf(b, "%s\"%s\":%u", k ? "," : "", xrt_fd_kind_name((enum xrt_fd_kind)k), kinds[k]);
    bstr(b, "}");
}
static void jfd(struct ui *u, struct buf *b, const struct xrt_fd *f, const struct xrt_fd_process *p)
{
    char link[4096], mode[4];
    access_mode(f, mode);
    bprintf(b, "{\"fd\":%d,\"kind\":\"%s\",\"target\":", f->fd, xrt_fd_kind_name((enum xrt_fd_kind)f->kind));
    link_text(u, f, link, sizeof(link));
    jstr(u, b, link, strlen(link));
    bprintf(b, ",\"deleted\":%s,\"opened\":%s,\"access\":\"%s\"", (f->flags & XRT_FD_DELETED) ? "true" : "false",
            (f->flags & XRT_FD_OPENED) ? "true" : "false", mode);
    if (f->flags & XRT_FD_INFO)
        bprintf(b, ",\"pos\":%llu,\"flags\":\"0%o\"", (unsigned long long)f->pos, f->open_flags);
    if (f->flags & XRT_FD_STAT)
        bprintf(b, ",\"device\":%llu,\"inode\":%llu,\"size\":%lld,\"disk\":%lld", (unsigned long long)f->device,
                (unsigned long long)f->inode, (long long)f->size, (long long)f->disk);
    (void)p;
    bprintf(b, ",\"generation\":%u,\"advance_per_s\":%.1f}", f->generation, f->rate);
}
static void json(struct ui *u, struct buf *b, int fd_tables, uint32_t limit)
{
    const struct xrt_fd_snapshot *v = &u->snap;
    bprintf(b, "{\"schema\":1,\"tool\":\"lsof-top\",\"source\":\"poll\",\"sequence\":%llu,\"interval_s\":%.6f,",
            (unsigned long long)v->sequence, seconds(v->interval_ns));
    bprintf(b, "\"scan\":{\"ms\":%.3f,\"cpu_ms\":%.3f,\"processes\":%u,\"hidden\":%u,\"kernel_threads\":%u,"
               "\"unscanned\":%u,\"gone\":%u,\"stale\":%u,\"dropped_processes\":%u,\"dropped_fds\":%u,\"cut_strings\":%u},",
            seconds(v->scan_ns) * 1e3, seconds(v->scan_cpu_ns) * 1e3, v->process_count, v->hidden, v->kernel_threads,
            v->unscanned, v->gone, v->stale, v->dropped_processes, v->dropped_fds, v->cut_strings);
    uint32_t deleted = 0;
    int64_t pinned = 0, pinned_disk = 0;
    for (uint32_t i = 0; i < u->nfiles; i++)
        if ((u->files[i].flags & XRT_FD_DELETED) && u->files[i].kind == XRT_FD_REGULAR) {
            deleted++;
            pinned += u->files[i].size;
            pinned_disk += u->files[i].disk;
        }
    bprintf(b, "\"totals\":{\"fds\":%u,\"kinds\":", v->fd_count);
    jkinds(b, v->kinds);
    bprintf(b, ",\"opened\":%llu,\"closed\":%llu,\"read_per_s\":%.1f,\"write_per_s\":%.1f,\"advance_per_s\":%.1f,"
               "\"deleted_files\":%u,\"deleted_bytes\":%lld,\"deleted_disk\":%lld},",
            (unsigned long long)v->opened, (unsigned long long)v->closed, v->read_rate, v->write_rate, v->advance_rate,
            deleted, (long long)pinned, (long long)pinned_disk);
    bstr(b, "\"processes\":[");
    int first = 1;
    for (uint32_t i = 0; i < v->process_count; i++) {
        const struct xrt_fd_process *p = &v->processes[i];
        char user[40], line[1024], name[32];
        shown_user(u, p->uid, user, sizeof(user));
        bprintf(b, "%s{\"pid\":%d,\"ppid\":%d,\"start\":%llu,\"user\":", first ? "" : ",", p->pid, p->ppid, (unsigned long long)p->start);
        first = 0;
        jstr(u, b, user, strlen(user));
        bstr(b, ",\"comm\":");
        comm(u, p, name, sizeof(name));
        jstr(u, b, name, strlen(name));
        bstr(b, ",\"cmd\":");
        command(u, p, line, sizeof(line));
        jstr(u, b, line, strlen(line));
        bprintf(b, ",\"fds\":%u,\"kinds\":", p->count);
        jkinds(b, p->kinds);
        bprintf(b, ",\"interval_s\":%.6f,\"opened\":%u,\"closed\":%u,\"d_count\":%d,\"growth\":%u,\"lifetime_low\":%u,"
                   "\"growth_per_min\":%.1f,\"samples\":%u,\"leaking\":%s,"
                   "\"io\":%s,\"rchar\":%llu,\"wchar\":%llu,\"read_per_s\":%.1f,\"write_per_s\":%.1f,\"advance_per_s\":%.1f,"
                   "\"churn_per_s\":%.1f,\"new\":%s,\"stale\":%s,\"truncated\":%s",
                seconds(p->interval_ns), p->opened, p->closed, p->d_count, xrt_fd_growth(p), p->lifetime_low, p_slope(p),
                p->history.samples, (p->flags & XRT_FDP_LEAKING) ? "true" : "false", (p->flags & XRT_FDP_NO_IO) ? "false" : "true",
                (unsigned long long)p->rchar, (unsigned long long)p->wchar, p->read_rate, p->write_rate, p->advance_rate,
                p->churn_rate, (p->flags & XRT_FDP_NEW) ? "true" : "false",
                (p->flags & XRT_FDP_STALE) ? "true" : "false", (p->flags & XRT_FDP_TRUNCATED) ? "true" : "false");
        bstr(b, ",\"growth_kinds\":{");
        int any = 0;
        for (int k = 0; k < XRT_FD_KINDS; k++)
            if (p->grew[k]) {
                bprintf(b, "%s\"%s\":%u", any ? "," : "", xrt_fd_kind_name((enum xrt_fd_kind)k), p->grew[k]);
                any = 1;
            }
        bstr(b, "}");
        if (fd_tables) {
            bstr(b, ",\"fd_table\":[");
            for (uint32_t k = 0; k < p->count; k++) {
                if (k)
                    bstr(b, ",");
                jfd(u, b, &v->fds[p->first + k], p);
            }
            bstr(b, "]");
        }
        bstr(b, "}");
    }
    bprintf(b, "],\"files_total\":%u,\"files\":[", u->nfiles);
    for (uint32_t i = 0; i < u->nfiles && i < limit; i++) {
        const struct xrt_fd_file *f = &u->files[i];
        char link[4096];
        link_text(u, &v->fds[f->sample], link, sizeof(link));
        const struct xrt_fd_process *p = owner(u, f->sample);
        bprintf(b, "%s{\"kind\":\"%s\",\"path\":", i ? "," : "", xrt_fd_kind_name((enum xrt_fd_kind)f->kind));
        jstr(u, b, link, strlen(link));
        bprintf(b, ",\"device\":%llu,\"inode\":%llu,\"size\":%lld,\"disk\":%lld,\"deleted\":%s,\"holders\":%u,\"fds\":%u,"
                   "\"sample_pid\":%d,\"advance_per_s\":%.1f,\"read_per_s\":%.1f,\"write_per_s\":%.1f}",
                (unsigned long long)f->device, (unsigned long long)f->inode, (long long)f->size, (long long)f->disk,
                (f->flags & XRT_FD_DELETED) ? "true" : "false", f->holders, f->fds, p ? p->pid : 0,
                f->rate, f->read_rate, f->write_rate);
    }
    bstr(b, "]}\n");
}

/* ------------------------------------------------------------------- main */
static void usage(FILE *to)
{
    fputs("usage: xodb --lsof-top [options]\n"
          "  --interval SECONDS   sampling period (default 1; 0.25 .. 60)\n"
          "  --pid PID            only these processes (repeatable, or a comma list)\n"
          "  --view NAME          files, processes, leaks or deleted (default processes)\n"
          "  --once               print one text frame after --samples scans and exit\n"
          "  --json               print a JSON snapshot after --samples scans and exit\n"
          "  --samples N          scans before --once/--json output (default 2; 6 or more to judge leaks)\n"
          "  --fds                include each process's fd table in --json\n"
          "  --size COLSxLINES    frame size for --once (default: terminal or 120x40)\n"
          "  --redact             hide user names, host names, addresses, private paths and arguments\n"
          "  --no-color, --ascii  plain attributes / ASCII-only glyphs (NO_COLOR is honoured)\n"
          "  --max-processes N --max-fds N --budget-ms N   scan bounds (the time budget defaults to half\n"
          "                       the period interactively and to none for snapshots)\n"
          "Keys: 1-4/Tab views, arrows, Enter drill in, Esc back, / filter, s sort, r reverse,\n"
          "      space freeze, +/- rate, ? help, q quit.\n",
          to);
}
static int number(const char *s, double lo, double hi, double *out)
{
    char *end;
    errno = 0;
    const double v = strtod(s, &end);
    if (errno || end == s || *end || v < lo || v > hi)
        return -1;
    *out = v;
    return 0;
}

static void teardown(struct ui *u)
{
    xrt_fdscan_destroy(u->scan);
    for (int i = 0; i < u->frame_lines; i++) {
        free(u->frame[i].b.b);
        free(u->shown[i].b);
    }
    free(u->frame);
    free(u->shown);
    free(u->list);
    free(u->out.b);
}

int xodb_lsof_top(int argc, char **argv)
{
    static struct ui ui;
    struct ui *u = &ui;
    memset(u, 0, sizeof(*u));
    u->interval = 1;
    u->view = V_PROCS;
    u->back = V_PROCS;
    int once = 0, as_json = 0, fd_tables = 0, color = -1;
    double samples = 2, value;
    int32_t pids[MAX_PIDS];
    uint32_t npids = 0;
    struct xrt_fdscan_options o;
    memset(&o, 0, sizeof(o));
    int width = 0, height = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *next = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--lsof-top"))
            continue;
        if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            usage(stdout);
            return 0;
        } else if (!strcmp(a, "--once"))
            once = 1;
        else if (!strcmp(a, "--json"))
            as_json = 1;
        else if (!strcmp(a, "--fds"))
            fd_tables = 1;
        else if (!strcmp(a, "--redact"))
            u->redact = 1;
        else if (!strcmp(a, "--no-color"))
            color = 0;
        else if (!strcmp(a, "--ascii"))
            u->ascii = 1;
        else if (!next && (!strcmp(a, "--interval") || !strcmp(a, "--samples") || !strcmp(a, "--max-processes") || !strcmp(a, "--max-fds") ||
                           !strcmp(a, "--budget-ms") || !strcmp(a, "--pid") || !strcmp(a, "--view") || !strcmp(a, "--size"))) {
            fprintf(stderr, "lsof-top: %s needs a value\n", a);
            usage(stderr);
            return 2;
        } else if (!strcmp(a, "--interval")) {
            if (number(next, 0.25, 60, &u->interval))
                goto bad;
            i++;
        } else if (!strcmp(a, "--samples")) {
            if (number(next, 1, 1000, &samples))
                goto bad;
            i++;
        } else if (!strcmp(a, "--max-processes") || !strcmp(a, "--max-fds") || !strcmp(a, "--budget-ms")) {
            if (number(next, a[6] == 'p' ? 16 : a[6] == 'f' ? 64 : 0, a[6] == 'p' ? 1 << 22 : a[6] == 'f' ? 1 << 26 : 60000, &value))
                goto bad;
            if (a[6] == 'p')
                o.max_processes = (uint32_t)value;
            else if (a[6] == 'f')
                o.max_fds = (uint32_t)value;
            else
                o.budget_ms = (uint32_t)value;
            i++;
        } else if (!strcmp(a, "--pid")) {
            for (const char *p = next; *p;) {
                char *end;
                const long pid = strtol(p, &end, 10);
                if (end == p || pid <= 0 || pid > INT32_MAX || npids == MAX_PIDS || (*end && *end != ','))
                    goto bad;
                pids[npids++] = (int32_t)pid;
                p = *end ? end + 1 : end;
            }
            i++;
        } else if (!strcmp(a, "--view")) {
            int found = -1;
            for (int k = 0; k < 4; k++)
                if (!strcmp(next, view_names[k]))
                    found = k;
            if (found < 0)
                goto bad;
            u->view = u->back = found;
            i++;
        } else if (!strcmp(a, "--size")) {
            if (sscanf(next, "%dx%d", &width, &height) != 2 || width < 60 || width > 1000 || height < 10 || height > 500)
                goto bad;
            i++;
        } else {
            fprintf(stderr, "lsof-top: unknown option %s\n", a);
            usage(stderr);
            return 2;
        }
        continue;
    bad:
        fprintf(stderr, "lsof-top: bad value for %s: %s\n", a, next);
        return 2;
    }
    const char *term = getenv("TERM"), *colorterm = getenv("COLORTERM"), *no_color = getenv("NO_COLOR");
    if (!once && !as_json && (!term || !term[0] || !strcmp(term, "dumb"))) {
        /* No cursor addressing to rely on: one plain frame instead. */
        fprintf(stderr, "lsof-top: TERM is %s; printing one frame (as --once)\n", term && term[0] ? term : "unset");
        once = 1;
    }
    const int interactive = !once && !as_json;
    if (interactive && (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO))) {
        fprintf(stderr, "lsof-top: needs a terminal; use --once or --json for snapshots\n");
        return 2;
    }
    setlocale(LC_CTYPE, "");
    u->utf8 = !strcmp(nl_langinfo(CODESET), "UTF-8") && !u->ascii;
    if (color < 0)
        color = (no_color && no_color[0]) || !term || !strcmp(term, "dumb") || (!interactive && !isatty(STDOUT_FILENO)) ? 0 : 1;
    if (color)
        u->color = (colorterm && colorterm[0]) || (term && strstr(term, "256")) ? 256 : 16;
    u->attrs = interactive || color;
    if (gethostname(u->host, sizeof(u->host) - 1))
        u->host[0] = 0;
    snprintf(u->short_host, sizeof(u->short_host), "%.*s", (int)strcspn(u->host, "."), u->host);
    if (!strcmp(u->short_host, u->host))
        u->short_host[0] = 0;
    if (u->redact) {
        user_name(u, getuid()); /* the invoking user is always substituted */
    }
    o.pids = npids ? pids : NULL;
    o.pid_count = npids;
    if (!o.budget_ms && interactive) {
        o.budget_ms = (uint32_t)(u->interval * 500); /* half the period, also after +/- */
        u->budget_default = 1;
    }
    enum xrt_status status = xrt_fdscan_create(&o, &u->scan);
    if (status != XRT_OK) {
        fprintf(stderr, "lsof-top: cannot read /proc (status %d)\n", (int)status);
        return 1;
    }
    u->started = 0;
    if (!interactive) {
        for (int k = 0; k < (int)samples; k++) {
            if (k) {
                const struct timespec t = { .tv_sec = (time_t)u->interval, .tv_nsec = (long)((u->interval - (double)(time_t)u->interval) * 1e9) };
                nanosleep(&t, NULL);
            }
            if (xrt_fdscan_poll(u->scan, &u->snap) != XRT_OK) {
                fprintf(stderr, "lsof-top: scan failed\n");
                teardown(u);
                return 1;
            }
            if (!k)
                u->started = u->snap.taken_ns;
        }
        xrt_fdscan_files(u->scan, &u->files, &u->nfiles);
        if (u->redact)
            for (uint32_t i = 0; i < u->snap.process_count; i++)
                user_name(u, u->snap.processes[i].uid);
        struct buf b = {0};
        if (as_json)
            json(u, &b, fd_tables, 200);
        else {
            u->cols = width ? width : 120;
            u->lines = height ? height : 40;
            if (!width && isatty(STDOUT_FILENO))
                size_from_tty(u);
            u->cpu_percent = u->snap.interval_ns ? 100.0 * (double)u->snap.scan_cpu_ns / (double)u->snap.interval_ns : 0;
            if (resize(u)) {
                teardown(u);
                return 1;
            }
            compose(u);
            for (int i = 0; i < u->lines; i++) {
                struct buf *line = &u->frame[i].b;
                size_t n = line->n;
                while (n && line->b[n - 1] == ' ')
                    n--;
                if (line->b)
                    bput(&b, line->b, n);
                bput(&b, "\n", 1);
            }
        }
        write_all(STDOUT_FILENO, b.b ? b.b : "", b.n);
        free(b.b);
        teardown(u);
        return 0;
    }

    /* Interactive: signals are blocked except while waiting in ppoll. */
    if (tcgetattr(STDIN_FILENO, &saved_tty)) {
        perror("lsof-top: tcgetattr");
        teardown(u);
        return 1;
    }
    sigset_t blocked, waiting;
    sigemptyset(&blocked);
    for (int s = 0, list[] = { SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGTSTP }; s < 5; s++) {
        sigaddset(&blocked, list[s]);
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_signal;
        sigaction(list[s], &sa, NULL);
    }
    sigprocmask(SIG_BLOCK, &blocked, &waiting);
    /* Every other signal whose default ends the process restores the
     * terminal first, then is re-raised. */
    static const int fatal[] = { SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM,
                                 SIGVTALRM, SIGPROF, SIGXCPU, SIGXFSZ, SIGSYS, SIGTRAP, SIGPIPE };
    for (size_t i = 0; i < sizeof(fatal) / sizeof(fatal[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_crash;
        sa.sa_flags = SA_RESETHAND | SA_NODEFER; /* the re-raise is delivered at once */
        sigaction(fatal[i], &sa, NULL);
    }
    atexit(restore_tty);
    u->cols = 80;
    u->lines = 24;
    size_from_tty(u);
    if (resize(u) || enter_tty()) {
        restore_tty();
        teardown(u);
        fprintf(stderr, "lsof-top: cannot set up the terminal\n");
        return 1;
    }
    uint64_t next = 0;
    int full = 1;
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    uint64_t last_wall = (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    uint64_t last_cpu = (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
    int dirty = 1;
    while (!u->quit && !got_quit) {
        clock_gettime(CLOCK_MONOTONIC, &t);
        const uint64_t now = (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
        if (!u->frozen && now >= next) {
            if (xrt_fdscan_poll(u->scan, &u->snap) == XRT_OK) {
                if (!u->started)
                    u->started = u->snap.taken_ns;
                xrt_fdscan_files(u->scan, &u->files, &u->nfiles);
                if (u->redact)
                    for (uint32_t i = 0; i < u->snap.process_count; i++)
                        user_name(u, u->snap.processes[i].uid);
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
                const uint64_t cpu = (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
                if (now > last_wall)
                    u->cpu_percent = 100.0 * (double)(cpu - last_cpu) / (double)(now - last_wall);
                last_cpu = cpu;
                last_wall = now;
            }
            const uint64_t period = (uint64_t)(u->interval * 1e9);
            next = next && next + period > now ? next + period : now + period;
            dirty = 1;
        }
        if (got_winch) {
            got_winch = 0;
            size_from_tty(u);
            if (resize(u))
                break;
            full = dirty = 1;
        }
        if (got_stop) {
            got_stop = 0;
            restore_tty();
            signal(SIGTSTP, SIG_DFL);
            sigprocmask(SIG_SETMASK, &waiting, NULL);
            raise(SIGTSTP);
            /* Continued. */
            sigprocmask(SIG_BLOCK, &blocked, NULL);
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_handler = on_signal;
            sigaction(SIGTSTP, &sa, NULL);
            if (enter_tty())
                break;
            size_from_tty(u);
            if (resize(u))
                break;
            full = dirty = 1;
        }
        if (dirty) {
            compose(u);
            present(u, full);
            full = dirty = 0;
        }
        clock_gettime(CLOCK_MONOTONIC, &t);
        const uint64_t after = (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
        const uint64_t wait = u->frozen ? 1000000000u : next > after ? next - after : 0;
        struct timespec timeout = { .tv_sec = (time_t)(wait / 1000000000u), .tv_nsec = (long)(wait % 1000000000u) };
        struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
        const int ready = ppoll(&p, 1, &timeout, &waiting);
        if (ready > 0 && (p.revents & (POLLHUP | POLLERR | POLLNVAL)))
            break; /* the terminal hung up */
        if (ready > 0) {
            for (int k; (k = read_key()) >= 0 || k == -2;) {
                if (k == -2) {
                    u->quit = 1;
                    break;
                }
                if (k)
                    key(u, k);
                struct pollfd more = { .fd = STDIN_FILENO, .events = POLLIN };
                if (pushed < 0 && poll(&more, 1, 0) != 1)
                    break;
            }
            dirty = 1;
        }
    }
    restore_tty();
    teardown(u);
    return 0;
}
