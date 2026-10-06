#ifndef XODB_IMPORT_JVM_EVIDENCE_H
#define XODB_IMPORT_JVM_EVIDENCE_H
/* C05-R3: owned JVM evidence bundle, the C entry point for integration.
 *
 * One call reads a declared JVM export once, imports it, adapts the selected
 * record kind to a C05-1 logical-frame document and decodes that with the shared
 * C05 reader. The bundle owns, immutably and until jvm_evidence_free:
 *   - the original source bytes (never re-read from the path, so citations still
 *     resolve after the file is changed or deleted) and their SHA-256;
 *   - the typed import (records, frames, threads, coroutine relations, times with
 *     raw text and status), which keeps the distinctions C05 kinds cannot carry:
 *     heuristic text parsing, JIT inlining, Java methods declared native (no
 *     machine PC and no native unwind/control authority), loader identity,
 *     virtual threads and coroutine creation/parent evidence;
 *   - the exact C05-1 bytes that were decoded (xlf_cite offsets index them);
 *   - the decoded xlf_doc.
 * Every byte of that work (source copy, importer and JSON scratch, adapter maps,
 * emitted document, reader decode peak and retained document) is charged to one
 * whole-operation budget; the call is refused (XLF_E_MEMORY) rather than exceed
 * it. The cancellation object is polled before any work, per MiB read and
 * hashed, per record/line imported, per record adapted, per 64 KiB emitted and
 * at the reader's own poll points.
 *
 * Lifetime: everything returned by an accessor (pointers, strings, the document)
 * is owned by the bundle and valid until jvm_evidence_free. A bundle is
 * immutable after creation; accessors and jvm_evidence_aggregate may run
 * concurrently. Not thread-safe against jvm_evidence_free.
 *
 * C05-R4: hosts use only the declarations in this header. struct jvm_import
 * (jvm_import.h, included for its enums and struct jvm_limits) is internal and
 * may change with any revision; the bundle's import state is reached only
 * through jvm_evidence_info and the typed accessors below.
 *
 * C05-R5: this is a source-level API for code built with this tree, not a
 * stable ABI. The structs here grow (fields are appended), jvm_evidence_info
 * embeds struct jvm_diagnostics by value and this header includes
 * jvm_import.h, so a host must be recompiled with the importer it links. */
#include "jvm_import.h"
#include <stdbool.h>

struct jvm_evidence;

struct jvm_evidence_limits {
    size_t max_total_bytes;   /* whole operation (see above); 0 = unlimited */
    struct jvm_limits import; /* per-source importer limits */
    struct xlf_limits reader; /* C05 decode limits; max_memory is further capped by what remains */
    uint32_t max_frames;      /* adapter frames per stack (C05 default 4096) */
};
void jvm_evidence_default_limits(struct jvm_evidence_limits *);

/* Memory by phase. Every figure counts the bundle's own budget, which already
 * includes the retained source copy; whole_peak is the maximum, over the whole
 * operation, of all live charged bytes (importer + adapter + emission + the
 * reader's decode peak on top of what was live when decode started). */
struct jvm_evidence_usage {
    size_t source_bytes;   /* retained immutable source copy (charged with header) */
    size_t import_peak;    /* peak while reading and importing */
    size_t adapt_peak;     /* peak while building maps and emitting */
    size_t lframes_bytes;  /* retained emitted C05-1 document */
    size_t decode_peak;    /* the C05 reader's own decode peak */
    size_t whole_peak;     /* peak of the whole operation */
    size_t retained_bytes; /* held by the bundle until jvm_evidence_free */
    size_t limit;          /* max_total_bytes (0 = unlimited) */
};

/* C05-R4: what the import established about the source, by value (strings are
 * owned by the bundle; NULL when the source did not export the field). */
struct jvm_evidence_info {
    enum jvm_source source;
    const char *label;                 /* path or caller label */
    const char *sha256_hex;            /* of the retained source bytes */
    uint64_t source_bytes;
    enum xlf_stability stability;      /* file sources: leased or unverified; bytes: caller_bytes */
    const char *incomplete;            /* importer budget/limit reason, NULL when the import is complete */
    uint64_t records_scanned, records, threads, frames;
    bool has_pid;
    int64_t pid;
    const char *jvm_name, *jvm_version, *runtime_version, *jvm_start, *os_version;
    const char *collected_at;          /* raw collection time text (dump/probe/Thread.print) */
    enum jvm_time_status collected_status;
    const char *recording_start, *recording_name;
    bool probes_installed;
    struct jvm_diagnostics diagnostics; /* counts of what was skipped, repaired or labelled */
};
void jvm_evidence_info(const struct jvm_evidence *, struct jvm_evidence_info *);

/* Selection: q->kind/has_kind and q->java_tid/has_java_tid as for
 * jvm_lframes_write (other members ignored); q may be NULL for the source's
 * default kind. Returns XLF_OK and *out, or a status with err->message prefixed
 * by the failing phase ("read:", "import:", "adapt:", "decode:", "index:"):
 * XLF_E_IO unavailable/non-regular/changed file, XLF_E_LIMIT input over
 * import.max_bytes, XLF_E_SCHEMA malformed source, XLF_E_MEMORY budget or
 * allocation, XLF_E_CANCELLED, XLF_E_EMPTY nothing selected, XLF_E_ARGUMENT kind
 * does not match the source, or any C05 reader status. err->peak_bytes is the
 * whole-operation peak. Nothing is retained on failure. */
enum xlf_status jvm_evidence_import(const char *path, enum jvm_source source, const struct jvm_query *q,
                                    const struct jvm_evidence_limits *limits, const struct xlf_cancel *cancel,
                                    struct jvm_evidence **out, struct xlf_error *err);
/* As above from caller bytes, which are copied (and charged) before anything else. */
enum xlf_status jvm_evidence_import_bytes(const void *bytes, size_t length, const char *label,
                                          enum jvm_source source, const struct jvm_query *q,
                                          const struct jvm_evidence_limits *limits,
                                          const struct xlf_cancel *cancel, struct jvm_evidence **out,
                                          struct xlf_error *err);
void jvm_evidence_free(struct jvm_evidence *);

const struct xlf_doc *jvm_evidence_doc(const struct jvm_evidence *);
const uint8_t *jvm_evidence_source(const struct jvm_evidence *, size_t *length, const char **sha256_hex);
const char *jvm_evidence_lframes(const struct jvm_evidence *, size_t *length);
void jvm_evidence_usage(const struct jvm_evidence *, struct jvm_evidence_usage *);

/* Typed evidence for one document frame (index into doc->frames). */
struct jvm_evidence_frame {
    uint32_t jvm_frame;          /* index into the import's frames */
    enum jvm_frame_kind mode;    /* execution mode as exported (interpreted, jit, inlined, native method, ...) */
    bool heuristic_text;         /* parsed from StackTraceElement-style text */
    bool inlined;                /* JFR "Inlined" */
    bool jvm_native_method;      /* a Java method declared native: not a native machine frame */
    bool native_authority;       /* always false: no PC, never native unwind/control evidence */
    bool marker;                 /* emitted as a C05 marker frame (no function) */
    bool has_line, has_bci;
    int64_t line, bci;
    enum jvm_loader_status loader_status;
    const char *class_name, *method, *descriptor, *class_loader, *class_loader_type, *module, *module_version;
    const char *file, *raw_text; /* raw_text: text frames only */
    /* C05-R5: the rest of the function identity. raw_class is the class name as
     * exported (p/C, or an already dotted p.C; class_name is the binary name of
     * either). nul_escaped holds enum jvm_nul_field bits: a field whose bit is
     * set contained NUL and is shown with NUL as \0 and backslash as \\; a field
     * without its bit is the exported text unchanged. Two frames are the same
     * function only if mode (as a C05 frame kind), class_name, raw_class,
     * method, descriptor, loader_status, class_loader, class_loader_type,
     * module, module_version and nul_escaped all agree. */
    const char *raw_class;
    uint8_t nul_escaped;
};
/* Typed evidence for one document stack (index into doc->stacks). */
struct jvm_evidence_stack {
    uint32_t record;          /* index into the import's records */
    uint64_t ordinal;         /* source event / thread / coroutine ordinal */
    uint64_t source_offset, source_length; /* cited span of the retained source bytes */
    uint64_t line_start, line_end;         /* Thread.print only; else 0 */
    const char *path;                      /* JSON path when the source has one, else NULL */
    const char *time_raw;                  /* exact source text, NULL if absent */
    enum jvm_time_status time_status;
    bool has_time_ns;
    int64_t time_ns;                       /* signed epoch ns (JFR wall clock), valid if has_time_ns */
    enum jvm_truncation truncation;
    uint32_t creation_count;               /* coroutine creation frames (context, not callers) */
};
enum jvm_evidence_thread_kind { JVM_EVIDENCE_PLATFORM_OR_VIRTUAL, JVM_EVIDENCE_COROUTINE, JVM_EVIDENCE_NO_THREAD };
/* Typed evidence for one document thread (index into doc->threads). */
struct jvm_evidence_thread {
    enum jvm_evidence_thread_kind what;
    uint32_t thread;            /* import thread (or a coroutine's last thread); UINT32_MAX if none */
    enum jvm_tri is_virtual;    /* unknown stays unknown */
    bool vm_internal, has_java_tid, has_os_tid;
    int64_t java_tid, os_tid;
    /* coroutines */
    uint32_t record;            /* import record of the coroutine, UINT32_MAX otherwise */
    int64_t coroutine_seq;
    bool has_parent;
    int64_t parent_seq;
    uint32_t parent_doc_thread; /* doc thread of the parent coroutine, XLF_NONE when not in this document */
    const char *parent_relation, *state;
};
int jvm_evidence_frame(const struct jvm_evidence *, uint32_t doc_frame, struct jvm_evidence_frame *);
int jvm_evidence_stack(const struct jvm_evidence *, uint32_t doc_stack, struct jvm_evidence_stack *);
int jvm_evidence_thread(const struct jvm_evidence *, uint32_t doc_thread, struct jvm_evidence_thread *);
/* The frame evidence of a function's representative frame (identity fields are
 * equal for every frame of the function). */
int jvm_evidence_function(const struct jvm_evidence *, uint32_t doc_function, struct jvm_evidence_frame *);
/* The exact retained source bytes a stack came from (0 ok, -1 index, -2 not localized). */
int jvm_evidence_cite(const struct jvm_evidence *, uint32_t doc_stack, const uint8_t **bytes, size_t *length);
/* xlf_aggregate bounded by the bundle. C05-R4: concurrent calls share what the
 * whole-operation budget has left after the bundle: each call atomically
 * reserves min(reader default query limit, unreserved remainder) before it
 * runs and returns the reservation when it ends, so the reservations of
 * concurrent queries never sum to more than the remainder. A call that finds
 * nothing unreserved is refused with XLF_E_MEMORY ("reserved by concurrent
 * queries" or "fully retained by the bundle") unless the document has no
 * functions (such a query allocates nothing). The returned aggregate is owned
 * by the caller after return and is outside the bundle's accounting. */
enum xlf_status jvm_evidence_aggregate(const struct jvm_evidence *, uint32_t thread, const struct xlf_cancel *,
                                       struct xlf_aggregate *, struct xlf_error *);
#endif
