#define _POSIX_C_SOURCE 200809L
#include "source_paths.h"
#include "dwarf_cursor.h"
#include "dwarf_constants.h"
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 16384u
#define PAGES 16u
#define DIRS 4096u
#define FILES 65536u
#define UNITS 8192u
#define FORMATS 8u
#define TRY(e) do { enum xbo_status s_ = (e); if (s_ != XBO_OK) return s_; } while (0)
enum section { LINE, STR, LINE_STR, COUNT };
struct reader {
    struct xbo_object *object;
    struct xbo_budget *budget;
    const struct xbo_section *sections[COUNT];
    struct cached_page {
        unsigned char bytes[PAGE];
        uint64_t base, age;
        size_t size;
        unsigned section;
        int ready;
    } pages[PAGES];
    uint64_t age;
    unsigned hint;
};
struct stream { struct reader *r; unsigned section; uint64_t pos, end; };
struct string { unsigned section; uint64_t offset, end; };
struct format { uint64_t content, form; };
struct row { struct string path; uint64_t directory; int has_path; };
struct context {
    struct reader reader;
    struct xdw_cursor *cursor;
    uint64_t next;
    const char *wanted;
    int matched;
    struct string dirs[DIRS];
};
static enum xbo_status tick(struct reader *r)
{
    if (r->budget->cancelled && r->budget->cancelled(r->budget->context)) return XBO_CANCELLED;
    if (r->budget->deadline_ns && xbo_now_ns() >= r->budget->deadline_ns) return XBO_AGAIN;
    return XBO_OK;
}
static enum xbo_status bytes(struct stream *s, void *out, size_t n)
{
    struct reader *r = s->r;
    const struct xbo_section *sec = r->sections[s->section];
    if (!sec || s->end > sec->size || s->pos > s->end || n > s->end - s->pos) return XBO_MALFORMED;
    unsigned char *dst = out;
    while (n) {
        TRY(tick(r));
        uint64_t base = s->pos - s->pos % PAGE;
        struct cached_page *page = &r->pages[r->hint];
        if (!page->ready || page->section != s->section || page->base != base) {
            unsigned oldest = 0;
            for (unsigned i = 0; i < PAGES; ++i) {
                struct cached_page *p = &r->pages[i];
                if (p->ready && p->section == s->section && p->base == base) {
                    r->hint = i; page = p; goto found;
                }
                if (!p->ready || p->age < r->pages[oldest].age) oldest = i;
            }
            r->hint = oldest; page = &r->pages[oldest]; page->ready = 0;
            size_t size = sec->size - base < PAGE ? (size_t)(sec->size - base) : PAGE, done = 0;
            TRY(xbo_read(r->object, sec->offset + base, page->bytes, size, &done, r->budget));
            page->section = s->section; page->base = base; page->size = size; page->ready = 1;
        }
found:
        page->age = ++r->age;
        size_t at = (size_t)(s->pos - base), part = page->size - at;
        if (part > n) part = n;
        if (dst) { memcpy(dst, page->bytes + at, part); dst += part; }
        s->pos += part; n -= part;
    }
    return XBO_OK;
}
static enum xbo_status number(struct stream *s, unsigned n, uint64_t *v)
{
    unsigned char b[8]; if (n > sizeof b) return XBO_MALFORMED;
    TRY(bytes(s, b, n)); *v = 0;
    for (unsigned i = 0; i < n; ++i) *v = *v << 8 | b[xbo_little_endian(s->r->object) ? n-i-1 : i];
    return XBO_OK;
}
static enum xbo_status leb(struct stream *s, uint64_t *v)
{
    *v = 0;
    for (unsigned i = 0; i < 10; ++i) {
        uint64_t b; TRY(number(s, 1, &b));
        if (i == 9 && (b & 0xfe)) return XBO_MALFORMED;
        *v |= (b & 127) << (7*i);
        if (!(b & 128)) return XBO_OK;
    }
    return XBO_MALFORMED;
}
static enum xbo_status string(struct stream *s, char *out)
{
    for (unsigned i = 0; i < XDW_SOURCE_PATH_MAX; ++i) {
        uint64_t b; TRY(number(s, 1, &b));
        if (out) out[i] = (char)b;
        if (!b) return XBO_OK;
    }
    return XBO_LIMIT;
}
static enum xbo_status get_string(struct reader *r, struct string ref, char *out)
{
    struct stream s = {r, ref.section, ref.offset, ref.end};
    return string(&s, out);
}
static enum xbo_status formats(struct stream *s, struct format *f, unsigned *count)
{
    uint64_t n; TRY(number(s, 1, &n));
    if (!n || n > FORMATS) return XBO_LIMIT;
    *count = (unsigned)n;
    for (unsigned i = 0; i < *count; ++i) {
        TRY(leb(s, &f[i].content)); TRY(leb(s, &f[i].form));
        for (unsigned j = 0; j < i; ++j) if (f[i].content == f[j].content) return XBO_MALFORMED;
    }
    return XBO_OK;
}
static enum xbo_status row(struct stream *s, const struct format *f, unsigned n, unsigned width, struct row *r)
{
    *r = (struct row){0};
    for (unsigned i = 0; i < n; ++i) {
        uint64_t value = 0; int is_string = 0, is_number = 0;
        struct string ref = {LINE, s->pos, s->end};
        switch (f[i].form) {
        case DW_FORM_string: TRY(string(s, NULL)); is_string = 1; break;
        case DW_FORM_strp: case DW_FORM_line_strp:
            TRY(number(s, width, &ref.offset)); ref.section = f[i].form == DW_FORM_strp ? STR : LINE_STR;
            if (!s->r->sections[ref.section]) return XBO_MALFORMED;
            ref.end = s->r->sections[ref.section]->size;
            TRY(get_string(s->r, ref, NULL)); is_string = 1; break;
        case DW_FORM_data1: TRY(number(s, 1, &value)); is_number = 1; break;
        case DW_FORM_data2: TRY(number(s, 2, &value)); is_number = 1; break;
        case DW_FORM_data4: TRY(number(s, 4, &value)); is_number = 1; break;
        case DW_FORM_data8: TRY(number(s, 8, &value)); is_number = 1; break;
        case DW_FORM_udata: TRY(leb(s, &value)); is_number = 1; break;
        case DW_FORM_data16: TRY(bytes(s, NULL, 16)); break;
        default: return XBO_LIMIT;
        }
        if (f[i].content == DW_LNCT_path) {
            if (!is_string) return XBO_MALFORMED;
            r->path = ref; r->has_path = 1;
        } else if (f[i].content == DW_LNCT_directory_index) {
            if (!is_number) return XBO_MALFORMED;
            r->directory = value;
        }
    }
    return r->has_path ? XBO_OK : XBO_MALFORMED;
}
enum xbo_status xdw_source_normalize(const char *path, char out[XDW_SOURCE_PATH_MAX])
{
    if (!path || !out || path[0] != '/') return XBO_MALFORMED;
    size_t size = strnlen(path, XDW_SOURCE_PATH_MAX);
    if (size == XDW_SOURCE_PATH_MAX) return XBO_LIMIT;
    char raw[XDW_SOURCE_PATH_MAX];
    memcpy(raw, path, size+1);
    size_t used = 0;
    const char *p = raw;
    while (*p) {
        while (*p == '/') ++p;
        const char *start = p; while (*p && *p != '/') ++p;
        size_t n = (size_t)(p-start);
        if (!n || (n == 1 && *start == '.')) continue;
        if (n == 2 && start[0] == '.' && start[1] == '.') {
            if (!used) { out[0] = 0; return XBO_MALFORMED; }
            while (used && out[used-1] != '/') --used;
            if (used) --used;
            continue;
        }
        out[used++] = '/'; memcpy(out+used, start, n); used += n;
    }
    if (!used) out[used++] = '/';
    out[used] = 0; return XBO_OK;
}
static enum xbo_status join(const char *dir, const char *file, char *out)
{
    size_t d = file[0] == '/' ? 0 : strlen(dir), f = strlen(file);
    if (d + !!d + f >= XDW_SOURCE_PATH_MAX) return XBO_LIMIT;
    char raw[XDW_SOURCE_PATH_MAX];
    memcpy(raw, dir, d); if (d) raw[d++] = '/'; memcpy(raw+d, file, f+1);
    if (raw[0] != '/') return XBO_NOT_FOUND;
    return xdw_source_normalize(raw, out);
}
static enum xbo_status match(struct context *c, const char *comp_dir, const struct string *dirs,
                             unsigned ndirs, unsigned version, const struct row *r, int *found)
{
    char name[XDW_SOURCE_PATH_MAX], directory[XDW_SOURCE_PATH_MAX], absolute[XDW_SOURCE_PATH_MAX];
    TRY(get_string(&c->reader, r->path, name));
    /* Directory spellings do not authorize a regular source file. They are
     * unusable rows, not a structural failure of the whole line table. */
    size_t length = strlen(name);
    int directory_name = !length || name[length-1] == '/' || !strcmp(name, ".") ||
                         (length >= 2 && !strcmp(name + length - 2, "/."));
    directory[0] = 0;
    if (version < 5 && !r->directory) {
        memcpy(directory, comp_dir, strlen(comp_dir)+1);
    } else {
        uint64_t index = r->directory - (version < 5);
        if (index >= ndirs) return XBO_MALFORMED;
        TRY(get_string(&c->reader, dirs[index], directory));
        enum xbo_status s = join(comp_dir, directory, absolute);
        /* A lexically escaping directory makes this row unusable. Parsing,
         * read and budget errors still propagate instead of being hidden. */
        if (s == XBO_MALFORMED) return XBO_OK;
        if (s != XBO_OK && s != XBO_NOT_FOUND) return s;
        if (s == XBO_OK) memcpy(directory, absolute, strlen(absolute)+1);
    }
    if (directory_name) return XBO_OK;
    enum xbo_status s = join(directory, name, absolute);
    if (s == XBO_NOT_FOUND || s == XBO_MALFORMED) return XBO_OK;
    if (s != XBO_OK) return s;
    if (!strcmp(absolute, c->wanted)) *found = 1;
    return XBO_OK;
}
static enum xbo_status table(struct context *c, uint64_t offset, const char *comp_dir)
{
    struct reader *r = &c->reader;
    struct stream s = {r, LINE, offset, r->sections[LINE]->size};
    uint64_t length, version, value, header; unsigned width = 4;
    TRY(number(&s, 4, &length));
    if (length == UINT32_MAX) { width = 8; TRY(number(&s, 8, &length)); }
    else if (length >= 0xfffffff0) return XBO_MALFORMED;
    if (!length || length > s.end - s.pos) return XBO_MALFORMED;
    s.end = s.pos + length; TRY(number(&s, 2, &version));
    if (version < 2 || version > 5) return XBO_LIMIT;
    if (version == 5) {
        TRY(number(&s, 1, &value)); if (value != 4 && value != 8) return XBO_LIMIT;
        TRY(number(&s, 1, &value)); if (value) return XBO_LIMIT;
    }
    TRY(number(&s, width, &header));
    if (header > s.end - s.pos) return XBO_MALFORMED;
    s.end = s.pos + header;
    TRY(number(&s, 1, &value)); if (!value) return XBO_MALFORMED;
    if (version >= 4) { TRY(number(&s, 1, &value)); if (!value) return XBO_MALFORMED; }
    TRY(bytes(&s, NULL, 2)); /* default_is_stmt, line_base */
    TRY(number(&s, 1, &value)); if (!value) return XBO_MALFORMED;
    TRY(number(&s, 1, &value)); if (!value) return XBO_MALFORMED;
    TRY(bytes(&s, NULL, (size_t)value - 1));
    struct string *dirs = c->dirs; unsigned ndirs = 0;
    struct format df[FORMATS], ff[FORMATS]; unsigned dn = 0, fn = 0;
    if (version == 5) {
        TRY(formats(&s, df, &dn)); TRY(leb(&s, &value));
        if (value > DIRS) return XBO_LIMIT;
        ndirs = (unsigned)value;
        for (unsigned i = 0; i < ndirs; ++i) {
            struct row row_; TRY(row(&s, df, dn, width, &row_)); dirs[i] = row_.path;
        }
        TRY(formats(&s, ff, &fn)); TRY(leb(&s, &value));
        if (value > FILES) return XBO_LIMIT;
    } else {
        for (;;) {
            uint64_t begin = s.pos; TRY(number(&s, 1, &value)); if (!value) break; s.pos = begin;
            if (ndirs == DIRS) return XBO_LIMIT;
            dirs[ndirs++] = (struct string){LINE, s.pos, s.end}; TRY(string(&s, NULL));
        }
        value = FILES;
    }
    int found = 0, terminated = version == 5;
    uint64_t count = value;
    for (uint64_t i = 0; i < count; ++i) {
        struct row row_ = {0};
        if (version == 5) TRY(row(&s, ff, fn, width, &row_));
        else {
            uint64_t begin = s.pos; TRY(number(&s, 1, &value));
            /* DWARF 2-4 ends the filename table at the first zero byte.
             * GCC can emit an empty name for a trailing-slash #line path;
             * it is indistinguishable from this terminator. Keep preceding
             * valid rows, but never authorize bytes after the terminator. */
            if (!value) { terminated = 1; break; } s.pos = begin;
            row_.path = (struct string){LINE, s.pos, s.end}; TRY(string(&s, NULL));
            TRY(leb(&s, &row_.directory)); TRY(leb(&s, &value)); TRY(leb(&s, &value));
        }
        TRY(match(c, comp_dir, dirs, ndirs, (unsigned)version, &row_, &found));
    }
    if (!terminated) return XBO_LIMIT;
    if (version == 5 && s.pos != s.end) return XBO_MALFORMED;
    if (found) c->matched = 1;
    return XBO_OK;
}
static enum xbo_status root(void *raw, const struct xdw_die *die, enum xdw_action *action)
{
    struct context *c = raw; *action = XDW_STOP; c->next = die->unit_end;
    if (die->depth) return XBO_MALFORMED;
    const struct xdw_attribute *stmt = xdw_attribute(die, DW_AT_stmt_list);
    if (!stmt) return XBO_OK;
    if (stmt->form != DW_FORM_sec_offset && !(die->version <= 3 &&
        (stmt->form == DW_FORM_data4 || stmt->form == DW_FORM_data8))) return XBO_MALFORMED;
    char dir[XDW_SOURCE_PATH_MAX] = {0};
    enum xbo_status status = xdw_string_attribute(c->cursor, die, DW_AT_comp_dir, dir, sizeof dir, c->reader.budget);
    if (status != XBO_OK && status != XBO_NOT_FOUND) return status;
    return table(c, stmt->value, dir);
}
enum xbo_status xdw_source_path(struct xbo_object *object, const char *path, struct xbo_budget *budget)
{
    if (!object || !path || path[0] != '/' || !budget) return XBO_MALFORMED;
    if (strnlen(path, XDW_SOURCE_PATH_MAX) == XDW_SOURCE_PATH_MAX) return XBO_LIMIT;
    char wanted[XDW_SOURCE_PATH_MAX]; TRY(join("", path, wanted));
    struct context *c = calloc(1, sizeof *c); if (!c) return XBO_NOMEM;
    c->reader.object = object; c->reader.budget = budget; c->wanted = wanted;
    enum xbo_status status = XBO_OK;
    const char *names[] = {".debug_line", ".debug_str", ".debug_line_str"};
    for (unsigned i = 0; i < COUNT; ++i) {
        uint32_t index; status = xbo_find_section(object, names[i], &index);
        if (status == XBO_OK) {
            c->reader.sections[i] = xbo_section(object, index);
            if (c->reader.sections[i]->flags & SHF_COMPRESSED) { status = XBO_LIMIT; goto done; }
        } else if (status != XBO_NOT_FOUND || i == LINE) goto done;
    }
    status = xdw_create(object, &c->cursor); if (status != XBO_OK) goto done;
    struct xdw_progress progress; xdw_progress(c->cursor, &progress);
    for (unsigned n = 0; c->next < progress.info_size; ++n) {
        if (n == UNITS) { status = XBO_LIMIT; goto done; }
        uint64_t before = c->next;
        status = xdw_select_unit(c->cursor, c->next); if (status != XBO_OK) goto done;
        status = xdw_walk(c->cursor, budget, 1, root, c); if (status != XBO_OK) goto done;
        if (c->next <= before) { status = XBO_MALFORMED; goto done; }
        if (c->matched) { status = xbo_validate(object, budget); goto done; }
    }
    status = XBO_NOT_FOUND;
done:
    xdw_destroy(c->cursor); free(c); return status;
}
