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
    XPL_BLESS_STASH,
    XPL_COPSEQ,
    XPL_SUBDEPTH,
    XPL_CVDEPTH,
    XPL_CVPADLIST,
    XPL_PADMAX,
    XPL_PADARRAY,
    XPL_NAMESFILL,
    XPL_NAMESMAX,
    XPL_NAMESARRAY,
    XPL_NAMEPV,
    XPL_NAMELEN,
    XPL_NAMEFLAGS,
    XPL_NAMEOUR,
    XPL_NAMELOW,
    XPL_NAMEHIGH,
    XPL_HEKHASH,
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
    uint64_t cv, context_address, cop;
    /* cxstack can move; stackinfo/index locates its current entry. This is a
     * location identity, not proof of an activation surviving between stops. */
    uint64_t stackinfo, context_index;
    int identity_proved;
    const char *reason;
};
struct xpl_stack {
    struct xpl_frame frames[XPL_MAX_FRAMES];
    size_t count;
    uint64_t interpreter, op, stackinfo;
    int chain_complete; /* separate structural completion from display errors */
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
    char class_name[256]; /* verified stash name; referent's class for an RV */
    uint8_t bytes[128];
    size_t byte_count, item_count;
    int truncated, stored_value_only, utf8;
    const char *reason;
    struct xpl_value_item items[XPL_MAX_PREVIEW];
};
void xpl_value_read(const struct xpl_layout *, struct xpl_reader *, uint64_t, struct xpl_value *);
#define XPL_MAX_LOCALS 32
#define XPL_MAX_PAD_SLOTS 4096
#define XPL_MAX_PAD_NAMES 512
enum xpl_local_scope { XPL_LOCAL, XPL_OUTER, XPL_STATE };
struct xpl_local {
    uint64_t ordinal, slot_address, sv;
    enum xpl_local_scope scope;
    char name[256];
    const char *reason;
    struct xpl_value value;
};
struct xpl_locals {
    uint64_t interpreter, context_address, cv, pad, sequence;
    uint32_t depth;
    size_t frame, start, total, count;
    int truncated;
    const char *reason;
    struct xpl_local items[XPL_MAX_LOCALS];
};
/* Select by a canonical retained context ordinal, never by a caller-provided
 * CV/pad address. Expressions support ASCII lexical names and bounded raw
 * builtin hash/array paths; no target calls or implicit autovivification. */
void xpl_locals_read(const struct xpl_layout *, struct xpl_reader *, uint64_t interpreter,
                     size_t frame, size_t start, size_t limit, struct xpl_locals *);
void xpl_local_find(const struct xpl_layout *, struct xpl_reader *, uint64_t interpreter,
                    size_t frame, const char *name, struct xpl_locals *);
const char *xpl_expression_check(const char *);
/* Bare container names remain valid for previews, but not scalar watches. */
const char *xpl_watch_expression_check(const char *);
/* Resolve from an already selected lexical SV. Used by the pad reader and by
 * independent runtime-oracle tests. Missing entries are explicit refusals. */
struct xpl_path_value { uint64_t sv, slot; const char *reason; };
void xpl_path_read(const struct xpl_layout *, struct xpl_reader *, uint64_t root,
                   const char *expression, struct xpl_path_value *);
/* A retained declaration remains that ordinal even while a same-named inner
 * declaration is visible. Its name is exact declared bytes, not an expression;
 * Unicode names are allowed. Inactive or mismatched declarations are refused. */
void xpl_local_binding(const struct xpl_layout *, struct xpl_reader *, uint64_t interpreter,
                       size_t frame, uint64_t ordinal, const char *name, struct xpl_locals *);
#define XPL_SAMPLE_BYTES 4096
enum xpl_sample_kind { XPL_SAMPLE_UNDEF = 0, XPL_SAMPLE_IV = 1, XPL_SAMPLE_NV = 2,
                       XPL_SAMPLE_PV = 4, XPL_SAMPLE_UNSIGNED = 8 };
struct xpl_sample {
    uint32_t kind;
    size_t size;
    uint8_t bytes[XPL_SAMPLE_BYTES];
    char type[32], display[256];
    const char *reason;
};
/* Complete stored scalar representations, not Perl eq/== or coercion. Public
 * IOK/NOK/POK bits all contribute (dualvars included); cache/validity changes
 * are observable. PV is canonical LE32 characters, with byte PV as Latin-1.
 * Magic, references, containers and non-Unicode UTF-8 are refused. */
void xpl_sample_read(const struct xpl_layout *, struct xpl_reader *, uint64_t sv,
                     struct xpl_sample *);
#endif
