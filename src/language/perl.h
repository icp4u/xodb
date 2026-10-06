#ifndef XODB_LANGUAGE_PERL_H
#define XODB_LANGUAGE_PERL_H
#include <elfutils/libdw.h>
#include <stddef.h>
#include <stdint.h>

/* Offsets come from the identified image's DWARF. Only the documented Perl
 * 5.44.0, LP64, little-endian, threaded macro rules are implemented. */
enum xpl_field {
    XPL_CURCOP,
    XPL_STACKINFO,
    XPL_MAINCV,
    XPL_OP,
    XPL_CXSTACK,
    XPL_SIPREV,
    XPL_CXIX,
    XPL_CXMAX,
    XPL_SITYPE,
    XPL_CXTYPE,
    XPL_OLDCOP,
    XPL_SUBCV,
    XPL_EVALCV,
    XPL_EVALOP,
    XPL_COPLINE,
    XPL_COPFILE,
    XPL_ANY,
    XPL_REFCNT,
    XPL_FLAGS,
    XPL_UNION,
    XPL_PVCUR,
    XPL_PVLEN,
    XPL_IV,
    XPL_NV,
    XPL_AVFILL,
    XPL_AVMAX,
    XPL_HVKEYS,
    XPL_HVMAX,
    XPL_CVSTASH,
    XPL_CVNAME,
    XPL_CVFLAGS,
    XPL_CVFILE,
    XPL_GVNAME,
    XPL_GVSTASH,
    XPL_HVAUX,
    XPL_HVNAME,
    XPL_HVNAMECOUNT,
    XPL_HEKLEN,
    XPL_HEKKEY,
    XPL_HENEXT,
    XPL_HEKEY,
    XPL_HEVAL,
    XPL_FIELD_COUNT
};
struct xpl_field_info {
    uint32_t offset, size;
};
struct xpl_layout {
    struct xpl_field_info fields[XPL_FIELD_COUNT];
    uint32_t context_size;
    uint8_t build_id[64], build_id_len;
    uint8_t version[3];
};
/* Both profile and target identities must be supplied; mismatch is a refusal. */
const char *xpl_layout_build(Dwarf *, const uint8_t *build_id, size_t build_id_len, const uint8_t version[3],
                             struct xpl_layout *);
const char *xpl_layout_check(const struct xpl_layout *, const uint8_t *, size_t, const uint8_t version[3]);

typedef int (*xpl_read_fn)(void *, uint64_t, void *, size_t);
struct xpl_reader {
    void *context;
    xpl_read_fn read; /* zero only for an exact read; never writes the inferior */
    size_t reads, bytes;
    const char *error;
};
#define XPL_MAX_FRAMES 128
#define XPL_MAX_PREVIEW 8
struct xpl_frame {
    char name[256], file[1024];
    uint32_t line, context_type;
    uint64_t cv, context_address;
    const char *reason;
};
struct xpl_stack {
    struct xpl_frame frames[XPL_MAX_FRAMES];
    size_t count;
    uint64_t interpreter, op, stackinfo;
    const char *reason; /* null means the bounded walk reached its root */
};
/* Caller keeps the entire process stopped for the duration of each operation.
 * Every traversal is bounded, including corrupt linked lists and strings. */
void xpl_stack_read(const struct xpl_layout *, struct xpl_reader *, uint64_t, struct xpl_stack *);
struct xpl_value_item {
    uint64_t address;
    char key[80], type[16], display[192];
    const char *reason;
};
struct xpl_value {
    uint64_t address, body, count;
    uint32_t flags, refcount;
    char type[16], display[256];
    uint8_t bytes[128];
    size_t byte_count, item_count;
    int truncated, stored_value_only, utf8;
    const char *reason;
    struct xpl_value_item items[XPL_MAX_PREVIEW];
};
void xpl_value_read(const struct xpl_layout *, struct xpl_reader *, uint64_t, struct xpl_value *);
#endif
