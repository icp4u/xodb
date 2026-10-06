#ifndef XODB_JITMAP_H
#define XODB_JITMAP_H
#include <stddef.h>
#include <stdint.h>

/* Time-aware JIT code attribution, draft model "xodb-jit-code-lifetime/3".
 *
 * Host-side analysis only: no target control, no allocation in the target.
 * Every add and resolve call has a deterministic work budget, a memory
 * budget that includes index and scratch storage, and optional cancellation
 * (see C07-R2 CONTRACT). A query's index search costs O(log^2 versions)
 * regardless of how many versions overlap the address or share a timestamp.
 * Classifying the at most 16 candidates found adds at most 15 comparisons;
 * each charges floor(n / 4096) units per compared n-byte string (perf-map
 * names; jitdump names, code, unwinding data, debug file names) plus
 * 1 + debug entries for a jitdump pair. The total is O(log^2 versions) plus
 * at most 15 times the largest per-version comparison cost (C07-R4 CONTRACT
 * v4 section 2), so long names raise it linearly in compared bytes / 4096.
 * A model holds immutable copies of jitdump and perf-map inputs, decoded into
 * code versions. A version is one code object at one address interval with
 * begin/end evidence; a move or address reuse always creates a new version.
 *
 * Absent end evidence means "not observed to end", never "valid forever".
 * Jitdump has no unload record. Perf maps are untimed and never resolve
 * confidently. Unknown process incarnation or clock relation stays unknown.
 * Candidates from separate sources name one code object only when every
 * identity, content and lifetime fact agrees (C07-R3 CONTRACT v3 section 5);
 * an equal address range and name are never enough. */

#define XODB_JIT_MODEL_VERSION "xodb-jit-code-lifetime/3"
#define XODB_JIT_MAX_CANDIDATES 16

enum xodb_jit_error {
    XODB_JIT_OK = 0,
    XODB_JIT_E_NOMEM = -1,
    XODB_JIT_E_BUDGET = -2,      /* input/record/memory budget exhausted; source partial */
    XODB_JIT_E_MAGIC = -3,       /* not a jitdump in either byte order */
    XODB_JIT_E_VERSION = -4,     /* unsupported jitdump version */
    XODB_JIT_E_HEADER = -5,      /* truncated or inconsistent file header */
    XODB_JIT_E_FLAGS = -6,       /* reserved header flag bits set */
    XODB_JIT_E_IDENTITY = -7,    /* header pid contradicts declared incarnation */
    XODB_JIT_E_CLOCK = -8,       /* declared domain contradicts header clock mode */
    XODB_JIT_E_ARGUMENT = -9,
    XODB_JIT_E_WORK = -10,       /* work limit reached; add rolled back / query incomplete */
    XODB_JIT_E_CANCELLED = -11,  /* cancellation observed; add rolled back / query incomplete */
};

/* Process incarnation. pid alone is not an identity: start_ticks (proc stat
 * field 22) and boot_id complete it. known=0 means only pid is asserted. */
struct xodb_jit_process {
    uint32_t pid;
    int known;
    uint64_t start_ticks;
    uint8_t boot_id[16];
};

enum xodb_jit_clock_kind {
    XODB_JIT_CLOCK_UNKNOWN = 0,
    XODB_JIT_CLOCK_MONOTONIC = 1, /* CLOCK_MONOTONIC ns of one boot and time namespace */
    XODB_JIT_CLOCK_ARCH = 2,      /* raw architecture counter ticks (e.g. x86 TSC) */
    XODB_JIT_CLOCK_OTHER = 3,     /* caller-named domain; compared by scope only */
};

/* Two domains compare only when both kinds match, neither is UNKNOWN and
 * both scopes are known and equal (e.g. hash of boot_id + time namespace). */
struct xodb_jit_clock {
    uint32_t kind;
    int scope_known;
    uint8_t scope[16];
};

enum xodb_jit_map_method {
    XODB_JIT_MAP_NONE = 0,
    XODB_JIT_MAP_OFFSET = 1,    /* to = from + offset */
    XODB_JIT_MAP_PERF_TSC = 2,  /* perf time_conv: zero + (from>>shift)*mult + (((from&mask)*mult)>>shift) */
};

/* Declared or measured mapping from a source's clock into another domain.
 * uncertainty is in target units and widens every lifetime boundary. */
struct xodb_jit_clock_map {
    uint32_t method;
    struct xodb_jit_clock target;
    int64_t offset;
    uint32_t mult;
    uint16_t shift;
    uint64_t zero;
    uint64_t uncertainty;
    const char *measured_by; /* provenance text, copied */
};

enum xodb_jit_source_kind { XODB_JIT_SOURCE_JITDUMP = 1, XODB_JIT_SOURCE_PERFMAP = 2 };

/* Externally supplied facts about an input. Nothing here is inferred from
 * file names. coverage_end bounds the period in which the source would have
 * reported new code (file read time or producer exit); without it, coverage
 * ends at the last decoded record (jitdump) or is absent (perf map). */
struct xodb_jit_source_meta {
    struct xodb_jit_process process;
    struct xodb_jit_clock clock;          /* domain of record/snapshot timestamps */
    struct xodb_jit_clock_map map;        /* optional source -> query domain */
    int has_coverage_end;
    uint64_t coverage_end;                /* in source clock */
    const char *artifact_sha256;          /* hex, copied; optional */
    const char *label;                    /* provenance text, copied; optional */
    uint64_t slack;                       /* declared producer timestamp skew, source units */
    int header_time_in_clock;             /* header timestamp declared to use the record clock;
                                           * CPython 3.14 writes CLOCK_REALTIME microseconds there */
    uint64_t debug_address_bias;          /* declared producer bias subtracted from debug entry
                                           * addresses (0: absolute, as perf inject reads them;
                                           * V8 output observed consistent with 0x40) */
};

struct xodb_jit_limits {
    size_t max_input_bytes;
    size_t max_records;
    size_t max_versions;
    size_t max_debug_entries;
    size_t max_name_bytes;
    size_t max_line_bytes;     /* perf map */
    size_t max_diagnostics;
    size_t max_memory_bytes;   /* model total allocation budget, index and scratch included */
    uint64_t max_prepare_work; /* work units per add call (decode, build, index) */
    uint64_t max_query_work;   /* work units per resolve call */
};

/* Cancellation token. Access it only through xodb_jit_cancel_*: they use
 * __atomic release/acquire operations, so any thread may request
 * cancellation while another thread runs an add or resolve call. */
struct xodb_jit_cancel {
    uint32_t requested;
};

enum xodb_jit_stop {
    XODB_JIT_STOP_NONE = 0,
    XODB_JIT_STOP_WORK = 1,
    XODB_JIT_STOP_CANCELLED = 2,
};

/* Per-call control. work_limit 0 uses the model limit; a nonzero value can
 * only lower it. Outputs are written on every return. */
struct xodb_jit_control {
    uint64_t work_limit;
    const struct xodb_jit_cancel *cancel;
    uint64_t work;        /* out: units charged */
    size_t memory_peak;   /* out: peak model->memory during the call */
    uint32_t stop;        /* out: enum xodb_jit_stop */
};

/* Jitdump record ids (format version 1). */
enum xodb_jit_record_kind {
    XODB_JIT_REC_LOAD = 0,
    XODB_JIT_REC_MOVE = 1,
    XODB_JIT_REC_DEBUG_INFO = 2,
    XODB_JIT_REC_CLOSE = 3,
    XODB_JIT_REC_UNWINDING_INFO = 4,
    XODB_JIT_REC_PERFMAP_LINE = 100, /* not a jitdump id */
};

enum xodb_jit_diag_code {
    XODB_JIT_D_TRUNCATED_RECORD = 1,   /* record extends past input end; decoding stopped */
    XODB_JIT_D_RECORD_TOO_SMALL,       /* total_size below record minimum; decoding stopped if < 16 */
    XODB_JIT_D_UNKNOWN_RECORD,         /* preserved byte range, not decoded */
    XODB_JIT_D_NAME_UNTERMINATED,
    XODB_JIT_D_NAME_TOO_LONG,
    XODB_JIT_D_RANGE_WRAPS,
    XODB_JIT_D_ZERO_SIZE,
    XODB_JIT_D_CODE_BYTES_SIZE,        /* load total_size disagrees with name + code_size */
    XODB_JIT_D_FOREIGN_PID,            /* record pid differs from header pid; excluded */
    XODB_JIT_D_MOVE_UNKNOWN_INDEX,     /* no live version for code_index; orphan version */
    XODB_JIT_D_MOVE_ADDRESS_MISMATCH,  /* old_code_addr differs from live version */
    XODB_JIT_D_MOVE_SIZE_MISMATCH,
    XODB_JIT_D_MOVE_AMBIGUOUS_INDEX,   /* several live versions share code_index */
    XODB_JIT_D_DUPLICATE_INDEX,        /* load reuses a live code_index */
    XODB_JIT_D_DEBUG_UNMATCHED,        /* debug info not followed by a load of its code_addr */
    XODB_JIT_D_DEBUG_MALFORMED,
    XODB_JIT_D_DEBUG_OUT_OF_RANGE,     /* entry address outside its code range */
    XODB_JIT_D_UNWIND_UNMATCHED,
    XODB_JIT_D_UNWIND_MALFORMED,
    XODB_JIT_D_OUT_OF_ORDER,           /* timestamp decreases in file order */
    XODB_JIT_D_AFTER_CLOSE,            /* record after CODE_CLOSE */
    XODB_JIT_D_HEADER_EXTRA,           /* header total_size larger than known fields */
    XODB_JIT_D_VMA_DIFFERS,            /* vma != code_addr; code_addr used */
    XODB_JIT_D_TRAILING_BYTES,         /* bytes after decoded content within total_size */
    XODB_JIT_D_LINE_MALFORMED,         /* perf map: fields */
    XODB_JIT_D_LINE_TOO_LONG,
    XODB_JIT_D_LINE_UNTERMINATED,      /* final line without newline; rejected */
    XODB_JIT_D_HEX_OVERFLOW,
    XODB_JIT_D_NAME_NOT_UTF8,          /* preserved bytes */
    XODB_JIT_D_BUDGET,                 /* decoding stopped by a limit */
    XODB_JIT_D_TIME_ZERO,              /* record timestamp 0; treated as present */
};

struct xodb_jit_diag {
    uint32_t source;
    uint32_t code;
    uint64_t ordinal;   /* record ordinal (jitdump) or 1-based line number (perf map) */
    uint64_t offset;    /* byte offset in source input */
    uint64_t value;     /* code-specific detail (e.g. code_index, record id) */
};

/* Evidence for a lifetime boundary. */
enum xodb_jit_bound_kind {
    XODB_JIT_BOUND_NONE = 0,      /* not observed */
    XODB_JIT_BOUND_LOAD = 1,      /* begin: JIT_CODE_LOAD */
    XODB_JIT_BOUND_MOVE_IN = 2,   /* begin: JIT_CODE_MOVE new address */
    XODB_JIT_BOUND_MOVE_OUT = 3,  /* end: JIT_CODE_MOVE from this address */
    XODB_JIT_BOUND_SNAPSHOT = 4,  /* perf map line: existed at some untimed point */
};

struct xodb_jit_bound {
    uint32_t kind;
    int has_time;
    uint64_t time;        /* source clock */
    uint64_t ordinal;     /* citing record ordinal / line */
    uint64_t offset;      /* citing byte offset */
};

enum xodb_jit_version_flag {
    XODB_JIT_V_ORPHAN_MOVE = 1u << 0,   /* created by a move with no matching load */
    XODB_JIT_V_HAS_CODE = 1u << 1,      /* code bytes retained */
    XODB_JIT_V_VMA_DIFFERS = 1u << 2,
    XODB_JIT_V_DUPLICATE_INDEX = 1u << 3,
    XODB_JIT_V_NAME_NOT_UTF8 = 1u << 4,
    XODB_JIT_V_HEX_PREFIX = 1u << 5,     /* perf map 0x prefix accepted */
};

struct xodb_jit_version {
    uint32_t id;          /* 1-based, model-wide */
    uint32_t source;      /* 0-based source index */
    uint32_t flags;
    uint32_t predecessor; /* moved-from version id, 0 if none */
    uint64_t code_index;  /* jitdump only */
    int has_code_index;
    uint32_t pid, tid;
    uint64_t start, size; /* [start, start + size), never wraps */
    uint64_t vma;
    struct xodb_jit_bound begin, end;
    uint64_t name_offset; /* in source input bytes */
    uint32_t name_len;
    uint64_t code_offset; /* retained code bytes in source input, if HAS_CODE */
    uint64_t debug_first; /* index into model debug entries */
    uint32_t debug_count;
    uint64_t debug_record_ordinal;
    int64_t unwind_record;  /* index into model unwinds, -1 if none */
    uint32_t line_base;     /* version id holding this code's debug entries (self or move
                             * ancestor), 0 if none */
    uint64_t line_delta;    /* start - line_base start, modulo 2^64 */
};

/* Derived line evidence; cites its debug record. Not a native address map
 * for interpreted bytecode: entries are producer-declared code addresses. */
struct xodb_jit_debug_entry {
    uint64_t address;     /* as recorded; subtract the source's declared bias */
    uint32_t line;
    uint32_t discriminator;
    uint64_t file_offset; /* in source input */
    uint32_t file_len;
    uint32_t in_range;    /* biased address within the attached version */
};

/* Preserved unwinding data. Not interpreted (no CFI evaluation). */
struct xodb_jit_unwind {
    uint32_t source;
    uint64_t ordinal, offset;
    uint64_t unwind_size, eh_frame_hdr_size, mapped_size;
    uint64_t data_offset; /* in source input */
};

struct xodb_jit_source {
    uint32_t kind;
    struct xodb_jit_source_meta meta; /* strings point into owned copies */
    uint8_t *bytes;                   /* owned immutable copy */
    size_t len;
    /* jitdump header */
    int swapped;                      /* file byte order differs from host */
    int big_endian;                   /* file byte order */
    uint32_t version, header_size, elf_mach, header_pid;
    uint64_t header_time, header_flags;
    int arch_timestamp;
    /* decoding outcome */
    int complete;                     /* every byte decoded; no stop */
    int tail_truncated;               /* stopped only at an incomplete final record */
    int partial;                      /* stopped by budget or undecodable framing */
    int closed;                       /* CODE_CLOSE seen */
    uint64_t close_time;
    uint64_t records, unknown_records, malformed_records;
    uint64_t decoded_bytes;           /* prefix consumed by whole records */
    int has_last_time;
    uint64_t last_time;               /* max decoded record timestamp */
    uint64_t first_time;              /* min decoded record timestamp (valid with has_last_time) */
    int has_coverage;
    uint64_t coverage_end;            /* effective, source clock */
    /* versions of this source: model->versions[version_first .. + version_count) */
    size_t version_first, version_count;
    /* Static segment tree over the distinct range endpoints. Node n
     * (1 <= n < 2 * base) lists entries[first[n] .. first[n + 1]): model
     * version indexes whose range covers every address of the node, ordered
     * by (begin time, end time descending with open ends first, index). */
    struct {
        uint64_t *coords;
        size_t coord_count;
        size_t base;
        uint32_t *first;
        uint32_t *entries;
        size_t entry_count;
    } index;
    size_t charged;                   /* bytes charged for the copy, metadata and index */
    uint64_t build_work;              /* work units charged by the add call */
};

struct xodb_jit_model {
    struct xodb_jit_limits limits;
    size_t memory;
    struct xodb_jit_source *sources;
    size_t source_count, source_cap;
    struct xodb_jit_version *versions;
    size_t version_count, version_cap;
    struct xodb_jit_debug_entry *debug;
    size_t debug_count, debug_cap;
    struct xodb_jit_unwind *unwinds;
    size_t unwind_count, unwind_cap;
    struct xodb_jit_diag *diags;
    size_t diag_count, diag_cap;
    uint64_t diags_dropped;
    size_t memory_peak;               /* highest memory seen; reset by each add call */
};

/* Query: what code was at address in this process incarnation at this time? */
struct xodb_jit_query {
    struct xodb_jit_process process;
    uint64_t address;
    int has_time;
    uint64_t time;
    struct xodb_jit_clock clock;
};

enum xodb_jit_outcome {
    XODB_JIT_RESOLVED = 1,    /* one candidate, timed lifetime, verified identity and clock */
    XODB_JIT_UNVERIFIED = 2,  /* one candidate; reasons say what is unproven */
    XODB_JIT_AMBIGUOUS = 3,   /* several candidates not shown to be one code object */
    XODB_JIT_NO_MATCH = 4,    /* no applicable evidence covers the address */
    XODB_JIT_UNAVAILABLE = 5, /* evidence exists but cannot be related (clock) */
    XODB_JIT_INCOMPLETE = 6,  /* query stopped by work limit or cancellation */
};

enum xodb_jit_reason {
    XODB_JIT_R_IDENTITY_UNVERIFIED = 1u << 0, /* matched by pid only */
    XODB_JIT_R_IDENTITY_SKIPPED = 1u << 1,    /* some sources skipped: other incarnation */
    XODB_JIT_R_NO_QUERY_TIME = 1u << 2,
    XODB_JIT_R_CLOCK_UNRELATED = 1u << 3,
    XODB_JIT_R_UNTIMED_SNAPSHOT = 1u << 4,    /* perf map evidence */
    XODB_JIT_R_BOUNDARY = 1u << 5,            /* time within uncertainty of a boundary */
    XODB_JIT_R_OVERLAP = 1u << 6,             /* overlapping live versions */
    XODB_JIT_R_AFTER_COVERAGE = 1u << 7,
    XODB_JIT_R_NO_COVERAGE = 1u << 8,         /* source has no coverage end */
    XODB_JIT_R_PARTIAL_SOURCE = 1u << 9,      /* truncated or budget-stopped input */
    XODB_JIT_R_NO_END_EVIDENCE = 1u << 10,    /* informational: not observed to end */
    XODB_JIT_R_CORROBORATED = 1u << 11,       /* identical duplicate evidence from several jitdumps */
    XODB_JIT_R_BEFORE_COVERAGE = 1u << 12,    /* time precedes known reporting start */
    XODB_JIT_R_CANDIDATES_TRUNCATED = 1u << 13,
    XODB_JIT_R_QUERY_STOPPED = 1u << 14,      /* work limit or cancellation; total is a lower bound */
};

enum xodb_jit_candidate_state {
    XODB_JIT_C_LIVE = 1,      /* lifetime contains time, outside uncertainty */
    XODB_JIT_C_POSSIBLE = 2,  /* boundary, untimed or unrelated clock */
};

struct xodb_jit_candidate {
    uint32_t version;
    uint32_t state;
    uint32_t reasons;
};

struct xodb_jit_result {
    uint32_t outcome;
    uint32_t reasons;
    size_t count;      /* stored candidates */
    size_t total;      /* all candidates; exact when total_exact */
    int total_exact;   /* 0 only for an incomplete query */
    struct xodb_jit_candidate candidates[XODB_JIT_MAX_CANDIDATES];
};

void xodb_jit_limits_default(struct xodb_jit_limits *limits);
void xodb_jit_cancel_init(struct xodb_jit_cancel *cancel);
void xodb_jit_cancel_request(struct xodb_jit_cancel *cancel);
void xodb_jit_cancel_reset(struct xodb_jit_cancel *cancel);
int xodb_jit_cancel_requested(const struct xodb_jit_cancel *cancel);
void xodb_jit_model_init(struct xodb_jit_model *model, const struct xodb_jit_limits *limits);
void xodb_jit_model_free(struct xodb_jit_model *model);

/* Both copy the input and the metadata strings (each at most 4096 bytes); the
 * whole copy is charged before anything is allocated. XODB_JIT_E_BUDGET from
 * decoding keeps a partial source (its index is returned). Out of memory, the work limit,
 * cancellation, or a memory budget hit while indexing roll the call back:
 * *source_index is -1 and the model is as before (grown array capacity stays
 * allocated and charged). The _ctl forms take an optional control. */
int xodb_jit_add_jitdump(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                         const uint8_t *bytes, size_t len, int *source_index);
int xodb_jit_add_perfmap(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                         const uint8_t *bytes, size_t len, int *source_index);

int xodb_jit_add_jitdump_ctl(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                             const uint8_t *bytes, size_t len, struct xodb_jit_control *control,
                             int *source_index);
int xodb_jit_add_perfmap_ctl(struct xodb_jit_model *model, const struct xodb_jit_source_meta *meta,
                             const uint8_t *bytes, size_t len, struct xodb_jit_control *control,
                             int *source_index);

/* Read-only on the model: concurrent calls on a prepared model are safe.
 * Returns XODB_JIT_E_WORK or XODB_JIT_E_CANCELLED with outcome
 * XODB_JIT_INCOMPLETE when stopped (also while comparing duplicate evidence). */
int xodb_jit_resolve(const struct xodb_jit_model *model, const struct xodb_jit_query *query,
                     struct xodb_jit_result *result);
int xodb_jit_resolve_ctl(const struct xodb_jit_model *model, const struct xodb_jit_query *query,
                         struct xodb_jit_control *control, struct xodb_jit_result *result);

/* Map a source timestamp into target domain; returns 0 when not related. */
int xodb_jit_source_time(const struct xodb_jit_source *source, const struct xodb_jit_clock *target,
                         uint64_t time, uint64_t *mapped, uint64_t *uncertainty);
int xodb_jit_clock_equal(const struct xodb_jit_clock *a, const struct xodb_jit_clock *b);

const char *xodb_jit_error_name(int error);
const char *xodb_jit_diag_name(uint32_t code);
const char *xodb_jit_outcome_name(uint32_t outcome);
const char *xodb_jit_bound_name(uint32_t kind);
#endif
