#include "gdb_lldb.h"
#include <string.h>

static int hex(unsigned c)
{
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}
static bool number(const char *text, size_t n, unsigned base, uint64_t *out)
{
    if (!n || n > 20) return false;
    uint64_t value = 0;
    for (size_t i = 0; i < n; ++i) {
        int digit = hex((uint8_t)text[i]);
        if (digit < 0 || (unsigned)digit >= base || value > (UINT64_MAX - (unsigned)digit) / base)
            return false;
        value = value * base + (unsigned)digit;
    }
    *out = value;
    return true;
}
struct pairs { const char *at, *end; bool cut; };
struct pair { const char *key, *value; size_t key_size, value_size; };
/* 1: a pair; 0: end of input; -1: malformed. */
static int next(struct pairs *p, struct pair *out)
{
    if (p->at == p->end) return 0;
    const char *stop = memchr(p->at, ';', (size_t)(p->end - p->at));
    if (!stop) {
        if (p->cut) { p->at = p->end; return 0; }
        stop = p->end;
    }
    const char *colon = memchr(p->at, ':', (size_t)(stop - p->at));
    if (!colon || colon == p->at) return -1;
    *out = (struct pair){p->at, colon + 1, (size_t)(colon - p->at), (size_t)(stop - colon - 1)};
    p->at = stop == p->end ? stop : stop + 1;
    return 1;
}
static bool is(const struct pair *p, const char *key)
{
    return strlen(key) == p->key_size && !memcmp(p->key, key, p->key_size);
}
static bool value_is(const struct pair *p, const char *value)
{
    return strlen(value) == p->value_size && !memcmp(p->value, value, p->value_size);
}
enum xrt_status xrt_gdb_host_parse(const char *text, size_t size, struct xrt_gdb_host *out)
{
    if (!text || !out || !size || memchr(text, 0, size)) return XRT_PROTOCOL_ERROR;
    struct pairs list = {text, text + size, false};
    struct pair p;
    bool apple = false, linux_ = false, has_cpu = false, has_bits = false, has_vendor = false, has_os = false;
    uint64_t value;
    int state;
    while ((state = next(&list, &p)) > 0) {
        if (is(&p, "cputype")) {
            if (has_cpu || !number(p.value, p.value_size, 10, &value) || value > UINT32_MAX)
                return XRT_PROTOCOL_ERROR;
            has_cpu = true; out->cputype = (uint32_t)value;
        } else if (is(&p, "addressing_bits")) {
            if (has_bits || !number(p.value, p.value_size, 10, &value) || !value || value > 64)
                return XRT_PROTOCOL_ERROR;
            has_bits = true; out->address_bits = (uint32_t)value;
        } else if (is(&p, "vendor")) {
            if (has_vendor) return XRT_PROTOCOL_ERROR;
            has_vendor = true; apple = value_is(&p, "apple");
        } else if (is(&p, "ostype")) {
            if (has_os) return XRT_PROTOCOL_ERROR;
            has_os = true; linux_ = value_is(&p, "linux");
        }
    }
    if (state < 0) return XRT_PROTOCOL_ERROR;
    out->os = apple ? XRT_GDB_OS_DARWIN : linux_ ? XRT_GDB_OS_LINUX : XRT_GDB_OS_UNKNOWN;
    return XRT_OK;
}
enum xrt_status xrt_gdb_process_parse(const char *text, size_t size, struct xrt_gdb_host *out)
{
    if (!text || !out || !size || memchr(text, 0, size)) return XRT_PROTOCOL_ERROR;
    struct pairs list = {text, text + size, false};
    struct pair p;
    bool has_pid = false;
    int state;
    while ((state = next(&list, &p)) > 0)
        if (is(&p, "pid")) {
            uint64_t value;
            if (has_pid || !number(p.value, p.value_size, 16, &value) || !value || value > INT32_MAX)
                return XRT_PROTOCOL_ERROR;
            has_pid = true; out->pid = value;
        }
    return state < 0 ? XRT_PROTOCOL_ERROR : XRT_OK;
}
static void label(char *out, size_t capacity, const char *text, size_t size, bool hexadecimal)
{
    size_t n = 0;
    for (size_t i = 0; i < size && n + 1 < capacity; i += hexadecimal ? 2 : 1) {
        unsigned c = (uint8_t)text[i];
        if (hexadecimal) c = (unsigned)(hex(c) * 16 + hex((uint8_t)text[i + 1]));
        out[n++] = c >= 32 && c < 127 ? (char)c : '?';
    }
    out[n] = 0;
}
enum xrt_status xrt_gdb_region_parse(const char *text, size_t size, bool cut, uint64_t asked,
                                     struct xrt_gdb_region *out)
{
    if (!text || !out || !size || memchr(text, 0, size)) return XRT_PROTOCOL_ERROR;
    /* An escape or repeat marker would make a raw prefix differ from its payload. */
    if (cut && (memchr(text, '}', size) || memchr(text, '*', size))) return XRT_PROTOCOL_ERROR;
    *out = (struct xrt_gdb_region){0};
    struct pairs list = {text, text + size, cut};
    struct pair p;
    bool has_start = false, has_size = false, has_name = false, has_type = false;
    int state;
    while ((state = next(&list, &p)) > 0) {
        if (is(&p, "start")) {
            if (has_start || !number(p.value, p.value_size, 16, &out->start)) return XRT_PROTOCOL_ERROR;
            has_start = true;
        } else if (is(&p, "size")) {
            if (has_size || !number(p.value, p.value_size, 16, &out->size) || !out->size)
                return XRT_PROTOCOL_ERROR;
            has_size = true;
        } else if (is(&p, "permissions")) {
            if (out->mapped || p.value_size > 3) return XRT_PROTOCOL_ERROR;
            for (size_t i = 0; i < p.value_size; ++i) {
                bool *flag = p.value[i] == 'r' ? &out->read : p.value[i] == 'w' ? &out->write :
                    p.value[i] == 'x' ? &out->execute : NULL;
                if (!flag || *flag) return XRT_PROTOCOL_ERROR;
                *flag = true;
            }
            out->mapped = true;
        } else if (is(&p, "name")) {
            if (has_name || p.value_size % 2) return XRT_PROTOCOL_ERROR;
            for (size_t i = 0; i < p.value_size; ++i)
                if (hex((uint8_t)p.value[i]) < 0) return XRT_PROTOCOL_ERROR;
            has_name = true; label(out->name, sizeof(out->name), p.value, p.value_size, true);
        } else if (is(&p, "type")) {
            if (has_type) return XRT_PROTOCOL_ERROR;
            has_type = true; label(out->type, sizeof(out->type), p.value, p.value_size, false);
        }
    }
    if (state < 0 || !has_start) return XRT_PROTOCOL_ERROR;
    if (!has_size) {
        /* The stub's end marker. A cut reply always carries its size first. */
        if (cut) return XRT_PROTOCOL_ERROR;
        *out = (struct xrt_gdb_region){.start = out->start};
        return XRT_OK;
    }
    if (out->start > asked || asked - out->start >= out->size || out->size - 1 > UINT64_MAX - out->start)
        return XRT_PROTOCOL_ERROR;
    return XRT_OK;
}

struct json { const char *at, *end; };
static void blank(struct json *j)
{
    while (j->at < j->end && (*j->at == ' ' || *j->at == '\t' || *j->at == '\n' || *j->at == '\r')) ++j->at;
}
static bool take(struct json *j, char c)
{
    blank(j);
    if (j->at == j->end || *j->at != c) return false;
    ++j->at;
    return true;
}
/* out may be NULL to skip. Longer text is cut; non-ASCII and \u become '?'. */
static bool text(struct json *j, char *out, size_t capacity, bool *truncated)
{
    if (!take(j, '"')) return false;
    size_t n = 0;
    if (truncated) *truncated = false;
    while (j->at < j->end) {
        unsigned c = (uint8_t)*j->at++;
        if (c == '"') {
            if (out) out[n] = 0;
            return true;
        }
        if (c < 32) return false;
        if (c == '\\') {
            if (j->at == j->end) return false;
            c = (uint8_t)*j->at++;
            if (c == 'u') {
                if (j->end - j->at < 4) return false;
                for (unsigned i = 0; i < 4; ++i) if (hex((uint8_t)j->at[i]) < 0) return false;
                j->at += 4; c = '?';
            } else if (c == 'b' || c == 'f' || c == 'n' || c == 'r' || c == 't') c = '?';
            else if (c != '"' && c != '\\' && c != '/') return false;
        }
        if (!out) continue;
        if (n + 1 < capacity) out[n++] = c < 127 ? (char)c : '?';
        else if (truncated) *truncated = true;
    }
    return false;
}
/* JSON number grammar. integer is set only for an unsigned value that fits. */
static bool numeral(struct json *j, uint64_t *value, bool *integer)
{
    blank(j);
    const char *start = j->at;
    bool plain = true;
    if (j->at < j->end && *j->at == '-') { plain = false; ++j->at; }
    const char *digits = j->at;
    while (j->at < j->end && *j->at >= '0' && *j->at <= '9') ++j->at;
    size_t count = (size_t)(j->at - digits);
    if (!count || (count > 1 && *digits == '0')) return false;
    if (j->at < j->end && *j->at == '.') {
        plain = false; ++j->at;
        const char *fraction = j->at;
        while (j->at < j->end && *j->at >= '0' && *j->at <= '9') ++j->at;
        if (j->at == fraction) return false;
    }
    if (j->at < j->end && (*j->at == 'e' || *j->at == 'E')) {
        plain = false; ++j->at;
        if (j->at < j->end && (*j->at == '+' || *j->at == '-')) ++j->at;
        const char *exponent = j->at;
        while (j->at < j->end && *j->at >= '0' && *j->at <= '9') ++j->at;
        if (j->at == exponent) return false;
    }
    *integer = plain && number(start, count, 10, value);
    return true;
}
static bool skip(struct json *j, unsigned depth)
{
    blank(j);
    if (j->at == j->end) return false;
    char c = *j->at;
    if (c == '"') return text(j, NULL, 0, NULL);
    if (c == '{' || c == '[') {
        if (depth == XRT_GDB_JSON_DEPTH) return false;
        char close = c == '{' ? '}' : ']';
        ++j->at;
        if (take(j, close)) return true;
        do {
            if (c == '{' && (!text(j, NULL, 0, NULL) || !take(j, ':'))) return false;
            if (!skip(j, depth + 1)) return false;
        } while (take(j, ','));
        return take(j, close);
    }
    for (const char *word = "true\0false\0null\0"; *word; word += strlen(word) + 1) {
        size_t n = strlen(word);
        if ((size_t)(j->end - j->at) >= n && !memcmp(j->at, word, n)) { j->at += n; return true; }
    }
    uint64_t value; bool integer;
    return numeral(j, &value, &integer);
}
static bool unsigned_number(struct json *j, uint64_t *out)
{
    bool integer;
    return numeral(j, out, &integer) && integer;
}
static bool image_uuid(struct json *j, unsigned char out[16])
{
    char value[37]; bool cut;
    if (!text(j, value, sizeof value, &cut) || cut || strlen(value) != 36) return false;
    size_t at = 0;
    for (unsigned i = 0; i < 16; ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) if (value[at++] != '-') return false;
        int a = hex((unsigned char)value[at++]), b = hex((unsigned char)value[at++]);
        if (a < 0 || b < 0) return false;
        out[i] = (unsigned char)(a * 16 + b);
    }
    return true;
}
static bool image_header(struct json *j, struct xrt_gdb_image *out)
{
    unsigned seen = 0; char key[32];
    if (!take(j, '{') || take(j, '}')) return false;
    do {
        if (!text(j, key, sizeof key, NULL) || !take(j, ':')) return false;
        unsigned bit = !strcmp(key, "cputype") ? 1 : !strcmp(key, "cpusubtype") ? 2 : !strcmp(key, "filetype") ? 4 : 0;
        if (!bit) { if (!skip(j, 4)) return false; continue; }
        uint64_t n;
        if ((seen & bit) || !unsigned_number(j, &n) || n > UINT32_MAX) return false;
        seen |= bit;
        if (bit == 1) out->cputype = (uint32_t)n;
        else if (bit == 2) out->cpusubtype = (uint32_t)n;
        else out->filetype = (uint32_t)n;
    } while (take(j, ','));
    return take(j, '}') && seen == 7;
}
static bool image_segment(struct json *j, struct xrt_gdb_image_segment *out)
{
    unsigned seen = 0; char key[32];
    *out = (struct xrt_gdb_image_segment){0};
    if (!take(j, '{') || take(j, '}')) return false;
    do {
        if (!text(j, key, sizeof key, NULL) || !take(j, ':')) return false;
        unsigned bit = !strcmp(key, "name") ? 1 : !strcmp(key, "vmaddr") ? 2 : !strcmp(key, "vmsize") ? 4 : !strcmp(key, "maxprot") ? 8 : 0;
        if (!bit) { if (!skip(j, 5)) return false; continue; }
        if (seen & bit) return false;
        seen |= bit;
        if (bit == 1) {
            bool cut;
            if (!text(j, out->name, sizeof out->name, &cut) || cut) return false;
        } else {
            uint64_t n;
            if (!unsigned_number(j, &n)) return false;
            if (bit == 2) out->vmaddr = n;
            else if (bit == 4) out->vmsize = n;
            else { if (n > 7) return false; out->maxprot = (uint32_t)n; }
        }
    } while (take(j, ','));
    return take(j, '}') && seen == 15 && out->vmsize <= UINT64_MAX-out->vmaddr;
}
static bool image_segments(struct json *j, struct xrt_gdb_image *out)
{
    if (!take(j, '[')) return false;
    if (take(j, ']')) return true;
    do {
        if (out->segment_count == XRT_GDB_IMAGE_SEGMENTS_MAX || !image_segment(j, &out->segments[out->segment_count])) return false;
        ++out->segment_count;
    } while (take(j, ','));
    return take(j, ']');
}
static bool image(struct json *j, struct xrt_gdb_image *out)
{
    bool has_address = false, has_path = false, has_segments = false;
    char key[32];
    *out = (struct xrt_gdb_image){0};
    if (!take(j, '{')) return false;
    if (take(j, '}')) return false;
    do {
        if (!text(j, key, sizeof(key), NULL) || !take(j, ':')) return false;
        if (!strcmp(key, "load_address")) {
            bool integer;
            if (has_address || !numeral(j, &out->load_address, &integer) || !integer) return false;
            has_address = true;
        } else if (!strcmp(key, "pathname")) {
            if (has_path || !text(j, out->path, sizeof(out->path), &out->path_truncated)) return false;
            has_path = true;
        } else if (!strcmp(key, "uuid")) {
            if (out->has_uuid || !image_uuid(j, out->uuid)) return false;
            out->has_uuid = true;
        } else if (!strcmp(key, "mach_header")) {
            if (out->has_header || !image_header(j, out)) return false;
            out->has_header = true;
        } else if (!strcmp(key, "segments")) {
            if (has_segments || !image_segments(j, out)) return false;
            has_segments = true;
        } else if (!skip(j, 3)) return false;
    } while (take(j, ','));
    return take(j, '}') && has_address;
}
enum xrt_status xrt_gdb_images_parse(const char *input, size_t size, struct xrt_gdb_image *out,
                                     size_t capacity, size_t *total)
{
    if (!input || !total || (capacity && !out) || !size || memchr(input, 0, size))
        return XRT_PROTOCOL_ERROR;
    *total = 0;
    struct json j = {input, input + size};
    bool found = false;
    char key[32];
    if (!take(&j, '{')) return XRT_PROTOCOL_ERROR;
    if (!take(&j, '}')) {
        do {
            if (!text(&j, key, sizeof(key), NULL) || !take(&j, ':')) return XRT_PROTOCOL_ERROR;
            if (strcmp(key, "images")) {
                if (!skip(&j, 1)) return XRT_PROTOCOL_ERROR;
                continue;
            }
            if (found || !take(&j, '[')) return XRT_PROTOCOL_ERROR;
            found = true;
            if (take(&j, ']')) continue;
            do {
                struct xrt_gdb_image row;
                if (!image(&j, &row)) return XRT_PROTOCOL_ERROR;
                if (*total == XRT_GDB_IMAGES_MAX) return XRT_BUFFER_TOO_SMALL;
                if (*total < capacity) out[*total] = row;
                ++*total;
            } while (take(&j, ','));
            if (!take(&j, ']')) return XRT_PROTOCOL_ERROR;
        } while (take(&j, ','));
        if (!take(&j, '}')) return XRT_PROTOCOL_ERROR;
    }
    blank(&j);
    return found && j.at == j.end ? XRT_OK : XRT_PROTOCOL_ERROR;
}
