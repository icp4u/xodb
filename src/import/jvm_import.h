#ifndef XODB_IMPORT_JVM_H
#define XODB_IMPORT_JVM_H
/* Declared-source JVM stack import (schema draft C06-0). Inputs are exports of an
 * owned HotSpot JVM: `jfr print --json`, `jcmd Thread.dump_to_file -format=json`,
 * `jcmd Thread.print`, and the C06 kotlinx.coroutines probe dump. No native PCs are
 * exported by these sources, so frames never carry one. Android ART and
 * Kotlin/Native are different producers and are rejected, not approximated. */
#include "jvm_budget.h"
#include "logical_frames.h" /* shared C05 reader, src/profile */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#define JVM_SCHEMA "C06-0"
#define JVM_PRODUCER_VERSION "0.1.0"
enum jvm_source {
    JVM_SOURCE_JFR_JSON,
    JVM_SOURCE_THREAD_DUMP_JSON,
    JVM_SOURCE_THREAD_PRINT,
    JVM_SOURCE_COROUTINE_PROBES
};
enum jvm_kind {
    JVM_EXECUTION_SAMPLE,
    JVM_NATIVE_METHOD_SAMPLE,
    JVM_EXCEPTION_THROW,
    JVM_ERROR_THROW,
    JVM_THREAD_START,
    JVM_THREAD_END,
    JVM_VIRTUAL_THREAD_START,
    JVM_VIRTUAL_THREAD_END,
    JVM_THREAD_DUMP_STACK,
    JVM_THREAD_PRINT_STACK,
    JVM_COROUTINE_STACK,
    JVM_KIND_COUNT
};
enum jvm_frame_kind {
    JVM_FRAME_INTERPRETED,
    JVM_FRAME_JIT,
    JVM_FRAME_INLINED,
    JVM_FRAME_NATIVE_METHOD, /* a Java method declared native; not a native C frame */
    JVM_FRAME_UNSPECIFIED,   /* source does not export execution mode */
    JVM_FRAME_UNKNOWN,       /* source exported an unrecognized mode */
    JVM_FRAME_UNAVAILABLE,   /* malformed frame record kept in position */
    JVM_FRAME_COROUTINE_MARKER
};
enum jvm_tri { JVM_NO, JVM_YES, JVM_UNKNOWN };
enum jvm_truncation {
    JVM_TRUNC_NO,
    JVM_TRUNC_SOURCE,
    JVM_TRUNC_UNREPORTED,
    JVM_TRUNC_IMPORTER,
    JVM_TRUNC_EXPORT /* may have been cut by the exporter (jfr print --stack-depth) */
};
enum jvm_name_status { JVM_NAME_OK, JVM_NAME_EMPTY, JVM_NAME_INVALID, JVM_NAME_ABSENT };
/* C05-R3: class-loader identity as exported by the producer. Function identity
 * includes it; an unexported loader is unknown, never assumed shared. */
enum jvm_loader_status {
    JVM_LOADER_NOT_EXPORTED, /* no loader information in the source frame */
    JVM_LOADER_NAMED,        /* loader name (and, for JFR, loader type) exported */
    JVM_LOADER_UNNAMED       /* loader object exported without a name (JFR); type only */
};
/* C05-R5: which identity strings of a frame held NUL and are stored escaped
 * (NUL as \0, backslash as \\). One bit per field, so a NUL in one field never
 * reads the same as a literal "\0" in another. JVM_NUL_CLASS covers the raw and
 * the binary class name (one source string). */
enum jvm_nul_field {
    JVM_NUL_CLASS = 1u << 0,
    JVM_NUL_METHOD = 1u << 1,
    JVM_NUL_DESCRIPTOR = 1u << 2,
    JVM_NUL_LOADER = 1u << 3,
    JVM_NUL_LOADER_TYPE = 1u << 4,
    JVM_NUL_MODULE = 1u << 5,
    JVM_NUL_MODULE_VERSION = 1u << 6
};
/* C05-R3: outcome of converting a source timestamp; the raw text is always kept. */
enum jvm_time_status {
    JVM_TIME_OK,
    JVM_TIME_ABSENT,
    JVM_TIME_MALFORMED,      /* not YYYY-MM-DDTHH:MM:SS[.f]Z|+-HH:MM[:SS] */
    JVM_TIME_UNZONED,        /* no zone: no defined epoch */
    JVM_TIME_INVALID_DATE,   /* month/day not a proleptic Gregorian calendar day */
    JVM_TIME_INVALID_CLOCK,  /* hour/minute/second out of range */
    JVM_TIME_LEAP_SECOND,    /* second 60: not representable as POSIX epoch time */
    JVM_TIME_INVALID_OFFSET, /* offset minutes/seconds >= 60 or |offset| > 18:00 */
    JVM_TIME_PRECISION,      /* more than 9 fraction digits */
    JVM_TIME_OUT_OF_RANGE,   /* valid instant outside signed 64-bit epoch nanoseconds */
    JVM_TIME_STATUS_COUNT
};
struct jvm_limits {
    uint64_t max_bytes, max_records, max_stack_frames, max_total_frames, max_threads;
    uint64_t max_event_bytes; /* JSON arena budget for one record */
    uint32_t max_depth;
    uint32_t jfr_export_depth; /* declared jfr print --stack-depth; 0 = undeclared */
};
struct jvm_strings {
    char *data;
    size_t used, cap;
    size_t *offsets;
    uint32_t count, cap_ids;
    uint32_t *slots;
    uint32_t slot_count;
};
struct jvm_frame {
    uint32_t class_name, raw_class, method, descriptor, module, module_version, loader, file;
    uint32_t raw_kind, raw_text, loader_type;
    int64_t line, bci;
    uint8_t has_line, has_bci, kind, hidden, name_status, heuristic, loader_status;
    uint8_t nul_escaped; /* C05-R5: enum jvm_nul_field bits of the strings stored escaped */
};
#define JVM_THREAD_NAMES 8
struct jvm_thread {
    int64_t java_tid, os_tid;
    uint8_t has_java_tid, has_os_tid, is_virtual, vm_internal, names_truncated;
    uint32_t names[JVM_THREAD_NAMES], name_count, vm_address, group;
    uint64_t records[JVM_KIND_COUNT], first_ordinal, last_ordinal;
};
struct jvm_record {
    uint64_t ordinal, byte_start, byte_end, line_start, line_end;
    uint32_t kind, event_type, thread, name, os_name, state, time_raw, detail, detail2, path;
    int64_t time_ns;
    uint8_t has_time_ns, truncated, has_coroutine_id, has_parent, time_status;
    uint32_t frame_start, frame_count, creation_start, creation_count;
    uint64_t dropped; /* frames past the importer stack budget */
    int64_t coroutine_seq, coroutine_id, parent_seq;
    uint32_t parent_relation;
};
struct jvm_diagnostics {
    uint64_t skipped_events, unknown_frame_kinds, malformed_frames, unnamed_methods;
    uint64_t invalid_method_names, lossy_strings, os_tid_zero, missing_thread, missing_stack;
    uint64_t heuristic_frames, creation_marker_splits, importer_truncated_stacks;
    uint64_t invalid_utf8_lines, nid_mismatch, unparsed_lines, monitor_lines, invalid_numbers;
    uint64_t export_depth_unknown;
    uint64_t nul_escaped_strings, crlf_lines; /* C05-R4 */
};
struct jvm_import {
    enum jvm_source source;
    const char *path;
    char sha256[65];
    uint64_t bytes, records_scanned;
    struct jvm_limits limits;
    struct jvm_strings strings;
    struct jvm_frame *frames;
    uint32_t frame_count, frame_cap, *frame_slots, frame_slot_count;
    uint32_t *stack;
    uint64_t stack_used, stack_cap;
    struct jvm_thread *threads;
    uint32_t thread_count, thread_cap;
    struct jvm_record *records;
    uint64_t record_count, record_cap;
    /* runtime and collection identity; 0 means absent */
    uint32_t jvm_name, jvm_version, runtime_version, jvm_start, jvm_args, java_args, os_version;
    uint32_t collected_at, recording_start, recording_name, dump_header, probe_nano;
    int64_t pid;
    uint8_t has_pid, probes_installed;
    uint8_t collected_status;  /* C05-R4: Thread.print local time status (unzoned or why not) */
    uint8_t alloc_failed;      /* C05-R4: sticky; an allocation failed somewhere in the import */
    uint8_t source_stability;  /* C05-R4: enum xlf_stability of the bytes (jvm_import_file) */
    struct jvm_diagnostics diag;
    const char *incomplete; /* budget/limit reason, NULL when complete */
    char error[256];
    struct jvm_budget *budget;     /* C05-R3: every allocation of this import */
    struct jvm_budget own_budget;  /* used when the caller supplies none */
};
void jvm_limits_default(struct jvm_limits *);
/* 0 ok (possibly incomplete), -1 malformed input, -2 unavailable file, -3 resource
 * failure (memory or whole-operation budget), -4 input over max_bytes, -5 cancelled.
 * On failure *out may hold a partial import with error text (free it). */
int jvm_import_file(const char *path, enum jvm_source, const struct jvm_limits *,
                    struct jvm_import **);
/* C05-R3: import caller bytes (not retained; label is recorded as the path).
 * Every allocation is charged to budget (NULL: a private unlimited budget) and
 * its cancellation object is polled per record/line and per MiB hashed. */
int jvm_import_bytes(const char *text, size_t length, const char *label, enum jvm_source,
                     const struct jvm_limits *, struct jvm_budget *budget, struct jvm_import **);
/* C05-R3: read a regular file once into a budgeted NUL-terminated buffer (free it
 * with jvm_bfree(budget, *out)). Same return codes as jvm_import_file.
 * C05-R4: the read goes through xlf_read_stable (logical_frames.h): a file open
 * for writing, a broken read lease or a detected change is refused (-2); an
 * accepted read is XLF_STABILITY_LEASED or, when no lease was possible,
 * XLF_STABILITY_UNVERIFIED (the bytes may mix versions of the file). */
int jvm_read_source(const char *path, struct jvm_budget *budget, uint64_t max_bytes, char **out,
                    size_t *out_len, char *error, size_t error_size);
int jvm_read_source_labelled(const char *path, struct jvm_budget *budget, uint64_t max_bytes, char **out,
                             size_t *out_len, enum xlf_stability *stability, char *error, size_t error_size);
void jvm_import_free(struct jvm_import *);
const char *jvm_str(const struct jvm_import *, uint32_t);
const char *jvm_kind_name(unsigned);
const char *jvm_frame_kind_name(unsigned);
const char *jvm_source_name(enum jvm_source);
int jvm_parse_kind(const char *, unsigned *);
/* ISO-8601 with zone -> signed epoch ns, with checked arithmetic. Returns
 * JVM_TIME_OK (0) or the reason the text has no representable instant; *out is
 * written only on JVM_TIME_OK. */
int jvm_parse_iso_time(const char *, int64_t *);
const char *jvm_time_status_name(unsigned);
const char *jvm_loader_status_name(unsigned);
/* Output and queries (jvm_query.c). */
struct jvm_query {
    const char *name; /* document, threads, stacks, aggregate, relations */
    unsigned kind;
    int has_kind;
    int64_t java_tid;
    int has_java_tid;
    const char *by; /* top, stack, method */
    uint64_t start, limit, citations;
};
/* Returns 0 ok, 1 when the query is valid but nothing matched, 2 invalid/unsupported. */
int jvm_query_write(FILE *, const struct jvm_import *, const struct jvm_query *);
void jvm_json_string(FILE *, const char *);
void jvm_json_string_n(FILE *, const char *, size_t); /* at most n bytes */
/* C05-1 logical-frames JSONL (jvm_lframes.c): 0 ok, 1 nothing selected, 2 unsupported. */
int jvm_lframes_write(FILE *, const struct jvm_import *, const struct jvm_query *,
                      uint32_t max_frames);
/* C05-R2 composition: emit the C05-1 document into memory and decode it with the
 * shared R2 reader (logical_frames.h). On XLF_OK *out is owned by the caller
 * (xlf_free); on failure *out is NULL and err is filled. Adapter outcomes map to
 * XLF_E_EMPTY (nothing selected), XLF_E_ARGUMENT (kind/source mismatch) and
 * XLF_E_MEMORY (write failure). */
/* Record kind the adapter selects for this query (explicit --kind or the source default). */
unsigned jvm_lframes_kind(const struct jvm_import *im, const struct jvm_query *q);
enum xlf_status jvm_lframes_decode(const struct jvm_import *im, const struct jvm_query *q, uint32_t max_frames,
                                   const struct xlf_limits *limits, const struct xlf_cancel *cancel,
                                   struct xlf_doc **out, struct xlf_error *err);
/* C05-R3: emit the C05-1 document into a buffer charged to im->budget (free with
 * jvm_bfree(im->budget, *text)), polling its cancellation per record and per
 * 64 KiB written. XLF_OK, XLF_E_EMPTY (nothing selected), XLF_E_ARGUMENT (kind
 * does not match the source), XLF_E_MEMORY (budget/allocation) or
 * XLF_E_CANCELLED; err says which phase. jvm_lframes_decode uses it and caps the
 * reader's max_memory at the budget that remains, polling cancel throughout. */
enum xlf_status jvm_lframes_emit(const struct jvm_import *im, const struct jvm_query *q, uint32_t max_frames,
                                 char **text, size_t *length, struct xlf_error *err);
#endif
