#ifndef XODB_LANGUAGE_RUBY_H
#define XODB_LANGUAGE_RUBY_H
#include <elfutils/libdw.h>
#include <stdint.h>
#include <stddef.h>
#define XRB_VERSION "4.1.0"
#define XRB_REVISION "4eed7d64eae2cc5fe072992e5d5da25aaa9d5171"
enum xrb_type {
#define XRB_TYPE(key, name) XRB_T_##key,
#include "ruby_types.inc"
#undef XRB_TYPE
    XRB_TYPE_COUNT
};
enum xrb_field {
#define XRB_FIELD(key, owner, path, kind, width) XRB_##key,
#include "ruby_fields.inc"
#undef XRB_FIELD
    XRB_FIELD_COUNT
};
struct xrb_field_info { uint32_t offset, size; };
struct xrb_layout {
    struct xrb_field_info fields[XRB_FIELD_COUNT];
    uint32_t sizes[XRB_TYPE_COUNT];
    uint8_t build_id[64], build_id_len;
    int succinct_lines;
};
/* Exact development revision plus same-image DWARF offsets, sizes and enums.
 * Caller verifies loaded build-id/version/revision, architecture and stop. */
const char *xrb_layout_build(Dwarf *, const uint8_t *, size_t, const char *, const char *, struct xrb_layout *);
typedef int (*xrb_read_fn)(void *, uint64_t, void *, size_t);
struct xrb_reader { void *context; xrb_read_fn read; size_t reads, bytes; const char *error; };
#define XRB_READ_LIMIT 8192
#define XRB_BYTE_LIMIT (2 * 1024 * 1024)
#define XRB_STACK_FRAMES 128
#define XRB_LOCAL_ITEMS 32
#define XRB_PREVIEW_ITEMS 8
struct xrb_item { uint64_t tagged; char type[24], display[256]; const char *reason; };
struct xrb_value {
    uint64_t tagged, count;
    char type[24], display[512];
    const char *reason;
    int truncated;
    size_t item_count;
    struct xrb_item items[XRB_PREVIEW_ITEMS];
};
struct xrb_frame {
    uint64_t cfp, ep, iseq, pc, self;
    char name[192], file[512], kind[24];
    uint32_t line;
    const char *reason, *line_reason;
};
struct xrb_stack {
    uint64_t ec, thread, stack_lo, stack_hi, cfp;
    size_t count;
    struct xrb_frame frames[XRB_STACK_FRAMES];
    const char *reason;
};
struct xrb_local {
    uint64_t address, tagged;
    size_t ordinal, depth;
    char name[512];
    int hidden, escaped;
    const char *reason;
    struct xrb_value value;
};
struct xrb_locals {
    size_t start, count, total;
    int truncated;
    const char *reason;
    struct xrb_local items[XRB_LOCAL_ITEMS];
};
void xrb_value_read(const struct xrb_layout *, struct xrb_reader *, uint64_t, struct xrb_value *);
/* ec comes only from a proved native rb_vm_exec argument. zjit_entry is the
 * loaded rb_zjit_entry value (not its address). Never call inferior code. */
void xrb_stack_read(const struct xrb_layout *, struct xrb_reader *, uint64_t ec, uint64_t zjit_entry, struct xrb_stack *);
/* Rebuild canonical frames at this stop before inspecting their environment.
 * Locals and outer block captures expire on resume, GC or fiber switches. */
void xrb_locals_read(const struct xrb_layout *, struct xrb_reader *, uint64_t ec,
                     uint64_t zjit_entry, uint64_t symbols, size_t frame,
                     size_t start, size_t limit, struct xrb_locals *);
void xrb_local_find(const struct xrb_layout *, struct xrb_reader *, uint64_t ec,
                    uint64_t zjit_entry, uint64_t symbols, size_t frame,
                    const char *expression, struct xrb_locals *);
/* Complete scalar bytes, separate from the bounded display preview. Strings
 * include their inline encoding index; extended encodings and object previews
 * are unavailable, never compared as complete values. */
#define XRB_SAMPLE_BYTES 4096
struct xrb_sample {
    uint32_t kind;
    size_t size;
    unsigned char bytes[XRB_SAMPLE_BYTES];
    char type[24], display[512];
    const char *reason;
};
void xrb_sample_read(const struct xrb_layout *, struct xrb_reader *, uint64_t,
                     struct xrb_sample *);
int xrb_dwarf_value(Dwarf_Die *);
#endif
