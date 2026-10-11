#ifndef XODB_MACHO_H
#define XODB_MACHO_H
#include <stddef.h>
#include <stdint.h>

/* Read-only 64-bit little-endian Mach-O metadata (arm64, x86_64).
 *
 * Two input layouts share one read callback. FILE: offsets are file offsets;
 * a universal (FAT) container is accepted and one slice is selected. MEMORY:
 * an image as loaded in an address space; offset 0 is the mach header and
 * offset N is the byte at header address + N, so a segment is found at its
 * vm address minus __TEXT's. Segments may be far apart (a shared-cache image
 * keeps __LINKEDIT hundreds of megabytes away) and the reader only ever asks
 * for the header, the load commands and the table bytes it indexes.
 *
 * Every field is untrusted. The source and its identity belong to the caller;
 * reads must be exact (no partial results). Nothing here follows a path.
 * An image has one user at a time: lookups load and cache tables. */
enum xmo_status { XMO_OK, XMO_NOT_MACHO, XMO_UNSUPPORTED, XMO_MALFORMED,
    XMO_LIMIT, XMO_IO, XMO_CHANGED, XMO_CANCELLED, XMO_NOMEM, XMO_NOT_FOUND,
    XMO_UNAVAILABLE };
enum xmo_layout { XMO_FILE, XMO_MEMORY };
struct xmo_source {
    void *context;
    uint64_t size; /* FILE: file size. MEMORY: readable extent above the header. */
    enum xmo_layout layout;
    /* At most XMO_MAX_CHUNK bytes per call; offset+size never exceeds size. */
    enum xmo_status (*read)(void *, uint64_t offset, void *, size_t);
};
struct xmo_options {
    uint32_t cputype;        /* FAT: wanted slice; 0 takes the first supported one */
    uint64_t max_read_bytes; /* 0 or above the hard cap: XMO_MAX_READ_BYTES */
    uint32_t cpusubtype;     /* Match the low 24 bits when match_subtype is set. */
    unsigned match_subtype;
    uint64_t max_retained_bytes; /* 0 or above the hard cap: XMO_MAX_RETAINED_BYTES */
};

#define XMO_MAX_CHUNK 65536u
#define XMO_MAX_FAT_ARCH 32u
#define XMO_MAX_COMMANDS 16384u
#define XMO_MAX_COMMAND_BYTES (1024u * 1024u)
#define XMO_MAX_SEGMENTS 256u
#define XMO_MAX_SECTIONS 4096u
#define XMO_MAX_DYLIBS 4096u
#define XMO_MAX_PATH 1024u
#define XMO_MAX_NAME 4096u
#define XMO_MAX_SYMBOLS 2097152u
#define XMO_MAX_FUNCTION_STARTS 2097152u
#define XMO_MAX_FUNCTION_START_BYTES (16u * 1024u * 1024u)
#define XMO_MAX_NAME_CANDIDATES 64u
#define XMO_MAX_NAME_WORK (UINT64_C(256) * 1024 * 1024)
#define XMO_MAX_READ_BYTES (UINT64_C(128) * 1024 * 1024)
#define XMO_MAX_READS 262144u
#define XMO_MAX_RETAINED_BYTES (UINT64_C(96) * 1024 * 1024)

#define XMO_CPU_X86_64 0x01000007u
#define XMO_CPU_ARM64 0x0100000cu
#define XMO_CPU_SUBTYPE_MASK 0x00ffffffu
#define XMO_CPU_SUBTYPE_ARM64E 2u
#define XMO_MH_OBJECT 1u
#define XMO_MH_EXECUTE 2u
#define XMO_MH_DYLIB 6u
#define XMO_MH_DYLINKER 7u
#define XMO_MH_BUNDLE 8u
#define XMO_MH_DSYM 10u
#define XMO_MH_PIE 0x00200000u
#define XMO_MH_DYLIB_IN_CACHE 0x80000000u

/* What the first bytes of a file are. Eight bytes are needed to tell a
 * universal binary from a Java class file, which shares 0xCAFEBABE: the word
 * after it is a slice count here and a class-file version (45 and up) there. */
enum xmo_kind { XMO_KIND_NONE, XMO_KIND_THIN_64, XMO_KIND_THIN_64_BIG_ENDIAN,
    XMO_KIND_THIN_32, XMO_KIND_FAT, XMO_KIND_FAT_64 };
enum xmo_kind xmo_probe(const unsigned char *bytes, size_t size);

struct xmo_fat_arch { uint32_t cputype, cpusubtype, align; uint64_t offset, size; };
struct xmo_segment {
    char name[17];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t maxprot, initprot, flags, first_section, section_count;
};
struct xmo_section {
    char segment[17], name[17];
    uint64_t address, size;
    uint32_t offset, align, flags, segment_index;
};
enum xmo_dylib_kind { XMO_DYLIB_ID, XMO_DYLIB_LOAD, XMO_DYLIB_WEAK,
    XMO_DYLIB_REEXPORT, XMO_DYLIB_LAZY, XMO_DYLIB_UPWARD };
struct xmo_dylib { const char *name; enum xmo_dylib_kind kind; uint32_t timestamp, current_version, compatibility_version; };
enum xmo_entry { XMO_ENTRY_NONE, XMO_ENTRY_MAIN, XMO_ENTRY_UNIXTHREAD };
enum xmo_fixups { XMO_FIXUPS_NONE, XMO_FIXUPS_DYLD_INFO, XMO_FIXUPS_CHAINED };
struct xmo_info {
    uint64_t source_bytes, source_reads, retained_bytes;
    uint64_t slice_offset, slice_size; /* FILE: the selected slice (whole file when thin) */
    uint32_t cputype, cpusubtype, filetype, flags, command_count, commands_size;
    uint32_t fat_count; /* 0 for a thin file */
    unsigned fat_64, has_uuid, has_text;
    unsigned char uuid[16];
    uint32_t platform, min_os, sdk; /* platform 0: no version command */
    unsigned version_from_build_command;
    uint32_t segment_count, section_count, dylib_count;
    uint64_t text_vmaddr; /* link address of the mach header, when has_text */
    enum xmo_entry entry;
    uint64_t entry_address, stack_size; /* link address */
    unsigned has_symtab, has_dysymtab, has_function_starts, has_code_signature;
    unsigned has_exports_trie, encrypted;
    enum xmo_fixups fixups;
    uint32_t symbol_count, string_size; /* as declared by LC_SYMTAB */
    uint32_t local_first, local_count, external_first, external_count, undefined_first, undefined_count;
    uint32_t code_signature_offset, code_signature_size;
    /* Counted while tables load; see the calls below. */
    uint32_t symbols_outside_section, unnamed_symbols;
};

/* nlist_64, as stored. `sect` is 1-based, 0 for none. */
struct xmo_symbol { uint64_t value; uint32_t strx; uint16_t desc; uint8_t type, sect; };
#define XMO_SYMBOL_STAB 1u       /* debugger entry (N_STAB); type is the stab code */
#define XMO_SYMBOL_EXTERNAL 2u   /* N_EXT */
#define XMO_SYMBOL_PRIVATE 4u    /* N_PEXT */
#define XMO_SYMBOL_DEFINED 8u    /* N_SECT: value is an address in section `sect` */
#define XMO_SYMBOL_UNDEFINED 16u
#define XMO_SYMBOL_ABSOLUTE 32u
#define XMO_SYMBOL_INDIRECT 64u
unsigned xmo_symbol_flags(const struct xmo_symbol *);

/* The debug map: which object file each function came from. Surfaced only;
 * no object path is opened. String fields are string-table offsets. */
struct xmo_debug_object { uint64_t mtime; uint32_t path, source_directory, source_name, first_function, function_count; };
struct xmo_debug_function { uint64_t address, size; uint32_t name, object; };
struct xmo_debug_map {
    const struct xmo_debug_object *objects; const struct xmo_debug_function *functions;
    uint32_t object_count, function_count;
};

/* Bytes of one section in the source: link address, size and where to read. */
struct xmo_range { uint64_t address, size, source_offset; };

struct xmo_image;
/* Header, load commands, segments, sections and dylib names. */
enum xmo_status xmo_load(const struct xmo_source *, const struct xmo_options *, struct xmo_image **);
void xmo_destroy(struct xmo_image *);
const char *xmo_status_name(enum xmo_status);
const struct xmo_info *xmo_info(const struct xmo_image *);
const struct xmo_fat_arch *xmo_fat_arch(const struct xmo_image *, unsigned index);
const struct xmo_segment *xmo_segment(const struct xmo_image *, unsigned index);
const struct xmo_section *xmo_section(const struct xmo_image *, unsigned index);
const struct xmo_dylib *xmo_dylib(const struct xmo_image *, unsigned index);
const struct xmo_section *xmo_find_section(const struct xmo_image *, const char *segment, const char *name);
/* UNAVAILABLE when the section has no bytes in this layout (zero fill in a
 * file, or outside what the source can address). */
enum xmo_status xmo_section_range(const struct xmo_image *, const struct xmo_section *, struct xmo_range *);
/* At most XMO_MAX_CHUNK bytes, inside the section. Not charged to the image's
 * read budget: the consumer brings its own. */
enum xmo_status xmo_read_section(const struct xmo_image *, const struct xmo_section *, uint64_t at, void *, size_t);
/* slide = runtime header address - __TEXT's link address (modulo 2^64). */
enum xmo_status xmo_slide(const struct xmo_image *, uint64_t header_address, uint64_t *slide);

/* The tables below load on first use, each once; a failure is remembered and
 * returned again. Loading reads only the table itself: symbol names are read
 * one page at a time, and only the pages that symbols point into. */
enum xmo_status xmo_symbols(struct xmo_image *, uint32_t *count);
const struct xmo_symbol *xmo_symbol(const struct xmo_image *, uint32_t index);
/* MALFORMED: offset outside the string table or no terminator inside it.
 * LIMIT: longer than XMO_MAX_NAME or than capacity-1. */
enum xmo_status xmo_string(struct xmo_image *, uint32_t strx, char *out, size_t capacity);
/* Exact name, as stored (C names carry a leading underscore). A defined
 * symbol wins over an undefined one of the same name, then table order. */
enum xmo_status xmo_symbol_find(struct xmo_image *, const char *name, const struct xmo_symbol **);
/* The defined symbol at or before a link address, inside the same section.
 * size runs to the next symbol, the next function start or the section end,
 * whichever is first. External symbols win ties. */
enum xmo_status xmo_symbol_at(struct xmo_image *, uint64_t address, const struct xmo_symbol **, uint64_t *size);
/* Background preparation for address labels: builds the address index and
 * retains the bounded string table. Later symbol_at/string calls do no I/O.
 * Missing tables are allowed and retain their ordinary unavailable status. */
enum xmo_status xmo_prepare_labels(struct xmo_image *);
/* Ascending link addresses from LC_FUNCTION_STARTS. */
enum xmo_status xmo_function_starts(struct xmo_image *, const uint64_t **addresses, uint32_t *count);
enum xmo_status xmo_debug_map(struct xmo_image *, struct xmo_debug_map *);
#endif
