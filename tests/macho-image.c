/* Dump and self-check tool for src/binary/macho.c. Portable C (Linux, macOS).
 *
 *   macho-image PATH [layout=sparse] [arch=arm64|x86_64] [budget=BYTES]
 *               [find=NAME]... [at=HEX]... [slide=HEX] [rows=N]
 *               [memory] [faults] [wrong-result]
 *
 * Prints tab-separated facts and the status of every table. A load or table
 * failure is printed, not fatal: the caller compares it with what it expects.
 * layout=sparse reads a loaded-image description: "XMOSPRS1", u64 extent,
 * u64 count, count x (u64 offset, u64 length), then the bytes of each range.
 * A read outside every range fails, as a read of unmapped memory does. */
#define _POSIX_C_SOURCE 200809L
#include "../src/binary/macho.h"
#include "check.h"
#include <fcntl.h>
#include <inttypes.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct extent { uint64_t offset, length, at; };
struct input {
    int fd;
    uint64_t size, reads, fail_at, unmapped;
    enum xmo_status failure;
    struct extent extents[4096];
    uint64_t extent_count;
    /* memory view of a file image */
    const struct xmo_image *file;
    uint64_t base;
};
static uint64_t le64(const unsigned char *p) { uint64_t v=0; for(int i=7;i>=0;--i) v = v<<8 | p[i]; return v; }
static int exact(int fd, uint64_t at, void *out, size_t n) {
    unsigned char *bytes = out;
    while (n) {
        ssize_t got = pread(fd, bytes, n, (off_t)at);
        if (got <= 0) return 0;
        bytes += got; at += (uint64_t)got; n -= (size_t)got;
    }
    return 1;
}
static enum xmo_status read_file(void *user, uint64_t at, void *out, size_t n) {
    struct input *in = user;
    if (++in->reads == in->fail_at) return in->failure;
    if (n > XMO_MAX_CHUNK || at > in->size || n > in->size-at) return XMO_IO;
    return exact(in->fd, at, out, n) ? XMO_OK : XMO_IO;
}
static enum xmo_status read_sparse(void *user, uint64_t at, void *out, size_t n) {
    struct input *in = user;
    if (++in->reads == in->fail_at) return in->failure;
    for (uint64_t i=0; i<in->extent_count; ++i) {
        const struct extent *e = &in->extents[i];
        if (at >= e->offset && at-e->offset <= e->length && n <= e->length-(at-e->offset))
            return exact(in->fd, e->at+(at-e->offset), out, n) ? XMO_OK : XMO_IO;
    }
    ++in->unmapped;
    return XMO_IO;
}
/* The file image seen as dyld would map it: each segment at its address. */
static enum xmo_status read_mapped(void *user, uint64_t at, void *out, size_t n) {
    struct input *in = user;
    const struct xmo_info *info = xmo_info(in->file);
    if (++in->reads == in->fail_at) return in->failure;
    uint64_t address = info->text_vmaddr+at;
    for (unsigned i=0; i<info->segment_count; ++i) {
        const struct xmo_segment *s = xmo_segment(in->file, i);
        if (address < s->vmaddr || address-s->vmaddr > s->vmsize || n > s->vmsize-(address-s->vmaddr)) continue;
        uint64_t delta = address-s->vmaddr;
        memset(out, 0, n);
        if (delta >= s->filesize) return XMO_OK;
        size_t stored = n > s->filesize-delta ? (size_t)(s->filesize-delta) : n;
        return exact(in->fd, in->base+s->fileoff+delta, out, stored) ? XMO_OK : XMO_IO;
    }
    ++in->unmapped;
    return XMO_IO;
}
static const char *name_of(struct xmo_image *p, uint32_t strx, char *out, size_t capacity) {
    enum xmo_status status = xmo_string(p, strx, out, capacity);
    if (status != XMO_OK) snprintf(out, capacity, "!%s", xmo_status_name(status));
    return out;
}
static void version(char *out, size_t capacity, uint32_t v) {
    snprintf(out, capacity, "%u.%u.%u", v>>16, v>>8&0xff, v&0xff);
}
static void dump(struct xmo_image *p, unsigned rows, int wrong) {
    static char name[XMO_MAX_NAME+1], other[XMO_MAX_NAME+1];
    const struct xmo_info *info = xmo_info(p);
    char minimum[32], sdk[32];
    if (info->fat_count) printf("fat\t%u\t%u\n", info->fat_count, info->fat_64);
    for (unsigned i=0; i<info->fat_count; ++i) {
        const struct xmo_fat_arch *a = xmo_fat_arch(p, i);
        printf("slice\t%u\t0x%x\t0x%x\t%" PRIu64 "\t%" PRIu64 "\t%u\n", i, a->cputype, a->cpusubtype, a->offset, a->size, a->align);
    }
    printf("selected\t%" PRIu64 "\t%" PRIu64 "\n", info->slice_offset, info->slice_size);
    printf("header\t0x%x\t0x%x\t%u\t0x%x\t%u\t%u\n", info->cputype, info->cpusubtype, info->filetype, info->flags, info->command_count, info->commands_size);
    printf("uuid\t");
    if (!info->has_uuid) printf("-");
    else for (unsigned i=0; i<16; ++i) printf("%02X%s", info->uuid[i], i==3 || i==5 || i==7 || i==9 ? "-" : "");
    version(minimum, sizeof minimum, info->min_os); version(sdk, sizeof sdk, info->sdk);
    printf("\nversion\t%u\t%s\t%s\t%s\n", info->platform, minimum, sdk, info->version_from_build_command ? "build" : info->platform ? "min" : "-");
    printf("entry\t%s\t0x%" PRIx64 "\n", info->entry == XMO_ENTRY_MAIN ? "main" : info->entry == XMO_ENTRY_UNIXTHREAD ? "unixthread" : "none", info->entry_address);
    printf("text\t%u\t0x%" PRIx64 "\n", info->has_text, info->text_vmaddr);
    printf("tables\tsymtab=%u\tdysymtab=%u\tstarts=%u\tsignature=%u\ttrie=%u\tfixups=%u\tencrypted=%u\n", info->has_symtab, info->has_dysymtab,
           info->has_function_starts, info->has_code_signature, info->has_exports_trie, (unsigned)info->fixups, info->encrypted);
    if (info->has_dysymtab) printf("dysymtab\t%u\t%u\t%u\t%u\t%u\t%u\n", info->local_first, info->local_count, info->external_first, info->external_count, info->undefined_first, info->undefined_count);
    for (unsigned i=0; i<info->segment_count; ++i) {
        const struct xmo_segment *s = xmo_segment(p, i);
        printf("segment\t%u\t%s\t0x%" PRIx64 "\t0x%" PRIx64 "\t%" PRIu64 "\t%" PRIu64 "\t%u\t%u\t%u\n", i, s->name, s->vmaddr, s->vmsize, s->fileoff, s->filesize, s->maxprot, s->initprot, s->section_count);
    }
    for (unsigned i=0; i<info->section_count; ++i) {
        const struct xmo_section *s = xmo_section(p, i);
        struct xmo_range range = {0};
        enum xmo_status status = xmo_section_range(p, s, &range);
        CHECK(xmo_find_section(p, s->segment, s->name));
        printf("section\t%u\t%s\t%s\t0x%" PRIx64 "\t0x%" PRIx64 "\t%u\t0x%x\t%s\t%" PRIu64 "\n", i, s->segment, s->name, s->address, s->size, s->offset, s->flags, xmo_status_name(status), status == XMO_OK ? range.source_offset : 0);
    }
    for (unsigned i=0; i<info->dylib_count; ++i) {
        const struct xmo_dylib *d = xmo_dylib(p, i);
        printf("dylib\t%u\t%s\t0x%x\t0x%x\n", (unsigned)d->kind, d->name, d->current_version, d->compatibility_version);
    }
    uint32_t count = 0;
    enum xmo_status status = xmo_symbols(p, &count);
    printf("symbols\t%s\t%u\n", xmo_status_name(status), count);
    for (uint32_t i=0; i<count; ++i) {
        const struct xmo_symbol *s = xmo_symbol(p, i), *found = NULL;
        unsigned flags = xmo_symbol_flags(s);
        if (i < rows) printf("symbol\t%u\t0x%" PRIx64 "\t0x%x\t%u\t0x%x\t%u\t%s\n", i, s->value, s->type, s->sect, s->desc, flags, name_of(p, s->strx, name, sizeof name));
        if (i >= 4096 || (flags&XMO_SYMBOL_STAB) || xmo_string(p, s->strx, name, sizeof name) != XMO_OK || !name[0]) continue;
        /* Every named symbol is found again by name; a defined one by address. */
        enum xmo_status looked = xmo_symbol_find(p, name, &found);
        if (looked == XMO_LIMIT) continue; /* more equal hashes than one lookup compares */
        CHECK(looked == XMO_OK && found && xmo_string(p, found->strx, other, sizeof other) == XMO_OK && !strcmp(name, other));
        const struct xmo_section *owner = xmo_section(p, s->sect ? s->sect-1u : UINT32_MAX);
        if (!(flags&XMO_SYMBOL_DEFINED) || !owner || s->value < owner->address || s->value-owner->address >= owner->size) continue;
        uint64_t size = 0;
        looked = xmo_symbol_at(p, s->value, &found, &size);
        CHECK(looked == XMO_OK && found->value == s->value+(wrong ? 1u : 0u) && size > 0);
    }
    const uint64_t *starts = NULL;
    status = xmo_function_starts(p, &starts, &count);
    printf("starts\t%s\t%u\n", xmo_status_name(status), count);
    for (uint32_t i=0; i<count; ++i) {
        CHECK(!i || starts[i] > starts[i-1]);
        if (i < rows) printf("start\t0x%" PRIx64 "\n", starts[i]);
    }
    struct xmo_debug_map map;
    status = xmo_debug_map(p, &map);
    printf("debug\t%s\t%u\t%u\n", xmo_status_name(status), map.object_count, map.function_count);
    for (uint32_t i=0; i<map.object_count && i<rows; ++i) {
        const struct xmo_debug_object *o = &map.objects[i];
        printf("object\t%u\t%s\t%" PRIu64, i, name_of(p, o->path, name, sizeof name), o->mtime);
        printf("\t%s", name_of(p, o->source_directory, name, sizeof name));
        printf("\t%s\t%u\t%u\n", name_of(p, o->source_name, name, sizeof name), o->first_function, o->function_count);
    }
    for (uint32_t i=0; i<map.function_count && i<rows; ++i) {
        const struct xmo_debug_function *f = &map.functions[i];
        printf("function\t%s\t0x%" PRIx64 "\t%" PRIu64 "\t%d\n", name_of(p, f->name, name, sizeof name), f->address, f->size, f->object == UINT32_MAX ? -1 : (int)f->object);
    }
}
static void queries(struct xmo_image *p, int argc, char **argv) {
    static char name[XMO_MAX_NAME+1];
    for (int i=2; i<argc; ++i) {
        const struct xmo_symbol *s = NULL;
        uint64_t size = 0, slide = 0;
        if (!strncmp(argv[i], "find=", 5)) {
            enum xmo_status status = xmo_symbol_find(p, argv[i]+5, &s);
            printf("find\t%s\t%s\t0x%" PRIx64 "\t0x%x\t%u\n", argv[i]+5, xmo_status_name(status), s ? s->value : 0, s ? s->type : 0u, s ? s->sect : 0u);
        } else if (!strncmp(argv[i], "at=", 3)) {
            uint64_t address = strtoull(argv[i]+3, NULL, 16);
            enum xmo_status status = xmo_symbol_at(p, address, &s, &size);
            printf("at\t0x%" PRIx64 "\t%s\t%s\t0x%" PRIx64 "\t%" PRIu64 "\n", address, xmo_status_name(status), s ? name_of(p, s->strx, name, sizeof name) : "-", s ? s->value : 0, size);
        } else if (!strncmp(argv[i], "slide=", 6)) {
            uint64_t header = strtoull(argv[i]+6, NULL, 16);
            enum xmo_status status = xmo_slide(p, header, &slide);
            printf("slide\t0x%" PRIx64 "\t%s\t0x%" PRIx64 "\n", header, xmo_status_name(status), slide);
        }
    }
}
/* The same image through the MEMORY layout must give the same answers. */
static void memory(struct xmo_image *file, struct input *in) {
    static char a[XMO_MAX_NAME+1], b[XMO_MAX_NAME+1];
    const struct xmo_info *info = xmo_info(file);
    CHECK(info->has_text);
    uint64_t extent = 0;
    for (unsigned i=0; i<info->segment_count; ++i) {
        const struct xmo_segment *s = xmo_segment(file, i);
        if (s->vmaddr >= info->text_vmaddr && s->vmaddr+s->vmsize-info->text_vmaddr > extent) extent = s->vmaddr+s->vmsize-info->text_vmaddr;
    }
    struct input mapped = { .fd = in->fd, .size = extent, .file = file, .base = info->slice_offset };
    struct xmo_source source = { &mapped, extent, XMO_MEMORY, read_mapped };
    struct xmo_image *loaded = NULL;
    CHECK(xmo_load(&source, NULL, &loaded) == XMO_OK);
    const struct xmo_info *other = xmo_info(loaded);
    CHECK(other->segment_count == info->segment_count && other->section_count == info->section_count && other->has_uuid == info->has_uuid);
    CHECK(!memcmp(other->uuid, info->uuid, 16) && other->entry_address == info->entry_address && other->cputype == info->cputype);
    uint32_t count = 0, loaded_count = 0;
    enum xmo_status status = xmo_symbols(file, &count);
    CHECK(xmo_symbols(loaded, &loaded_count) == status && loaded_count == count);
    for (uint32_t i=0; i<count && i<4096; ++i) {
        const struct xmo_symbol *x = xmo_symbol(file, i), *y = xmo_symbol(loaded, i);
        CHECK(!memcmp(x, y, sizeof *x));
        CHECK(xmo_string(file, x->strx, a, sizeof a) == xmo_string(loaded, y->strx, b, sizeof b) && !strcmp(a, b));
        const struct xmo_symbol *fx = NULL, *fy = NULL;
        uint64_t sx = 0, sy = 0;
        CHECK(xmo_symbol_at(file, x->value, &fx, &sx) == xmo_symbol_at(loaded, y->value, &fy, &sy) && sx == sy);
        CHECK((!fx && !fy) || (fx && fy && fx-xmo_symbol(file, 0) == fy-xmo_symbol(loaded, 0)));
    }
    const uint64_t *sa = NULL, *sb = NULL;
    uint32_t na = 0, nb = 0;
    CHECK(xmo_function_starts(file, &sa, &na) == xmo_function_starts(loaded, &sb, &nb) && na == nb && (!na || !memcmp(sa, sb, na*sizeof *sa)));
    unsigned compared = 0;
    for (unsigned i=0; i<info->section_count; ++i) {
        unsigned char x[64], y[64];
        const struct xmo_section *s = xmo_section(file, i), *t = xmo_section(loaded, i);
        size_t n = s->size < sizeof x ? (size_t)s->size : sizeof x;
        if (xmo_read_section(file, s, 0, x, n) != XMO_OK) continue;
        CHECK(xmo_read_section(loaded, t, 0, y, n) == XMO_OK && !memcmp(x, y, n));
        CHECK(xmo_read_section(file, s, s->size, x, 1) == XMO_MALFORMED && xmo_read_section(file, s, 0, x, XMO_MAX_CHUNK+1) == XMO_LIMIT);
        ++compared;
    }
    uint64_t slide = 0;
    CHECK(xmo_slide(loaded, info->text_vmaddr+0x4000, &slide) == XMO_OK && slide == 0x4000);
    CHECK(xmo_slide(loaded, 0, &slide) == XMO_OK && slide == 0-info->text_vmaddr);
    printf("memory\tok\tsymbols=%u\tstarts=%u\tsections=%u\tunmapped=%" PRIu64 "\n", count, na, compared, mapped.unmapped);
    xmo_destroy(loaded);
}
/* Every operation, in a fixed order; statuses[] gets one entry per operation. */
enum { OPERATIONS = 6 };
static void every(const struct xmo_source *source, const struct xmo_options *options, enum xmo_status *statuses) {
    struct xmo_image *p = NULL;
    const struct xmo_symbol *s = NULL;
    struct xmo_debug_map map;
    statuses[0] = xmo_load(source, options, &p);
    CHECK((p != NULL) == (statuses[0] == XMO_OK));
    for (int i=1; i<OPERATIONS; ++i) statuses[i] = statuses[0]; /* no image, no tables */
    if (!p) return;
    statuses[1] = xmo_symbols(p, NULL);
    statuses[2] = xmo_function_starts(p, NULL, NULL);
    statuses[3] = xmo_symbol_find(p, "_no_such_symbol_", &s);
    statuses[4] = xmo_symbol_at(p, xmo_info(p)->entry_address, &s, NULL);
    statuses[5] = xmo_debug_map(p, &map);
    CHECK(xmo_info(p)->retained_bytes <= XMO_MAX_RETAINED_BYTES && xmo_info(p)->source_bytes <= XMO_MAX_READ_BYTES);
    xmo_destroy(p);
}
static void faults(struct xmo_source *source, const struct xmo_options *options, struct input *in) {
    enum xmo_status baseline[OPERATIONS], now[OPERATIONS];
    in->reads = 0; in->fail_at = 0;
    every(source, options, baseline);
    uint64_t calls = in->reads;
    CHECK(baseline[0] == XMO_OK && calls > 4);
    for (enum xmo_status failure=XMO_IO; failure<=XMO_CANCELLED; ++failure) {
        for (uint64_t at=1; at<=calls; ++at) {
            int seen = 0;
            in->reads = 0; in->fail_at = at; in->failure = failure;
            every(source, options, now);
            /* The read that failed fails its operation with the same status;
             * nothing else changes, and nothing is published half-read. */
            for (int i=0; i<OPERATIONS; ++i) {
                CHECK(now[i] == baseline[i] || now[i] == failure);
                seen |= now[i] == failure;
            }
            CHECK(seen);
        }
    }
    in->fail_at = 0;
    printf("faults\tok\t%" PRIu64 "\n", calls);
}
int main(int argc, char **argv) {
    static struct input in;
    struct xmo_options options = {0};
    unsigned rows = 4096;
    int sparse = 0, wrong = 0, with_memory = 0, with_faults = 0;
    CHECK(argc >= 2);
    for (int i=2; i<argc; ++i) {
        if (!strcmp(argv[i], "layout=sparse")) sparse = 1;
        else if (!strcmp(argv[i], "arch=arm64")) options.cputype = XMO_CPU_ARM64;
        else if (!strcmp(argv[i], "arch=x86_64")) options.cputype = XMO_CPU_X86_64;
        else if (!strncmp(argv[i], "arch=0x", 7)) options.cputype = (uint32_t)strtoul(argv[i]+5, NULL, 16);
        else if (!strncmp(argv[i], "budget=", 7)) options.max_read_bytes = strtoull(argv[i]+7, NULL, 10);
        else if (!strncmp(argv[i], "rows=", 5)) rows = (unsigned)strtoul(argv[i]+5, NULL, 10);
        else if (!strcmp(argv[i], "wrong-result")) wrong = 1;
        else if (!strcmp(argv[i], "memory")) with_memory = 1;
        else if (!strcmp(argv[i], "faults")) with_faults = 1;
        else CHECK(!strncmp(argv[i], "find=", 5) || !strncmp(argv[i], "at=", 3) || !strncmp(argv[i], "slide=", 6));
    }
    struct stat st;
    in.fd = open(argv[1], O_RDONLY);
    CHECK(in.fd >= 0 && !fstat(in.fd, &st));
    in.size = (uint64_t)st.st_size;
    struct xmo_source source = { &in, in.size, XMO_FILE, read_file };
    if (sparse) {
        unsigned char head[24], row[16];
        CHECK(in.size >= sizeof head && exact(in.fd, 0, head, sizeof head) && !memcmp(head, "XMOSPRS1", 8));
        in.extent_count = le64(head+16);
        CHECK(in.extent_count <= sizeof in.extents/sizeof *in.extents);
        uint64_t at = sizeof head+in.extent_count*16;
        for (uint64_t i=0; i<in.extent_count; ++i) {
            CHECK(exact(in.fd, sizeof head+i*16, row, sizeof row));
            in.extents[i] = (struct extent){ le64(row), le64(row+8), at };
            at += in.extents[i].length;
        }
        CHECK(at == in.size);
        source = (struct xmo_source){ &in, le64(head+8), XMO_MEMORY, read_sparse };
    }
    struct xmo_image *p = NULL;
    enum xmo_status status = xmo_load(&source, &options, &p);
    printf("load\t%s\n", xmo_status_name(status));
    CHECK((p != NULL) == (status == XMO_OK));
    if (p) {
        dump(p, rows, wrong);
        queries(p, argc, argv);
        if (with_memory) memory(p, &in);
        const struct xmo_info *info = xmo_info(p);
        CHECK(info->retained_bytes <= XMO_MAX_RETAINED_BYTES && info->source_bytes <= XMO_MAX_READ_BYTES);
        printf("counters\tbytes=%" PRIu64 "\treads=%" PRIu64 "\tretained=%" PRIu64 "\toutside=%u\tunnamed=%u\tunmapped=%" PRIu64 "\n",
               info->source_bytes, info->source_reads, info->retained_bytes, info->symbols_outside_section, info->unnamed_symbols, in.unmapped);
        xmo_destroy(p);
    }
    if (with_faults) faults(&source, &options, &in);
    CHECK(!close(in.fd) && !fflush(stdout));
    return 0;
}
