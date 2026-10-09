#ifndef XODB_LANGUAGE_PYTHON_H
#define XODB_LANGUAGE_PYTHON_H
#include <elfutils/libdw.h>
#include <stddef.h>
#include <stdint.h>

/* CPython stopped-memory reader. Offsets come from the runtime's published
 * _Py_DebugOffsets (cookie "xdebugpy") in the identified image, plus a small
 * per-minor-version table for fields CPython does not publish. Only the
 * documented 3.14 final and 3.16 prerelease rules for LP64 little-endian,
 * GIL (not free-threaded) builds are implemented. Prereleases require DWARF
 * from the same image, which must agree with every table entry. */
enum xpy_field {
    /* published in _Py_DebugOffsets */
    XPY_RT_INTERPRETERS,
    XPY_IS_ID,
    XPY_IS_NEXT,
    XPY_IS_THREADS,
    XPY_TS_NEXT,
    XPY_TS_INTERP,
    XPY_TS_FRAME,
    XPY_TS_THREAD_ID,
    XPY_TS_NATIVE_ID,
    XPY_FR_PREVIOUS,
    XPY_FR_EXECUTABLE,
    XPY_FR_INSTR,
    XPY_FR_OWNER,
    XPY_CO_FILENAME,
    XPY_CO_NAME,
    XPY_CO_QUALNAME,
    XPY_CO_LINETABLE,
    XPY_CO_FIRSTLINE,
    XPY_CO_CODE,
    XPY_OB_SIZE_OF, /* sizeof(PyObject) */
    XPY_OB_TYPE,
    XPY_TP_NAME,
    XPY_TP_FLAGS,
    XPY_TUPLE_ITEM,
    XPY_TUPLE_SIZE,
    XPY_LIST_ITEM,
    XPY_LIST_SIZE,
    XPY_SET_USED,
    XPY_DICT_KEYS,
    XPY_DICT_VALUES,
    XPY_FLOAT_VALUE,
    XPY_LONG_TAG,
    XPY_LONG_DIGIT,
    XPY_BYTES_SIZE,
    XPY_BYTES_VALUE,
    XPY_STR_STATE,
    XPY_STR_LENGTH,
    XPY_STR_ASCII_SIZE,
    XPY_FR_LOCALSPLUS,
    XPY_FR_STACKPOINTER,
    XPY_CO_ARGCOUNT,
    XPY_CO_LOCAL_NAMES,
    XPY_CO_LOCAL_KINDS,
    XPY_PUBLISHED_COUNT,
    /* not published: per-version table, DWARF-verified when available */
    XPY_STR_COMPACT_SIZE = XPY_PUBLISHED_COUNT,
    XPY_CO_FLAGS,
    XPY_DICT_USED,
    XPY_DK_LOG2_SIZE,
    XPY_DK_LOG2_INDEX,
    XPY_DK_KIND,
    XPY_DK_NENTRIES,
    XPY_DK_INDICES,
    XPY_DV_VALUES,
    XPY_CELL_VALUE,
    XPY_FIELD_COUNT
};
enum xpy_type {
    XPY_NONE_OBJECT,
    XPY_TRUE_OBJECT,
    XPY_FALSE_OBJECT,
    XPY_TYPE_TYPE,
    XPY_TYPE_NONE,
    XPY_TYPE_BOOL,
    XPY_TYPE_LONG,
    XPY_TYPE_FLOAT,
    XPY_TYPE_UNICODE,
    XPY_TYPE_BYTES,
    XPY_TYPE_TUPLE,
    XPY_TYPE_LIST,
    XPY_TYPE_DICT,
    XPY_TYPE_SET,
    XPY_TYPE_FROZENSET,
    XPY_TYPE_CODE,
    XPY_TYPE_CELL,
    XPY_TYPE_COUNT
};
extern const char *const xpy_type_symbols[XPY_TYPE_COUNT];
struct xpy_layout {
    uint64_t fields[XPY_FIELD_COUNT];
    uint64_t types[XPY_TYPE_COUNT]; /* runtime addresses from the same image */
    uint64_t runtime;               /* runtime address of _PyRuntime */
    uint64_t version;               /* PY_VERSION_HEX published by the runtime */
    uint8_t build_id[64], build_id_len;
    uint8_t dwarf_verified;
};
/* Bytes of _PyRuntime that hold the published offsets; callers compare the
 * loaded copy with the image file before building a layout. */
#define XPY_DEBUG_OFFSETS_BYTES 1024
/* Returns null or a refusal reason. `published` is the loaded copy of the
 * runtime's first XPY_DEBUG_OFFSETS_BYTES; `dwarf` may be null only for a
 * final release whose table is fixed for that minor version. */
const char *xpy_layout_build(const uint8_t *published, size_t published_len, Dwarf *dwarf, const uint8_t *build_id,
                             size_t build_id_len, struct xpy_layout *);
const char *xpy_layout_check(const struct xpy_layout *, const uint8_t *published, size_t published_len,
                             const uint8_t *build_id, size_t build_id_len);
/* Position of each published field inside _Py_DebugOffsets for one minor
 * version, or null. Exposed for header cross-checks in tests. */
const uint16_t *xpy_published_positions(uint64_t version);
extern const uint64_t xpy_unpublished_3_14[XPY_FIELD_COUNT - XPY_PUBLISHED_COUNT];
extern const char *const xpy_field_names[XPY_FIELD_COUNT];

typedef int (*xpy_read_fn)(void *, uint64_t, void *, size_t);
struct xpy_reader {
    void *context;
    xpy_read_fn read; /* zero only for an exact read; never writes the inferior */
    size_t reads, bytes;
    const char *error;
};
#define XPY_MAX_FRAMES 512     /* retained per read */
#define XPY_SEGMENT_FRAMES 128 /* retained per segment */
#define XPY_MAX_EXAMINED 4096
#define XPY_MAX_PREVIEW 8
#define XPY_MAX_THREAD_STATES 8
#define XPY_MAX_RANGES 64

/* Owner values for frames on a thread's chain. Entry frames live on the
 * native C stack of the _PyEval_EvalFrameDefault activation that pushed them. */
enum { XPY_OWNED_BY_THREAD = 0, XPY_OWNED_BY_GENERATOR = 1, XPY_OWNED_BY_FRAME_OBJECT = 2, XPY_OWNED_BY_INTERPRETER = 3, XPY_OWNED_BY_CSTACK = 4 };

struct xpy_frame {
    char name[256], file[1024];
    uint32_t line, code_flags;
    uint64_t address, code, instr;
    uint8_t owner;
    uint8_t identity_proved; /* validated executable code object */
    const char *reason;
};
/* Native interpreter activations on one stopped thread, innermost first:
 * [sp, cfa) of each _PyEval_EvalFrameDefault frame. */
struct xpy_range {
    uint64_t low, high;
};
struct xpy_segment {
    uint64_t thread_state, interpreter, interpreter_id;
    int32_t anchor;          /* index into ranges, -1 when unanchored */
    uint64_t entry_frame;    /* boundary frame proving the anchor */
    size_t first, count;     /* slice of xpy_stack.frames */
    size_t examined;         /* frames examined, including unretained */
    int skipped;             /* anchored before `first`: frames not retained */
    int chain_complete;      /* entire thread-state chain walked and retained */
    const char *reason;      /* null means complete */
};
struct xpy_stack {
    struct xpy_frame frames[XPY_MAX_FRAMES];
    size_t count;
    struct xpy_segment segments[XPY_MAX_RANGES + XPY_MAX_THREAD_STATES];
    size_t segment_count, thread_states;
    uint8_t entry_found[XPY_MAX_RANGES]; /* an entry frame proved range k */
    const char *reason; /* whole-read failure; per-segment reasons otherwise */
};
/* Caller keeps the entire process stopped for the duration of each operation.
 * Every traversal is bounded, including corrupt linked lists and strings. */
/* Segments anchored at a range index below `first` keep their place but
 * retain no frames, so they do not spend the frame budget. */
void xpy_stack_read(const struct xpy_layout *, struct xpy_reader *, uint32_t tid, const struct xpy_range *ranges,
                    size_t range_count, size_t first, struct xpy_stack *);
/* Line for a code-unit index from a 3.11+ location table; -1 when absent. */
int xpy_line_for(const uint8_t *table, size_t n, int first_line, uint64_t unit, int *line);

struct xpy_value_item {
    uint64_t address;
    char key[96], type[32], display[192];
    const char *reason;
};
struct xpy_value {
    uint64_t address, type_object, count;
    uint64_t refcount;
    int immortal, truncated;
    char type[64], display[320];
    const char *reason;
    size_t item_count;
    struct xpy_value_item items[XPY_MAX_PREVIEW];
};
void xpy_value_read(const struct xpy_layout *, struct xpy_reader *, uint64_t, struct xpy_value *);

/* Complete canonical samples for stopped-value comparison. Display previews
 * are never equality evidence. Exact builtin scalars only; subclasses and
 * containers are refused. Integers use sign plus little-endian base-2^30
 * digits, str uses little-endian Unicode code points (including surrogates),
 * floats preserve IEEE bits, and bytes preserves all bytes. */
#define XPY_SAMPLE_BYTES 4096
enum xpy_sample_kind { XPY_SAMPLE_NONE, XPY_SAMPLE_BOOL, XPY_SAMPLE_INT,
                       XPY_SAMPLE_FLOAT, XPY_SAMPLE_STR, XPY_SAMPLE_BYTES_KIND };
const char *xpy_value_sample(const struct xpy_layout *, struct xpy_reader *, uint64_t,
                             void *, size_t capacity, size_t *length, enum xpy_sample_kind *);

#define XPY_MAX_LOCALS 4096
#define XPY_LOCAL_PAGE 32
enum xpy_local_scope { XPY_LOCAL, XPY_PARAMETER, XPY_CELL, XPY_FREE };
struct xpy_local {
    char name[512];
    const char *name_reason, *reason;
    size_t ordinal;
    enum xpy_local_scope scope;
    uint64_t slot_address, address;
    int hidden, immediate;
    int64_t immediate_integer;
    struct xpy_value value;
};
struct xpy_locals {
    uint64_t frame, code;
    size_t start, total, count;
    int truncated;
    const char *reason;
    struct xpy_local items[XPY_LOCAL_PAGE];
};
/* The caller supplies a frame/code pair from the retained canonical stack,
 * never from a client address. Mapping locals and arbitrary expressions are
 * refused. Unbound slots keep their name and reason, without an object address. */
void xpy_locals_read(const struct xpy_layout *, struct xpy_reader *, uint64_t frame, uint64_t code,
                     size_t start, size_t limit, struct xpy_locals *);
/* A local/upvalue name followed by at most four [int32] or quoted ASCII-key
 * selectors (128 bytes total). Exact builtin dict/list/tuple storage only;
 * no subclasses, attributes, callbacks or implicit globals. */
#define XPY_PATH_DEPTH 4
#define XPY_PATH_ENTRIES 128
/* Pure syntax/bounds check; no target reads. Resolution can still be unavailable. */
int xpy_expression_valid(const char *);
void xpy_local_find(const struct xpy_layout *, struct xpy_reader *, uint64_t frame, uint64_t code,
                    const char *name, struct xpy_locals *);
/* Use a row just resolved in this stopped generation, never a saved slot.
 * Immediate stackrefs and boxed integers produce the same canonical bytes. */
const char *xpy_local_sample(const struct xpy_layout *, struct xpy_reader *, const struct xpy_local *,
                             void *, size_t capacity, size_t *length, enum xpy_sample_kind *);
#endif
