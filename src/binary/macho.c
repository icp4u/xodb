#include "macho.h"
#include <stdlib.h>
#include <string.h>

enum {
    LC_SYMTAB = 0x2, LC_UNIXTHREAD = 0x5, LC_DYSYMTAB = 0xb, LC_LOAD_DYLIB = 0xc,
    LC_ID_DYLIB = 0xd, LC_SEGMENT_64 = 0x19, LC_UUID = 0x1b, LC_CODE_SIGNATURE = 0x1d,
    LC_LAZY_LOAD_DYLIB = 0x20, LC_DYLD_INFO = 0x22, LC_VERSION_MIN_MACOSX = 0x24,
    LC_VERSION_MIN_IPHONEOS = 0x25, LC_FUNCTION_STARTS = 0x26, LC_ENCRYPTION_INFO_64 = 0x2c,
    LC_VERSION_MIN_TVOS = 0x2f, LC_VERSION_MIN_WATCHOS = 0x30, LC_BUILD_VERSION = 0x32
};
#define LC_REQ_DYLD 0x80000000u
#define LC_LOAD_WEAK_DYLIB (0x18u | LC_REQ_DYLD)
#define LC_REEXPORT_DYLIB (0x1fu | LC_REQ_DYLD)
#define LC_DYLD_INFO_ONLY (0x22u | LC_REQ_DYLD)
#define LC_LOAD_UPWARD_DYLIB (0x23u | LC_REQ_DYLD)
#define LC_MAIN (0x28u | LC_REQ_DYLD)
#define LC_DYLD_EXPORTS_TRIE (0x33u | LC_REQ_DYLD)
#define LC_DYLD_CHAINED_FIXUPS (0x34u | LC_REQ_DYLD)
#define N_STAB 0xe0u
#define N_PEXT 0x10u
#define N_TYPE 0x0eu
#define N_EXT 0x01u
#define N_SECT 0x0eu
#define N_FUN 0x24u
#define N_SO 0x64u
#define N_OSO 0x66u
#define PAGE 4096u

typedef char symbol_is_one_nlist[sizeof(struct xmo_symbol) == 16 ? 1 : -1];
struct lazy { unsigned done; enum xmo_status status; };
struct xmo_image {
    struct xmo_source source;
    struct xmo_info info;
    uint64_t base, limit, read_limit, retained_limit; /* base/limit: the slice inside a FILE source */
    struct xmo_fat_arch fat[XMO_MAX_FAT_ARCH];
    unsigned char *commands;
    struct xmo_segment *segments;
    struct xmo_section *sections;
    struct xmo_dylib *dylibs;
    uint32_t symoff, stroff, starts_offset, starts_size;
    uint64_t entry_offset, thread_pc;
    unsigned has_thread_pc;
    struct lazy symbols_state, address_state, name_state, starts_state, debug_state;
    struct xmo_symbol *symbols;
    uint32_t symbol_count;
    uint64_t strings_at;
    unsigned char *strings;
    uint32_t *by_address, address_count; /* (value, external first, index) order */
    uint32_t *hashes, *by_name, name_count; /* (hash, index) order */
    uint64_t *starts;
    uint32_t start_count, start_capacity;
    struct xmo_debug_object *objects;
    struct xmo_debug_function *functions;
    uint32_t object_count, function_count;
    unsigned char page[PAGE]; /* one page of the string table */
    uint64_t page_at;
    uint32_t page_size;
    unsigned page_valid;
    uint64_t name_work; /* name bytes copied out of the string table */
};

static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | (unsigned)p[1] << 8); }
static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p+4) << 32; }
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[0] << 24;
}
static uint64_t be64(const unsigned char *p) { return be32(p+4) | (uint64_t)be32(p) << 32; }
/* strnlen is not ISO C. */
static size_t bounded_length(const char *text, size_t limit) {
    const char *end = memchr(text, 0, limit);
    return end ? (size_t)(end-text) : limit;
}
static int span(uint64_t at, uint64_t size, uint64_t limit) { return at <= limit && size <= limit-at; }
static int overlap(uint64_t a, uint64_t an, uint64_t b, uint64_t bn) {
    return an && bn && a < b+bn && b < a+an;
}

const char *xmo_status_name(enum xmo_status status) {
    static const char *const names[] = { "ok", "not-macho", "unsupported", "malformed", "limit", "io",
        "changed", "cancelled", "no-memory", "not-found", "unavailable" };
    return (unsigned)status < sizeof names/sizeof *names ? names[status] : "unknown";
}
enum xmo_kind xmo_probe(const unsigned char *bytes, size_t size) {
    if (!bytes || size < 4) return XMO_KIND_NONE;
    uint32_t stored = be32(bytes);
    if (stored == 0xcffaedfeu) return XMO_KIND_THIN_64;
    if (stored == 0xfeedfacfu) return XMO_KIND_THIN_64_BIG_ENDIAN;
    if (stored == 0xcefaedfeu || stored == 0xfeedfaceu) return XMO_KIND_THIN_32;
    if (stored != 0xcafebabeu && stored != 0xcafebabfu) return XMO_KIND_NONE;
    if (size < 8) return XMO_KIND_NONE;
    uint32_t count = be32(bytes+4);
    if (!count || count > XMO_MAX_FAT_ARCH) return XMO_KIND_NONE;
    return stored == 0xcafebabeu ? XMO_KIND_FAT : XMO_KIND_FAT_64;
}

static enum xmo_status fetch(struct xmo_image *p, uint64_t at, void *out, uint64_t size) {
    if (!span(at, size, p->source.size)) return p->source.layout == XMO_FILE ? XMO_MALFORMED : XMO_UNAVAILABLE;
    unsigned char *bytes = out;
    while (size) {
        size_t chunk = size > XMO_MAX_CHUNK ? XMO_MAX_CHUNK : (size_t)size;
        if (chunk > p->read_limit-p->info.source_bytes || p->info.source_reads >= XMO_MAX_READS) return XMO_LIMIT;
        enum xmo_status status = p->source.read(p->source.context, at, bytes, chunk);
        if (status != XMO_OK) return status;
        p->info.source_bytes += chunk; ++p->info.source_reads;
        at += chunk; bytes += chunk; size -= chunk;
    }
    return XMO_OK;
}
static enum xmo_status retain(struct xmo_image *p, uint64_t count, size_t each, void *out) {
    if (!count || count > (p->retained_limit-p->info.retained_bytes)/each) return XMO_LIMIT;
    void *result = calloc((size_t)count, each);
    if (!result) return XMO_NOMEM;
    p->info.retained_bytes += count*each;
    memcpy(out, &result, sizeof result);
    return XMO_OK;
}
static void release(struct xmo_image *p, void *pointer, uint64_t count, size_t each) {
    if (!pointer) return;
    free(pointer); p->info.retained_bytes -= count*each;
}
/* Where `size` bytes at a (slice-relative) file offset are in the source. In a
 * loaded image a file offset is reached through the segment that maps it. */
static enum xmo_status locate(const struct xmo_image *p, uint64_t fileoff, uint64_t size, uint64_t *at) {
    if (p->source.layout == XMO_FILE) {
        if (!span(fileoff, size, p->limit)) return XMO_MALFORMED;
        *at = p->base+fileoff;
        return XMO_OK;
    }
    if (!p->info.has_text) return XMO_UNAVAILABLE;
    for (uint32_t i=0; i<p->info.segment_count; ++i) {
        const struct xmo_segment *s = &p->segments[i];
        if (fileoff < s->fileoff || !span(fileoff-s->fileoff, size, s->filesize)) continue;
        uint64_t address = s->vmaddr+(fileoff-s->fileoff);
        if (address < p->info.text_vmaddr) return XMO_UNAVAILABLE;
        *at = address-p->info.text_vmaddr;
        return span(*at, size, p->source.size) ? XMO_OK : XMO_UNAVAILABLE;
    }
    return XMO_MALFORMED;
}

static enum xmo_status segment(struct xmo_image *p, const unsigned char *c, uint32_t index, uint32_t first, uint32_t count) {
    struct xmo_segment *s = &p->segments[index];
    memcpy(s->name, c+8, 16);
    s->vmaddr = u64(c+24); s->vmsize = u64(c+32); s->fileoff = u64(c+40); s->filesize = u64(c+48);
    s->maxprot = u32(c+56); s->initprot = u32(c+60); s->flags = u32(c+68);
    s->first_section = first; s->section_count = count;
    if (s->vmaddr > UINT64_MAX-s->vmsize || s->fileoff > UINT64_MAX-s->filesize || s->filesize > s->vmsize) return XMO_MALFORMED;
    if (p->source.layout == XMO_FILE && !span(s->fileoff, s->filesize, p->limit)) return XMO_MALFORMED;
    if (!p->info.has_text && !strcmp(s->name, "__TEXT")) { p->info.has_text = 1; p->info.text_vmaddr = s->vmaddr; }
    for (uint32_t i=0; i<count; ++i) {
        const unsigned char *raw = c+72+(size_t)i*80;
        struct xmo_section *section = &p->sections[first+i];
        memcpy(section->name, raw, 16); memcpy(section->segment, raw+16, 16);
        section->address = u64(raw+32); section->size = u64(raw+40);
        section->offset = u32(raw+48); section->align = u32(raw+52); section->flags = u32(raw+64);
        section->relocation_offset = u32(raw+56); section->relocation_count = u32(raw+60);
        section->segment_index = index;
        if (section->address < s->vmaddr || !span(section->address-s->vmaddr, section->size, s->vmsize)) return XMO_MALFORMED;
    }
    return XMO_OK;
}
static int dylib_kind(uint32_t cmd, enum xmo_dylib_kind *kind) {
    switch (cmd) {
    case LC_ID_DYLIB: *kind = XMO_DYLIB_ID; return 1;
    case LC_LOAD_DYLIB: *kind = XMO_DYLIB_LOAD; return 1;
    case LC_LOAD_WEAK_DYLIB: *kind = XMO_DYLIB_WEAK; return 1;
    case LC_REEXPORT_DYLIB: *kind = XMO_DYLIB_REEXPORT; return 1;
    case LC_LAZY_LOAD_DYLIB: *kind = XMO_DYLIB_LAZY; return 1;
    case LC_LOAD_UPWARD_DYLIB: *kind = XMO_DYLIB_UPWARD; return 1;
    }
    return 0;
}
enum { SEEN_SYMTAB = 1, SEEN_DYSYMTAB = 2, SEEN_UUID = 4, SEEN_MAIN = 8, SEEN_STARTS = 16,
    SEEN_SIGNATURE = 32, SEEN_ID = 64, SEEN_TRIE = 128, SEEN_CHAINED = 256, SEEN_DYLD_INFO = 512 };
static int once(unsigned *seen, unsigned bit) {
    if (*seen & bit) return 0;
    *seen |= bit;
    return 1;
}
/* The load commands, twice: first to validate sizes and count what will be
 * retained, then to fill arrays allocated from those counts. */
static enum xmo_status walk(struct xmo_image *p, int fill) {
    struct xmo_info *info = &p->info;
    const unsigned char *c = p->commands;
    uint32_t left = info->commands_size, segments = 0, sections = 0, dylibs = 0;
    unsigned seen = 0;
    for (uint32_t i=0; i<info->command_count; ++i) {
        if (left < 8) return XMO_MALFORMED;
        uint32_t cmd = u32(c), size = u32(c+4);
        enum xmo_dylib_kind kind;
        if (size < 8 || (size&7) || size > left) return XMO_MALFORMED;
        if (cmd == LC_SEGMENT_64) {
            if (size < 72) return XMO_MALFORMED;
            uint32_t count = u32(c+64);
            if (count > (size-72)/80) return XMO_MALFORMED;
            if (segments >= XMO_MAX_SEGMENTS || count > XMO_MAX_SECTIONS-sections) return XMO_LIMIT;
            if (fill) {
                enum xmo_status status = segment(p, c, segments, sections, count);
                if (status != XMO_OK) return status;
            }
            ++segments; sections += count;
        } else if (dylib_kind(cmd, &kind)) {
            if (size < 24) return XMO_MALFORMED;
            uint32_t name = u32(c+8);
            if (name < 24 || name >= size) return XMO_MALFORMED;
            size_t length = bounded_length((const char *)c+name, size-name);
            if (length == size-name) return XMO_MALFORMED;
            if (length > XMO_MAX_PATH || dylibs >= XMO_MAX_DYLIBS) return XMO_LIMIT;
            if (fill) {
                if (kind == XMO_DYLIB_ID && !once(&seen, SEEN_ID)) return XMO_MALFORMED;
                p->dylibs[dylibs] = (struct xmo_dylib){ (const char *)c+name, kind, u32(c+12), u32(c+16), u32(c+20) };
            }
            ++dylibs;
        } else if (!fill) {
            /* Everything else is decoded on the second pass. */
        } else if (cmd == LC_SYMTAB) {
            if (size < 24 || !once(&seen, SEEN_SYMTAB)) return XMO_MALFORMED;
            info->has_symtab = 1;
            p->symoff = u32(c+8); info->symbol_count = u32(c+12); p->stroff = u32(c+16); info->string_size = u32(c+20);
        } else if (cmd == LC_DYSYMTAB) {
            if (size < 80 || !once(&seen, SEEN_DYSYMTAB)) return XMO_MALFORMED;
            info->has_dysymtab = 1;
            info->local_first = u32(c+8); info->local_count = u32(c+12);
            info->external_first = u32(c+16); info->external_count = u32(c+20);
            info->undefined_first = u32(c+24); info->undefined_count = u32(c+28);
        } else if (cmd == LC_UUID) {
            if (size < 24 || !once(&seen, SEEN_UUID)) return XMO_MALFORMED;
            info->has_uuid = 1; memcpy(info->uuid, c+8, 16);
        } else if (cmd == LC_MAIN) {
            if (size < 24 || !once(&seen, SEEN_MAIN)) return XMO_MALFORMED;
            p->entry_offset = u64(c+8); info->stack_size = u64(c+16);
        } else if (cmd == LC_UNIXTHREAD) {
            /* Flavors follow one another; each is bounded by the command. */
            uint32_t want = info->cputype == XMO_CPU_ARM64 ? 6 : 4, words = info->cputype == XMO_CPU_ARM64 ? 68 : 42;
            uint32_t pc = info->cputype == XMO_CPU_ARM64 ? 256 : 128;
            for (uint32_t at=8; size-at >= 8;) {
                uint32_t flavor = u32(c+at), count = u32(c+at+4);
                if (count > (size-at-8)/4) return XMO_MALFORMED;
                if (flavor == want && count == words && !p->has_thread_pc) { p->has_thread_pc = 1; p->thread_pc = u64(c+at+8+pc); }
                at += 8+count*4;
            }
        } else if (cmd == LC_FUNCTION_STARTS || cmd == LC_CODE_SIGNATURE || cmd == LC_DYLD_EXPORTS_TRIE || cmd == LC_DYLD_CHAINED_FIXUPS) {
            unsigned bit = cmd == LC_FUNCTION_STARTS ? SEEN_STARTS : cmd == LC_CODE_SIGNATURE ? SEEN_SIGNATURE : cmd == LC_DYLD_EXPORTS_TRIE ? SEEN_TRIE : SEEN_CHAINED;
            if (size < 16 || !once(&seen, bit)) return XMO_MALFORMED;
            if (cmd == LC_FUNCTION_STARTS) { info->has_function_starts = 1; p->starts_offset = u32(c+8); p->starts_size = u32(c+12); }
            else if (cmd == LC_CODE_SIGNATURE) { info->has_code_signature = 1; info->code_signature_offset = u32(c+8); info->code_signature_size = u32(c+12); }
            else if (cmd == LC_DYLD_EXPORTS_TRIE) info->has_exports_trie = 1;
            else info->fixups = XMO_FIXUPS_CHAINED;
        } else if (cmd == LC_DYLD_INFO || cmd == LC_DYLD_INFO_ONLY) {
            if (size < 48 || !once(&seen, SEEN_DYLD_INFO)) return XMO_MALFORMED;
            if (info->fixups == XMO_FIXUPS_NONE) info->fixups = XMO_FIXUPS_DYLD_INFO;
            if (u32(c+44)) info->has_exports_trie = 1;
        } else if (cmd == LC_BUILD_VERSION) {
            if (size < 24 || u32(c+20) > (size-24)/8) return XMO_MALFORMED;
            if (!info->version_from_build_command) {
                info->version_from_build_command = 1;
                info->platform = u32(c+8); info->min_os = u32(c+12); info->sdk = u32(c+16);
            }
        } else if (cmd == LC_VERSION_MIN_MACOSX || cmd == LC_VERSION_MIN_IPHONEOS || cmd == LC_VERSION_MIN_TVOS || cmd == LC_VERSION_MIN_WATCHOS) {
            if (size < 16) return XMO_MALFORMED;
            if (!info->platform) {
                info->platform = cmd == LC_VERSION_MIN_MACOSX ? 1 : cmd == LC_VERSION_MIN_IPHONEOS ? 2 : cmd == LC_VERSION_MIN_TVOS ? 3 : 4;
                info->min_os = u32(c+8); info->sdk = u32(c+12);
            }
        } else if (cmd == LC_ENCRYPTION_INFO_64) {
            if (size < 24) return XMO_MALFORMED;
            if (u32(c+16)) info->encrypted = 1;
        }
        c += size; left -= size;
    }
    if (!fill) { info->segment_count = segments; info->section_count = sections; info->dylib_count = dylibs; return XMO_OK; }
    if (seen&SEEN_MAIN && info->has_text) {
        if (p->entry_offset > UINT64_MAX-info->text_vmaddr) return XMO_MALFORMED;
        info->entry = XMO_ENTRY_MAIN; info->entry_address = info->text_vmaddr+p->entry_offset;
    } else if (p->has_thread_pc) {
        info->entry = XMO_ENTRY_UNIXTHREAD; info->entry_address = p->thread_pc;
    }
    if (info->has_dysymtab && (!span(info->local_first, info->local_count, info->symbol_count) ||
        !span(info->external_first, info->external_count, info->symbol_count) ||
        !span(info->undefined_first, info->undefined_count, info->symbol_count))) return XMO_MALFORMED;
    return XMO_OK;
}
static enum xmo_status thin(struct xmo_image *p) {
    unsigned char h[32];
    struct xmo_info *info = &p->info;
    if (p->limit < 4) return XMO_NOT_MACHO;
    enum xmo_status status = fetch(p, p->base, h, 4);
    if (status != XMO_OK) return status;
    enum xmo_kind kind = xmo_probe(h, 4);
    if (kind == XMO_KIND_THIN_64_BIG_ENDIAN || kind == XMO_KIND_THIN_32) return XMO_UNSUPPORTED;
    /* A dyld shared cache file ("dyld_v1 ...") is a different container. */
    if (kind != XMO_KIND_THIN_64) return memcmp(h, "dyld", 4) ? XMO_NOT_MACHO : XMO_UNSUPPORTED;
    if (p->limit < sizeof h) return p->source.layout == XMO_FILE ? XMO_MALFORMED : XMO_UNAVAILABLE;
    status = fetch(p, p->base, h, sizeof h);
    if (status != XMO_OK) return status;
    info->cputype = u32(h+4); info->cpusubtype = u32(h+8); info->filetype = u32(h+12);
    info->command_count = u32(h+16); info->commands_size = u32(h+20); info->flags = u32(h+24);
    if (info->cputype != XMO_CPU_ARM64 && info->cputype != XMO_CPU_X86_64) return XMO_UNSUPPORTED;
    if ((uint64_t)info->command_count*8 > info->commands_size) return XMO_MALFORMED;
    if (!span(sizeof h, info->commands_size, p->limit)) return p->source.layout == XMO_FILE ? XMO_MALFORMED : XMO_UNAVAILABLE;
    if (info->command_count > XMO_MAX_COMMANDS || info->commands_size > XMO_MAX_COMMAND_BYTES) return XMO_LIMIT;
    if (!info->commands_size) return XMO_OK;
    status = retain(p, info->commands_size, 1, &p->commands);
    if (status != XMO_OK) return status;
    status = fetch(p, p->base+sizeof h, p->commands, info->commands_size);
    if (status != XMO_OK) return status;
    status = walk(p, 0);
    if (status != XMO_OK) return status;
    if (info->segment_count && (status = retain(p, info->segment_count, sizeof *p->segments, &p->segments)) != XMO_OK) return status;
    if (info->section_count && (status = retain(p, info->section_count, sizeof *p->sections, &p->sections)) != XMO_OK) return status;
    if (info->dylib_count && (status = retain(p, info->dylib_count, sizeof *p->dylibs, &p->dylibs)) != XMO_OK) return status;
    return walk(p, 1);
}
static enum xmo_status fat(struct xmo_image *p, const struct xmo_options *options, int wide) {
    unsigned char raw[32];
    if (p->source.layout != XMO_FILE) return XMO_UNSUPPORTED;
    if (p->source.size < 8) return XMO_MALFORMED;
    enum xmo_status status = fetch(p, 4, raw, 4);
    if (status != XMO_OK) return status;
    uint32_t count = be32(raw), each = wide ? 32 : 20;
    if (!count) return XMO_MALFORMED;
    /* A Java class file: the same magic, then minor and major version. */
    if (count > XMO_MAX_FAT_ARCH) return !wide && (count&0xffff) >= 45 ? XMO_NOT_MACHO : XMO_LIMIT;
    uint64_t table_end = 8+(uint64_t)count*each;
    if (table_end > p->source.size) return XMO_MALFORMED;
    const struct xmo_fat_arch *chosen = NULL;
    for (uint32_t i=0; i<count; ++i) {
        struct xmo_fat_arch *a = &p->fat[i];
        status = fetch(p, 8+(uint64_t)i*each, raw, each);
        if (status != XMO_OK) return status;
        a->cputype = be32(raw); a->cpusubtype = be32(raw+4);
        if (wide) { a->offset = be64(raw+8); a->size = be64(raw+16); a->align = be32(raw+24); }
        else { a->offset = be32(raw+8); a->size = be32(raw+12); a->align = be32(raw+16); }
        if (!a->size || a->offset < table_end || !span(a->offset, a->size, p->source.size)) return XMO_MALFORMED;
        for (uint32_t j=0; j<i; ++j) if (overlap(a->offset, a->size, p->fat[j].offset, p->fat[j].size)) return XMO_MALFORMED;
        int supported = a->cputype == XMO_CPU_ARM64 || a->cputype == XMO_CPU_X86_64;
        if (!chosen && (options && options->cputype ? a->cputype == options->cputype : supported) &&
            (!options || !options->match_subtype || (a->cpusubtype & XMO_CPU_SUBTYPE_MASK) == (options->cpusubtype & XMO_CPU_SUBTYPE_MASK))) chosen = a;
    }
    p->info.fat_count = count; p->info.fat_64 = wide != 0;
    if (!chosen) return options && options->cputype ? XMO_NOT_FOUND : XMO_UNSUPPORTED;
    p->base = chosen->offset; p->limit = chosen->size;
    if (p->limit < 8) return XMO_MALFORMED;
    status = fetch(p, p->base, raw, 8);
    if (status != XMO_OK) return status;
    /* No recursion: a slice is one Mach-O image, never another container. */
    if (be32(raw) == 0xcafebabeu || be32(raw) == 0xcafebabfu) return XMO_MALFORMED;
    if (!memcmp(raw, "!<arch>\n", 8)) return XMO_UNSUPPORTED;
    status = thin(p);
    if (status == XMO_NOT_MACHO) return XMO_MALFORMED;
    if (status == XMO_OK && (p->info.cputype != chosen->cputype || p->info.cpusubtype != chosen->cpusubtype)) return XMO_MALFORMED;
    return status;
}
enum xmo_status xmo_load(const struct xmo_source *source, const struct xmo_options *options, struct xmo_image **out) {
    unsigned char magic[4];
    if (!source || !source->read || !out) return XMO_MALFORMED;
    *out = NULL;
    if (source->layout != XMO_FILE && source->layout != XMO_MEMORY) return XMO_MALFORMED;
    if (source->size < sizeof magic) return XMO_NOT_MACHO;
    struct xmo_image *p = calloc(1, sizeof *p);
    if (!p) return XMO_NOMEM;
    p->source = *source; p->limit = source->size;
    p->read_limit = options && options->max_read_bytes && options->max_read_bytes < XMO_MAX_READ_BYTES ? options->max_read_bytes : XMO_MAX_READ_BYTES;
    p->retained_limit = options && options->max_retained_bytes && options->max_retained_bytes < XMO_MAX_RETAINED_BYTES ? options->max_retained_bytes : XMO_MAX_RETAINED_BYTES;
    enum xmo_status status = fetch(p, 0, magic, sizeof magic);
    if (status == XMO_OK) {
        uint32_t stored = be32(magic);
        status = stored == 0xcafebabeu || stored == 0xcafebabfu ? fat(p, options, stored == 0xcafebabfu) : thin(p);
    }
    p->info.slice_offset = p->base; p->info.slice_size = p->limit;
    if (status != XMO_OK) { xmo_destroy(p); return status; }
    *out = p;
    return XMO_OK;
}
void xmo_destroy(struct xmo_image *p) {
    if (!p) return;
    free(p->commands); free(p->segments); free(p->sections); free(p->dylibs); free(p->symbols); free(p->strings);
    free(p->by_address); free(p->hashes); free(p->by_name); free(p->starts); free(p->objects); free(p->functions);
    free(p);
}
const struct xmo_info *xmo_info(const struct xmo_image *p) { return p ? &p->info : NULL; }
const struct xmo_fat_arch *xmo_fat_arch(const struct xmo_image *p, unsigned i) { return p && i < p->info.fat_count ? &p->fat[i] : NULL; }
const struct xmo_segment *xmo_segment(const struct xmo_image *p, unsigned i) { return p && i < p->info.segment_count ? &p->segments[i] : NULL; }
const struct xmo_section *xmo_section(const struct xmo_image *p, unsigned i) { return p && i < p->info.section_count ? &p->sections[i] : NULL; }
const struct xmo_dylib *xmo_dylib(const struct xmo_image *p, unsigned i) { return p && i < p->info.dylib_count ? &p->dylibs[i] : NULL; }
const struct xmo_section *xmo_find_section(const struct xmo_image *p, const char *segment_name, const char *name) {
    if (!p || !segment_name || !name) return NULL;
    for (uint32_t i=0; i<p->info.section_count; ++i)
        if (!strcmp(p->sections[i].segment, segment_name) && !strcmp(p->sections[i].name, name)) return &p->sections[i];
    return NULL;
}
enum xmo_status xmo_section_range(const struct xmo_image *p, const struct xmo_section *s, struct xmo_range *out) {
    if (!p || !out || !s || s < p->sections || s >= p->sections+p->info.section_count) return XMO_MALFORMED;
    out->address = s->address; out->size = s->size;
    if (p->source.layout == XMO_MEMORY) {
        if (!p->info.has_text || s->address < p->info.text_vmaddr) return XMO_UNAVAILABLE;
        out->source_offset = s->address-p->info.text_vmaddr;
        return span(out->source_offset, s->size, p->source.size) ? XMO_OK : XMO_UNAVAILABLE;
    }
    const struct xmo_segment *owner = &p->segments[s->segment_index];
    uint32_t type = s->flags&0xff;
    /* S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL: no bytes in a file. */
    if (type == 0x1 || type == 0xc || type == 0x12) return XMO_UNAVAILABLE;
    if (s->offset < owner->fileoff || !span(s->offset-owner->fileoff, s->size, owner->filesize)) return XMO_UNAVAILABLE;
    out->source_offset = p->base+s->offset;
    return XMO_OK;
}
enum xmo_status xmo_read_section(const struct xmo_image *p, const struct xmo_section *s, uint64_t at, void *out, size_t size) {
    struct xmo_range range;
    if (!out && size) return XMO_MALFORMED;
    enum xmo_status status = xmo_section_range(p, s, &range);
    if (status != XMO_OK) return status;
    if (size > XMO_MAX_CHUNK) return XMO_LIMIT;
    if (!span(at, size, range.size)) return XMO_MALFORMED;
    return size ? p->source.read(p->source.context, range.source_offset+at, out, size) : XMO_OK;
}
enum xmo_status xmo_read_relocations(const struct xmo_image *p, const struct xmo_section *s,
                                   uint32_t first, uint32_t count, void *out) {
    if (!p || !s || s<p->sections || s>=p->sections+p->info.section_count || (!out && count)) return XMO_MALFORMED;
    if (p->source.layout!=XMO_FILE) return XMO_UNAVAILABLE;
    if (count>XMO_MAX_CHUNK/8) return XMO_LIMIT;
    if (first>s->relocation_count || count>s->relocation_count-first) return XMO_MALFORMED;
    uint64_t at;
    enum xmo_status status=locate(p,s->relocation_offset,(uint64_t)s->relocation_count*8,&at);
    if (status!=XMO_OK) return status;
    return count ? p->source.read(p->source.context,at+(uint64_t)first*8,out,(size_t)count*8) : XMO_OK;
}
enum xmo_status xmo_slide(const struct xmo_image *p, uint64_t header_address, uint64_t *slide) {
    if (!p || !slide) return XMO_MALFORMED;
    if (!p->info.has_text) return XMO_UNAVAILABLE;
    *slide = header_address-p->info.text_vmaddr;
    return XMO_OK;
}
unsigned xmo_symbol_flags(const struct xmo_symbol *s) {
    if (!s) return 0;
    if (s->type&N_STAB) return XMO_SYMBOL_STAB;
    unsigned flags = (s->type&N_EXT ? XMO_SYMBOL_EXTERNAL : 0) | (s->type&N_PEXT ? XMO_SYMBOL_PRIVATE : 0);
    switch (s->type&N_TYPE) {
    case 0x0: return flags|XMO_SYMBOL_UNDEFINED;
    case 0x2: return flags|XMO_SYMBOL_ABSOLUTE;
    case 0xa: return flags|XMO_SYMBOL_INDIRECT;
    case N_SECT: return flags|XMO_SYMBOL_DEFINED;
    }
    return flags;
}

static enum xmo_status load_symbols(struct xmo_image *p) {
    const struct xmo_info *info = &p->info;
    uint64_t at, bytes = (uint64_t)info->symbol_count*16;
    if (!info->has_symtab) return XMO_UNAVAILABLE;
    enum xmo_status status = locate(p, p->symoff, bytes, &at);
    if (status == XMO_OK && info->string_size) status = locate(p, p->stroff, info->string_size, &p->strings_at);
    if (status != XMO_OK) return status;
    if (info->symbol_count > XMO_MAX_SYMBOLS) return XMO_LIMIT;
    if (!info->symbol_count) return XMO_OK;
    status = retain(p, info->symbol_count, sizeof *p->symbols, &p->symbols);
    if (status != XMO_OK) return status;
    status = fetch(p, at, p->symbols, bytes);
    if (status != XMO_OK) {
        release(p, p->symbols, info->symbol_count, sizeof *p->symbols); p->symbols = NULL;
        return status;
    }
    for (uint32_t i=0; i<info->symbol_count; ++i) {
        unsigned char raw[16];
        memcpy(raw, &p->symbols[i], sizeof raw);
        p->symbols[i] = (struct xmo_symbol){ .value = u64(raw+8), .strx = u32(raw), .desc = u16(raw+6), .type = raw[4], .sect = raw[5] };
    }
    p->symbol_count = info->symbol_count;
    return XMO_OK;
}
static enum xmo_status once_loaded(struct xmo_image *p, struct lazy *state, enum xmo_status (*load)(struct xmo_image *)) {
    if (!state->done) { state->status = load(p); state->done = 1; }
    return state->status;
}
enum xmo_status xmo_symbols(struct xmo_image *p, uint32_t *count) {
    if (!p) return XMO_MALFORMED;
    enum xmo_status status = once_loaded(p, &p->symbols_state, load_symbols);
    if (count) *count = status == XMO_OK ? p->symbol_count : 0;
    return status;
}
const struct xmo_symbol *xmo_symbol(const struct xmo_image *p, uint32_t index) {
    return p && index < p->symbol_count ? &p->symbols[index] : NULL;
}
/* One name through the page cache. A defect of this entry alone (outside the
 * table, unterminated, too long) is reported in *defect with XMO_OK, so a
 * table walk can skip it; any other status is a source or budget failure. */
static enum xmo_status name_at(struct xmo_image *p, uint32_t strx, char *out, size_t capacity, size_t *length, enum xmo_status *defect) {
    uint64_t size = p->info.string_size, at = strx;
    size_t done = 0;
    *defect = XMO_OK;
    if (p->strings) {
        if (at >= size) { *defect = XMO_MALFORMED; return XMO_OK; }
        size_t available = size-at < capacity ? (size_t)(size-at) : capacity;
        const unsigned char *end = memchr(p->strings+at, 0, available);
        if (!end) { *defect = available == capacity ? XMO_LIMIT : XMO_MALFORMED; return XMO_OK; }
        *length = (size_t)(end-(p->strings+at));
        memcpy(out, p->strings+at, *length+1);
        return XMO_OK;
    }
    for (;;) {
        if (at >= size) { *defect = XMO_MALFORMED; return XMO_OK; }
        uint64_t start = at&~(uint64_t)(PAGE-1);
        if (!p->page_valid || p->page_at != start) {
            uint32_t want = size-start > PAGE ? PAGE : (uint32_t)(size-start);
            p->page_valid = 0;
            enum xmo_status status = fetch(p, p->strings_at+start, p->page, want);
            if (status != XMO_OK) return status;
            p->page_at = start; p->page_size = want; p->page_valid = 1;
        }
        const unsigned char *from = p->page+(at-start);
        size_t have = p->page_size-(size_t)(at-start);
        const unsigned char *end = memchr(from, 0, have);
        size_t take = end ? (size_t)(end-from) : have;
        if (take > capacity-1-done) { *defect = XMO_LIMIT; p->name_work += capacity; return XMO_OK; }
        memcpy(out+done, from, take); done += take; p->name_work += take+1;
        if (end) { out[done] = 0; *length = done; return XMO_OK; }
        at += have;
    }
}
enum xmo_status xmo_string(struct xmo_image *p, uint32_t strx, char *out, size_t capacity) {
    size_t length;
    enum xmo_status defect;
    if (!p || !out || !capacity) return XMO_MALFORMED;
    out[0] = 0;
    enum xmo_status status = xmo_symbols(p, NULL);
    if (status != XMO_OK) return status;
    if (capacity > XMO_MAX_NAME+1) capacity = XMO_MAX_NAME+1;
    status = name_at(p, strx, out, capacity, &length, &defect);
    if (status == XMO_OK && defect != XMO_OK) { out[0] = 0; return defect; }
    return status;
}

typedef int less_fn(const struct xmo_image *, uint32_t, uint32_t);
static void sift(const struct xmo_image *p, uint32_t *v, size_t root, size_t count, less_fn *less) {
    for (;;) {
        size_t child = 2*root+1;
        if (child >= count) return;
        if (child+1 < count && less(p, v[child], v[child+1])) ++child;
        if (!less(p, v[root], v[child])) return;
        uint32_t held = v[root]; v[root] = v[child]; v[child] = held;
        root = child;
    }
}
/* Heap sort: n log n on every input, in place, no recursion. */
static void sort(const struct xmo_image *p, uint32_t *v, size_t count, less_fn *less) {
    for (size_t start=count/2; start-- > 0;) sift(p, v, start, count, less);
    for (size_t end=count; end-- > 1;) {
        uint32_t held = v[0]; v[0] = v[end]; v[end] = held;
        sift(p, v, 0, end, less);
    }
}
static int less_address(const struct xmo_image *p, uint32_t a, uint32_t b) {
    const struct xmo_symbol *x = &p->symbols[a], *y = &p->symbols[b];
    if (x->value != y->value) return x->value < y->value;
    if ((x->type&N_EXT) != (y->type&N_EXT)) return (x->type&N_EXT) != 0;
    return a < b;
}
static int less_name(const struct xmo_image *p, uint32_t a, uint32_t b) {
    return p->hashes[a] != p->hashes[b] ? p->hashes[a] < p->hashes[b] : a < b;
}
static const struct xmo_section *symbol_section(const struct xmo_image *p, const struct xmo_symbol *s) {
    if ((s->type&N_STAB) || (s->type&N_TYPE) != N_SECT || !s->sect || s->sect > p->info.section_count) return NULL;
    const struct xmo_section *section = &p->sections[s->sect-1];
    return s->value >= section->address && s->value-section->address < section->size ? section : NULL;
}
static enum xmo_status load_addresses(struct xmo_image *p) {
    enum xmo_status status = xmo_symbols(p, NULL);
    if (status != XMO_OK) return status;
    uint32_t count = 0, outside = 0;
    for (uint32_t i=0; i<p->symbol_count; ++i) {
        const struct xmo_symbol *s = &p->symbols[i];
        if (symbol_section(p, s)) ++count;
        else if (!(s->type&N_STAB) && (s->type&N_TYPE) == N_SECT) ++outside;
    }
    p->info.symbols_outside_section = outside;
    if (!count) return XMO_OK;
    status = retain(p, count, sizeof *p->by_address, &p->by_address);
    if (status != XMO_OK) return status;
    for (uint32_t i=0, k=0; i<p->symbol_count; ++i) if (symbol_section(p, &p->symbols[i])) p->by_address[k++] = i;
    sort(p, p->by_address, count, less_address);
    p->address_count = count;
    return XMO_OK;
}
static uint32_t hash(const char *text, size_t length) {
    uint32_t h = 2166136261u;
    for (size_t i=0; i<length; ++i) h = (h^(unsigned char)text[i])*16777619u;
    return h;
}
static enum xmo_status load_names(struct xmo_image *p) {
    char name[XMO_MAX_NAME+1];
    enum xmo_status status = xmo_symbols(p, NULL), defect;
    if (status != XMO_OK) return status;
    uint32_t count = 0, kept = 0, unnamed = 0;
    for (uint32_t i=0; i<p->symbol_count; ++i) if (!(p->symbols[i].type&N_STAB)) ++count;
    if (!count) return XMO_OK;
    status = retain(p, p->symbol_count, sizeof *p->hashes, &p->hashes);
    if (status == XMO_OK && (status = retain(p, count, sizeof *p->by_name, &p->by_name)) != XMO_OK) {
        release(p, p->hashes, p->symbol_count, sizeof *p->hashes); p->hashes = NULL;
    }
    if (status != XMO_OK) return status;
    for (uint32_t i=0; i<p->symbol_count && status == XMO_OK; ++i) {
        size_t length = 0;
        if (p->symbols[i].type&N_STAB) continue;
        status = name_at(p, p->symbols[i].strx, name, sizeof name, &length, &defect);
        /* Long names repeated by every symbol: bounded work, not symbols x 4096. */
        if (status == XMO_OK && p->name_work > XMO_MAX_NAME_WORK) status = XMO_LIMIT;
        if (status != XMO_OK) break;
        if (defect != XMO_OK) { ++unnamed; continue; }
        if (!length) continue;
        p->hashes[i] = hash(name, length); p->by_name[kept++] = i;
    }
    if (status != XMO_OK) {
        release(p, p->hashes, p->symbol_count, sizeof *p->hashes); p->hashes = NULL;
        release(p, p->by_name, count, sizeof *p->by_name); p->by_name = NULL;
        return status;
    }
    sort(p, p->by_name, kept, less_name);
    p->name_count = kept; p->info.unnamed_symbols = unnamed;
    return XMO_OK;
}
static enum xmo_status symbol_find(struct xmo_image *p, const char *name, const struct xmo_symbol **out, int unique) {
    char stored[XMO_MAX_NAME+1];
    if (!p || !name || !out) return XMO_MALFORMED;
    *out = NULL;
    enum xmo_status status = once_loaded(p, &p->name_state, load_names), defect;
    if (status != XMO_OK) return status;
    size_t length = bounded_length(name, XMO_MAX_NAME+1), found;
    if (!length || length > XMO_MAX_NAME) return XMO_NOT_FOUND;
    uint32_t wanted = hash(name, length), low = 0, high = p->name_count;
    while (low < high) {
        uint32_t middle = low+(high-low)/2;
        if (p->hashes[p->by_name[middle]] < wanted) low = middle+1; else high = middle;
    }
    /* Equal hashes are compared by reading each name: a bounded number, so a
     * table built to collide costs a typed refusal, not a long walk. */
    const struct xmo_symbol *undefined = NULL, *defined = NULL;
    for (uint32_t work=0; low < p->name_count && p->hashes[p->by_name[low]] == wanted; ++low, ++work) {
        const struct xmo_symbol *s = &p->symbols[p->by_name[low]];
        if (work == XMO_MAX_NAME_CANDIDATES) return XMO_LIMIT;
        status = name_at(p, s->strx, stored, sizeof stored, &found, &defect);
        if (status != XMO_OK) return status;
        if (defect != XMO_OK || found != length || memcmp(stored, name, length)) continue;
        if ((s->type&N_TYPE) != 0) {
            if (!unique) { *out = s;return XMO_OK; }
            if (defined && (defined->value!=s->value || defined->sect!=s->sect || (defined->type&N_TYPE)!=(s->type&N_TYPE))) return XMO_UNAVAILABLE;
            defined=s;continue;
        }
        if (!undefined) undefined = s;
    }
    *out = defined ? defined : undefined;
    return *out ? XMO_OK : XMO_NOT_FOUND;
}
enum xmo_status xmo_symbol_find(struct xmo_image *p, const char *name, const struct xmo_symbol **out) {
    return symbol_find(p,name,out,0);
}
enum xmo_status xmo_symbol_unique(struct xmo_image *p, const char *name, const struct xmo_symbol **out) {
    return symbol_find(p,name,out,1);
}
static int fatal(enum xmo_status status) {
    return status == XMO_IO || status == XMO_CHANGED || status == XMO_CANCELLED || status == XMO_NOMEM;
}
enum xmo_status xmo_symbol_at(struct xmo_image *p, uint64_t address, const struct xmo_symbol **out, uint64_t *size) {
    if (!p || !out) return XMO_MALFORMED;
    *out = NULL;
    if (size) *size = 0;
    enum xmo_status status = once_loaded(p, &p->address_state, load_addresses);
    if (status != XMO_OK) return status;
    uint32_t low = 0, high = p->address_count;
    while (low < high) { /* first symbol above the address */
        uint32_t middle = low+(high-low)/2;
        if (p->symbols[p->by_address[middle]].value > address) high = middle; else low = middle+1;
    }
    if (!low) return XMO_NOT_FOUND;
    uint32_t above = low;
    uint64_t value = p->symbols[p->by_address[above-1]].value;
    for (low=0, high=above-1; low < high;) { /* first symbol at that value */
        uint32_t middle = low+(high-low)/2;
        if (p->symbols[p->by_address[middle]].value >= value) high = middle; else low = middle+1;
    }
    const struct xmo_symbol *s = &p->symbols[p->by_address[low]];
    const struct xmo_section *section = &p->sections[s->sect-1];
    uint64_t end = section->address+section->size;
    if (above < p->address_count && p->symbols[p->by_address[above]].value < end) end = p->symbols[p->by_address[above]].value;
    const uint64_t *starts;
    uint32_t count;
    status = xmo_function_starts(p, &starts, &count);
    if (fatal(status)) return status;
    if (status == XMO_OK) {
        for (low=0, high=count; low < high;) { /* first function start above the symbol */
            uint32_t middle = low+(high-low)/2;
            if (starts[middle] > value) high = middle; else low = middle+1;
        }
        if (low < count && starts[low] < end) end = starts[low];
    }
    if (address >= end) return XMO_NOT_FOUND;
    *out = s;
    if (size) *size = end-value;
    return XMO_OK;
}

static enum xmo_status load_starts(struct xmo_image *p) {
    unsigned char bytes[PAGE];
    uint64_t at, done = 0, address = p->info.text_vmaddr, value = 0;
    unsigned shift = 0, digits = 0;
    if (!p->info.has_function_starts || !p->info.has_text) return XMO_UNAVAILABLE;
    enum xmo_status status = locate(p, p->starts_offset, p->starts_size, &at);
    if (status != XMO_OK) return status;
    if (p->starts_size > XMO_MAX_FUNCTION_START_BYTES) return XMO_LIMIT;
    while (done < p->starts_size) {
        size_t have = p->starts_size-done > sizeof bytes ? sizeof bytes : (size_t)(p->starts_size-done);
        status = fetch(p, at+done, bytes, have);
        if (status != XMO_OK) return status;
        for (size_t i=0; i<have; ++i) {
            unsigned char byte = bytes[i];
            /* ULEB128 of a 64-bit value: at most ten bytes, the tenth holding one bit. */
            if (++digits > 10 || (digits == 10 && (byte&0x7e))) return XMO_MALFORMED;
            value |= (uint64_t)(byte&0x7f) << shift; shift += 7;
            if (byte&0x80) continue;
            if (!value) return XMO_OK; /* a zero delta ends the list */
            if (value > UINT64_MAX-address) return XMO_MALFORMED;
            address += value;
            if (p->start_count == p->start_capacity) {
                uint32_t wider = p->start_capacity ? p->start_capacity*2 : 1024;
                if (p->start_count == XMO_MAX_FUNCTION_STARTS) return XMO_LIMIT;
                if (wider > XMO_MAX_FUNCTION_STARTS) wider = XMO_MAX_FUNCTION_STARTS;
                uint64_t more = (uint64_t)(wider-p->start_capacity)*sizeof *p->starts;
                if (more > p->retained_limit-p->info.retained_bytes) return XMO_LIMIT;
                uint64_t *grown = realloc(p->starts, (size_t)wider*sizeof *p->starts);
                if (!grown) return XMO_NOMEM;
                p->starts = grown; p->start_capacity = wider; p->info.retained_bytes += more;
            }
            p->starts[p->start_count++] = address;
            value = 0; shift = 0; digits = 0;
        }
        done += have;
    }
    return digits ? XMO_MALFORMED : XMO_OK;
}
static enum xmo_status load_starts_all(struct xmo_image *p) {
    enum xmo_status status = load_starts(p);
    if (status != XMO_OK) p->start_count = 0; /* never a partial list */
    return status;
}
enum xmo_status xmo_function_starts(struct xmo_image *p, const uint64_t **addresses, uint32_t *count) {
    if (!p) return XMO_MALFORMED;
    enum xmo_status status = once_loaded(p, &p->starts_state, load_starts_all);
    if (addresses) *addresses = status == XMO_OK ? p->starts : NULL;
    if (count) *count = status == XMO_OK ? p->start_count : 0;
    return status;
}
enum xmo_status xmo_prepare_labels(struct xmo_image *p) {
    if (!p) return XMO_MALFORMED;
    enum xmo_status status = once_loaded(p, &p->address_state, load_addresses);
    if (status != XMO_OK && status != XMO_UNAVAILABLE) return status;
    if (status == XMO_OK && p->info.string_size && !p->strings) {
        unsigned char *strings = NULL;
        status = retain(p, p->info.string_size, 1, &strings);
        if (status != XMO_OK) return status;
        status = fetch(p, p->strings_at, strings, p->info.string_size);
        if (status != XMO_OK) { release(p, strings, p->info.string_size, 1); return status; }
        p->strings = strings;
    }
    status = xmo_function_starts(p, NULL, NULL);
    return status == XMO_UNAVAILABLE ? XMO_OK : status;
}

/* ld's debug map, in table order: N_SO directory, N_SO file, N_OSO object
 * (value: its mtime), then per function N_FUN name (address, section) and a
 * closing N_FUN without a section (value: size). */
static enum xmo_status load_debug_map(struct xmo_image *p) {
    enum xmo_status status = xmo_symbols(p, NULL);
    if (status != XMO_OK) return status;
    uint32_t objects = 0, functions = 0;
    for (uint32_t i=0; i<p->symbol_count; ++i) {
        const struct xmo_symbol *s = &p->symbols[i];
        if (s->type == N_OSO) ++objects;
        else if (s->type == N_FUN && s->sect) ++functions;
    }
    if (objects && (status = retain(p, objects, sizeof *p->objects, &p->objects)) != XMO_OK) return status;
    if (functions && (status = retain(p, functions, sizeof *p->functions, &p->functions)) != XMO_OK) return status;
    uint32_t directory = 0, source = 0, last_source = UINT32_MAX, object = UINT32_MAX;
    int open = 0;
    objects = functions = 0;
    for (uint32_t i=0; i<p->symbol_count; ++i) {
        const struct xmo_symbol *s = &p->symbols[i];
        if (s->type == N_SO) {
            directory = last_source == i-1 ? source : 0; /* two in a row: directory, then file */
            source = s->strx; last_source = i; open = 0;
        } else if (s->type == N_OSO) {
            object = objects++;
            p->objects[object] = (struct xmo_debug_object){ .mtime = s->value, .path = s->strx, .source_directory = directory, .source_name = source, .first_function = functions };
            directory = source = 0; open = 0;
        } else if (s->type == N_FUN && s->sect) {
            p->functions[functions++] = (struct xmo_debug_function){ .address = s->value, .name = s->strx, .object = object };
            if (object != UINT32_MAX) ++p->objects[object].function_count;
            open = 1;
        } else if (s->type == N_FUN && open) {
            p->functions[functions-1].size = s->value; open = 0;
        }
    }
    p->object_count = objects; p->function_count = functions;
    return XMO_OK;
}
enum xmo_status xmo_debug_map(struct xmo_image *p, struct xmo_debug_map *out) {
    if (!p || !out) return XMO_MALFORMED;
    memset(out, 0, sizeof *out);
    enum xmo_status status = once_loaded(p, &p->debug_state, load_debug_map);
    if (status != XMO_OK) return status;
    *out = (struct xmo_debug_map){ p->objects, p->functions, p->object_count, p->function_count };
    return XMO_OK;
}
