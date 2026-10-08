#include "gdb_description.h"
#include "gdb_packet.h"
#include <elf.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct attribute { char name[64], value[128]; };
struct token {
    char name[64];
    struct attribute attributes[16];
    unsigned count;
    int close, empty;
};
struct parser {
    struct xrt_gdb_description *description;
    xrt_gdb_annex load;
    void *context;
    char annexes[32][128];
    unsigned annex_count;
};
static enum xrt_status error(struct parser *p, enum xrt_status status, const char *why)
{
    snprintf(p->description->reason, sizeof(p->description->reason), "%s", why);
    return status;
}
static int space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
static int namechar(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == ':' || c == '-' || c == '.';
}
static int word(const char **at, const char *end, char *out, size_t capacity)
{
    const char *start = *at;
    while (*at < end && namechar(**at)) ++*at;
    size_t n = (size_t)(*at - start);
    if (!n || n >= capacity) return 0;
    memcpy(out, start, n); out[n] = 0;
    return 1;
}
static const char *attribute(const struct token *t, const char *name)
{
    for (unsigned i = 0; i < t->count; ++i)
        if (!strcmp(t->attributes[i].name, name)) return t->attributes[i].value;
    return NULL;
}
static int number(const char *text, uint32_t *out)
{
    if (!text || !*text) return 0;
    uint32_t value = 0;
    for (; *text; ++text) {
        if (*text < '0' || *text > '9' || value > (UINT32_MAX - (unsigned)(*text - '0')) / 10)
            return 0;
        value = value * 10 + (unsigned)(*text - '0');
    }
    *out = value;
    return 1;
}
static int token(const char **at, const char *end, struct token *t)
{
    *t = (struct token){0};
    const char *s = *at;
    if (s == end || *s++ != '<') return 0;
    if (s < end && *s == '/') { t->close = 1; ++s; }
    if (!word(&s, end, t->name, sizeof(t->name))) return 0;
    for (;;) {
        int separated = s < end && space(*s);
        while (s < end && space(*s)) ++s;
        if (s == end) return 0;
        if (*s == '>') { *at = s + 1; return 1; }
        if (*s == '/' && !t->close && s + 1 < end && s[1] == '>') {
            t->empty = 1; *at = s + 2; return 1;
        }
        if (!separated || t->close || t->count == 16) return 0;
        struct attribute *a = &t->attributes[t->count];
        if (!word(&s, end, a->name, sizeof(a->name)) || attribute(t, a->name)) return 0;
        while (s < end && space(*s)) ++s;
        if (s == end || *s++ != '=') return 0;
        while (s < end && space(*s)) ++s;
        if (s == end || (*s != '"' && *s != '\'')) return 0;
        char quote = *s++;
        const char *start = s;
        while (s < end && *s != quote) {
            if ((unsigned char)*s < 32 || (unsigned char)*s > 126 || *s == '&' || *s == '<')
                return 0;
            ++s;
        }
        size_t n = (size_t)(s - start);
        if (s == end || n >= sizeof(a->value)) return 0;
        memcpy(a->value, start, n); a->value[n] = 0; ++s; ++t->count;
    }
}
static enum xrt_status document(struct parser *, const char *, size_t, unsigned);
static enum xrt_status include(struct parser *p, const char *name, unsigned depth)
{
    if (!name || !*name || strlen(name) >= 128 || !p->load || p->annex_count == 32 || depth >= 8)
        return error(p, XRT_PROTOCOL_ERROR, "GDB XML include unavailable or limit exceeded");
    for (const char *s = name; *s; ++s)
        if (!namechar(*s) || *s == ':') return error(p, XRT_PROTOCOL_ERROR, "Invalid GDB XML annex name");
    if (strstr(name, "..")) return error(p, XRT_PROTOCOL_ERROR, "Invalid GDB XML annex name");
    for (unsigned i = 0; i < p->annex_count; ++i)
        if (!strcmp(name, p->annexes[i])) return error(p, XRT_PROTOCOL_ERROR, "Repeated GDB XML include");
    strcpy(p->annexes[p->annex_count++], name);
    char *text = NULL; size_t size = 0;
    enum xrt_status status = p->load(p->context, name, &text, &size);
    if (status == XRT_OK) status = document(p, text, size, depth + 1);
    free(text);
    return status;
}
static enum xrt_status add_register(struct parser *p, const struct token *t)
{
    struct xrt_gdb_description *d = p->description;
    const char *name = attribute(t, "name"), *regnum = attribute(t, "regnum");
    uint32_t bits, n = d->next_number;
    if (!name || !*name || strlen(name) >= sizeof(d->registers[0].name) ||
        !number(attribute(t, "bitsize"), &bits) || !bits || bits % 8 ||
        (regnum && !number(regnum, &n)) || n != d->next_number)
        return error(p, XRT_PROTOCOL_ERROR, "GDB XML register width/number is invalid or has a gap");
    if (d->count == XRT_GDB_REGISTERS_MAX || bits / 8 > XRT_GDB_REGISTER_BYTES_MAX - d->register_bytes)
        return error(p, XRT_BUFFER_TOO_SMALL, "GDB XML register layout exceeds limits");
    for (uint32_t i = 0; i < d->count; ++i)
        if (!strcmp(name, d->registers[i].name))
            return error(p, XRT_PROTOCOL_ERROR, "Duplicate GDB XML register name");
    struct xrt_gdb_register *r = &d->registers[d->count++];
    strcpy(r->name, name); r->number = n; r->offset = d->register_bytes; r->bytes = bits / 8;
    d->register_bytes += r->bytes; d->next_number = n + 1;
    return XRT_OK;
}
static enum xrt_status document(struct parser *p, const char *text, size_t size, unsigned depth)
{
    struct xrt_gdb_description *d = p->description;
    if (!text || !size || size > XRT_GDB_XML_MAX - d->xml_bytes || memchr(text, 0, size) ||
        ++d->documents > 32)
        return error(p, XRT_PROTOCOL_ERROR, "Invalid or oversized GDB XML document");
    d->xml_bytes += (uint32_t)size;
    /* Work on a terminated copy so all delimiter searches remain bounded. */
    char *copy = malloc(size + 1);
    if (!copy) return XRT_OUT_OF_MEMORY;
    memcpy(copy, text, size); copy[size] = 0;
    const char *at = copy, *end = copy + size;
    char stack[32][64]; unsigned level = 0, roots = 0;
    enum xrt_status status = XRT_OK;
    while (at < end) {
        if (space(*at)) { ++at; continue; }
        if (!strncmp(at, "<!--", 4)) {
            const char *close = strstr(at + 4, "-->");
            if (!close) { status = XRT_PROTOCOL_ERROR; break; }
            at = close + 3; continue;
        }
        if (!strncmp(at, "<?xml ", 6)) {
            const char *close = strstr(at + 6, "?>");
            if (!close || level || roots) { status = XRT_PROTOCOL_ERROR; break; }
            at = close + 2; continue;
        }
        if (!strncmp(at, "<!DOCTYPE ", 10)) {
            const char *close = strchr(at + 10, '>');
            if (!close || level || roots || memchr(at, '[', (size_t)(close - at))) {
                status = XRT_PROTOCOL_ERROR; break;
            }
            at = close + 1; continue; /* external DTDs are never fetched */
        }
        struct token t;
        if (!token(&at, end, &t)) { status = XRT_PROTOCOL_ERROR; break; }
        if (t.close) {
            if (!level || strcmp(stack[level - 1], t.name)) { status = XRT_PROTOCOL_ERROR; break; }
            --level; continue;
        }
        if (!level && (++roots != 1 || (strcmp(t.name, "target") && strcmp(t.name, "feature")))) {
            status = XRT_PROTOCOL_ERROR; break;
        }
        if (!strcmp(t.name, "architecture")) {
            if (!level || strcmp(stack[level - 1], "target") || t.empty || d->architecture[0]) {
                status = XRT_PROTOCOL_ERROR; break;
            }
            const char *close = strchr(at, '<');
            if (!close) { status = XRT_PROTOCOL_ERROR; break; }
            while (at < close && space(*at)) ++at;
            const char *trim = close; while (trim > at && space(trim[-1])) --trim;
            size_t n = (size_t)(trim - at);
            if (!n || n >= sizeof(d->architecture)) { status = XRT_PROTOCOL_ERROR; break; }
            for (const char *s = at; s < trim; ++s)
                if (!namechar(*s)) status = XRT_PROTOCOL_ERROR;
            if (status != XRT_OK) break;
            memcpy(d->architecture, at, n); d->architecture[n] = 0; at = close;
        } else if (!strcmp(t.name, "reg")) {
            if (!level || strcmp(stack[level - 1], "feature") || !t.empty) {
                status = XRT_PROTOCOL_ERROR; break;
            }
            status = add_register(p, &t);
        } else if (!strcmp(t.name, "xi:include")) {
            if (!t.empty || !level) { status = XRT_PROTOCOL_ERROR; break; }
            status = include(p, attribute(&t, "href"), depth);
        } else if (!strcmp(t.name, "osabi") || !strcmp(t.name, "compatible")) {
            const char *close = strchr(at, '<');
            if (!close || t.empty) { status = XRT_PROTOCOL_ERROR; break; }
            at = close; /* Informational: no Linux process assumptions. */
        }
        if (status != XRT_OK) break;
        if (!t.empty) {
            if (level == 32) { status = XRT_PROTOCOL_ERROR; break; }
            strcpy(stack[level++], t.name);
        }
    }
    if (status == XRT_OK && (level || roots != 1)) status = XRT_PROTOCOL_ERROR;
    free(copy);
    return status == XRT_PROTOCOL_ERROR ? error(p, status, "Malformed or unsupported GDB XML") : status;
}
const struct xrt_gdb_register *xrt_gdb_description_register(
    const struct xrt_gdb_description *d, const struct xrt_register_desc *desc)
{
    const char *name = desc->name;
    if (!strcmp(name, "pstate")) name = "cpsr";
    for (uint32_t i = 0; i < d->count; ++i) {
        const struct xrt_gdb_register *r = &d->registers[i];
        if (!strcmp(r->name, name) &&
            (r->bytes == desc->width || (r->bytes == 4 &&
             (!strcmp(desc->name, "eflags") || !strcmp(desc->name, "pstate")))))
            return r;
    }
    return NULL;
}
enum xrt_status xrt_gdb_description_parse(struct xrt_gdb_description *d,
                                          const char *text, size_t size,
                                          xrt_gdb_annex loader, void *context)
{
    if (!d) return XRT_INVALID_ARGUMENT;
    *d = (struct xrt_gdb_description){0};
    struct parser p = {.description = d, .load = loader, .context = context};
    enum xrt_status status = document(&p, text, size, 0);
    if (status != XRT_OK) return status;
    if (!strcmp(d->architecture, "i386:x86-64")) d->arch = xrt_arch_get(EM_X86_64);
    else if (!strcmp(d->architecture, "aarch64")) d->arch = xrt_arch_get(EM_AARCH64);
    else return error(&p, XRT_UNSUPPORTED_ARCHITECTURE, "GDB target.xml architecture has no supported register mapping");
    if (!d->arch || !d->count)
        return error(&p, XRT_REGISTER_UNAVAILABLE, "GDB target.xml has no register description");
    const struct xrt_register_desc *pc = xrt_arch_role(d->arch, XRT_ROLE_PC);
    const struct xrt_register_desc *sp = xrt_arch_role(d->arch, XRT_ROLE_SP);
    if (!pc || !sp || !xrt_gdb_description_register(d, pc) || !xrt_gdb_description_register(d, sp))
        return error(&p, XRT_REGISTER_UNAVAILABLE, "GDB target.xml is missing usable PC or SP");
    return XRT_OK;
}
static int hex(unsigned c)
{
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}
enum xrt_status xrt_gdb_description_decode(const struct xrt_gdb_description *d,
                                            const uint8_t *text, size_t size,
                                            struct xrt_registers *out)
{
    if (!d || !d->arch || !text || !out) return XRT_INVALID_ARGUMENT;
    if (!size || size % 2 || size > 2 * d->register_bytes || size > XRT_GDB_PAYLOAD_MAX)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    /* A stub may place only a whole-register prefix in g (QEMU leaves
     * optional system/vector banks to p). The omitted suffix stays unknown. */
    size_t bytes = size / 2;
    /* Validate even unprojected FP/vector bytes. A register may be unavailable
     * only as a whole; mixed hex/x bytes are not a valid partial value. */
    for (uint32_t i = 0; i < d->count; ++i) {
        const struct xrt_gdb_register *r = &d->registers[i];
        if (r->offset >= bytes) break;
        if (r->bytes > bytes - r->offset) return XRT_UNEXPECTED_REGISTER_SIZE;
        bool unknown = text[2 * r->offset] == 'x';
        for (uint32_t j = 0; j < 2 * r->bytes; ++j) {
            unsigned c = text[2 * r->offset + j];
            if (unknown ? c != 'x' : hex(c) < 0) return XRT_PROTOCOL_ERROR;
        }
    }
    struct xrt_registers regs = {.abi = xrt_arch_abi(d->arch)};
    for (unsigned i = 0; i < d->arch->register_count; ++i) {
        const struct xrt_register_desc *desc = &d->arch->registers[i];
        const struct xrt_gdb_register *r = xrt_gdb_description_register(d, desc);
        if (!r || r->offset >= bytes || text[2 * r->offset] == 'x') {
            if (regs.unknown_count == XRT_ABSENT_MAX) return XRT_BUFFER_TOO_SMALL;
            regs.unknown_id[regs.unknown_count++] = desc->id;
            continue;
        }
        uint64_t value = 0;
        for (uint32_t j = 0; j < r->bytes; ++j) {
            unsigned byte = (unsigned)(hex(text[2 * (r->offset + j)]) * 16 + hex(text[2 * (r->offset + j) + 1]));
            unsigned shift = d->arch->little_endian ? j : r->bytes - j - 1;
            value |= (uint64_t)byte << (shift * 8);
        }
        memcpy((uint8_t *)&regs.values + desc->snapshot_offset, &value, sizeof(value));
    }
    enum xrt_status status = xrt_registers_validate(d->arch, &regs);
    if (status == XRT_OK) *out = regs;
    return status;
}
