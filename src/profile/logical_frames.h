#ifndef XODB_LOGICAL_FRAMES_H
#define XODB_LOGICAL_FRAMES_H
/* Bounded reader for "xodb.logical-frames" version 1, draft C05-1: logical
 * (interpreter/runtime) stacks exported by language runtimes. Standalone C11
 * candidate (C05-R2 boundary contract, docs/LOGICAL_FRAMES.md); not an
 * installed xodb ABI. It never produces native unwinding.
 *
 * Input is UTF-8 JSON Lines. Every decoded entity cites its source line and
 * byte range; the raw input SHA-256 is retained. All strings are copied into
 * the document, so no pointer into the caller's buffer survives decoding.
 *
 * Ownership and lifetime (C05-R2):
 *  - xlf_decode/xlf_decode_file return a document owned by the caller and
 *    released only by xlf_free. After a successful return the document is
 *    immutable: queries take it const and may run concurrently on several
 *    threads. Freeing it while a query runs is the caller's error.
 *  - Every allocation made by the reader is charged to a byte budget. Decode
 *    charges the document, transient parse storage and (xlf_decode_file) the
 *    input copy; a query charges its scratch and its result separately.
 *  - On any failure the function returns no object, releases everything it
 *    allocated, leaves its inputs unchanged and fills xlf_error.
 *  - Aggregates are exact. Counter values are struct xlf_count (exact
 *    unsigned 128-bit). With the validated limits below no counter can exceed
 *    2^96, so a valid document always aggregates exactly; nothing saturates or
 *    wraps. Consumers needing a u64 use xlf_count_to_u64, whose false result is
 *    the explicit overflow outcome. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XLF_FORMAT "xodb.logical-frames"
#define XLF_VERSION 1
#define XLF_DRAFT "C05-1"
#define XLF_CONTRACT "C05-R4-1" /* reader boundary contract version */
#define XLF_HAVE_READ_STABLE 1 /* C05-R4: xlf_read_stable, enum xlf_stability */
#define XLF_NONE UINT32_MAX
#define XLF_AMBIGUOUS (UINT32_MAX - 1) /* xlf_find_thread: name matches several threads */
#define XLF_MAX_INDEX (UINT32_MAX - 2) /* entity/stack/frame/record counts are below this */

struct xlf_limits {
    size_t max_input_bytes;  /* whole input */
    size_t max_line_bytes;   /* one JSON record */
    size_t max_records;      /* lines */
    size_t max_string_bytes; /* any decoded string */
    size_t max_frames_per_stack;
    size_t max_total_frames;
    size_t max_entities; /* codes, functions, threads, losses each */
    size_t max_stacks;   /* stacks, and acquisitions */
    size_t max_memory;   /* peak live bytes of one decode (document + parse scratch + owned input) */
    unsigned max_depth;
};
void xlf_default_limits(struct xlf_limits *limits);

/* Budget of one query. Incremental = the query's own scratch + result storage.
 * Combined = the document's retained bytes + that incremental peak. A query is
 * refused (XLF_E_MEMORY, nothing allocated) when the retained bytes alone exceed
 * max_combined_bytes, even when it would allocate nothing (C05-R3). */
struct xlf_query_limits {
    size_t max_query_bytes;
    size_t max_combined_bytes;
};
void xlf_default_query_limits(struct xlf_query_limits *limits);

enum xlf_status {
    XLF_OK,
    XLF_E_MEMORY, /* budget exhausted or allocation failed */
    XLF_E_LIMIT,  /* a count/size limit, or invalid limits */
    XLF_E_UTF8,
    XLF_E_JSON,
    XLF_E_SCHEMA,
    XLF_E_VERSION,
    XLF_E_DUPLICATE,
    XLF_E_REFERENCE,
    XLF_E_IDENTITY,
    XLF_E_CLOCK,
    XLF_E_ORDER,
    XLF_E_INVENTED_PC,
    XLF_E_ADDRESS,
    XLF_E_COUNT,
    XLF_E_EMPTY,
    /* C05-R2 additions (appended; earlier values unchanged) */
    XLF_E_CANCELLED, /* cancellation observed; no result */
    XLF_E_OVERFLOW,  /* an exact value does not fit the requested representation */
    XLF_E_ARGUMENT,  /* invalid call argument (e.g. thread index) */
    XLF_E_IO,        /* xlf_decode_file: open/stat/read failure (message has errno text) */
};
const char *xlf_status_name(enum xlf_status status);

struct xlf_error {
    enum xlf_status status;
    uint64_t line;   /* 1-based, 0 if not line specific */
    uint64_t offset; /* byte offset of that line */
    size_t peak_bytes; /* peak charged bytes of the failed operation */
    char message[256];
};

/* Exact unsigned counter: value = hi * 2^64 + lo. */
struct xlf_count {
    uint64_t hi, lo;
};
/* Adds v. Returns false (count unchanged) only if the 128-bit value would overflow. */
bool xlf_count_add(struct xlf_count *count, uint64_t v);
/* Returns false when the exact value exceeds UINT64_MAX (explicit overflow outcome). */
bool xlf_count_to_u64(struct xlf_count count, uint64_t *out);
int xlf_count_cmp(struct xlf_count a, struct xlf_count b);
/* Canonical decimal text, NUL terminated; returns the length (at most 39). */
size_t xlf_count_format(struct xlf_count count, char out[40]);

/* Cancellation shared between threads. Request is a C11 atomic release store
 * (lock-free; also usable from a signal handler); operations poll it with
 * acquire loads at least once per record, per MiB of hashed/read input and
 * per aggregated stack. A request is sticky until xlf_cancel_reset. */
struct xlf_cancel;
struct xlf_cancel *xlf_cancel_create(void);
void xlf_cancel_destroy(struct xlf_cancel *cancel);
void xlf_cancel_request(struct xlf_cancel *cancel);
void xlf_cancel_reset(struct xlf_cancel *cancel);
bool xlf_cancel_requested(const struct xlf_cancel *cancel);

enum xlf_kind {
    XLF_KIND_INTERPRETER,
    XLF_KIND_NATIVE,
    XLF_KIND_NATIVE_TRANSITION,
    XLF_KIND_JIT,
    XLF_KIND_LOGICAL,
    XLF_KIND_UNKNOWN,
    XLF_KIND_UNCLASSIFIED,
};
const char *xlf_kind_name(enum xlf_kind kind);
enum xlf_provenance { XLF_PROV_RUNTIME, XLF_PROV_COOPERATIVE, XLF_PROV_EXTERNAL };
const char *xlf_provenance_name(enum xlf_provenance provenance);
enum xlf_state { XLF_STACK_COMPLETE, XLF_STACK_TRUNCATED, XLF_STACK_PARTIAL };
const char *xlf_state_name(enum xlf_state state);

/* Optional text: ptr == NULL means JSON null. Text is NUL terminated. */
struct xlf_str {
    const char *ptr;
    uint32_t len;
};
struct xlf_cite {
    uint64_t line, offset, length;
};
struct xlf_opt_u64 {
    bool known;
    uint64_t value;
};

struct xlf_code {
    struct xlf_str id, kind, path, sha256, unavailable;
    struct xlf_opt_u64 bytes;
    bool has_range;
    uint64_t start, end;               /* JIT/native code interval */
    struct xlf_opt_u64 load_ns, unload_ns;
    struct xlf_cite cite;
};
struct xlf_function {
    struct xlf_str id, name, qualified, runtime_id;
    uint32_t code; /* XLF_NONE when unknown */
    int64_t first_line; /* -1 when unknown */
    enum xlf_kind kind;
    struct xlf_cite cite;
};
struct xlf_thread {
    struct xlf_str id, language_id, name, os_tid_source, os_tid_reason;
    int64_t os_tid; /* -1 when unknown */
    bool os_tid_shared; /* another thread record names the same OS TID */
    struct xlf_cite cite;
};
struct xlf_frame {
    uint32_t function; /* XLF_NONE for marker frames */
    int64_t line;      /* -1 when unknown */
    enum xlf_kind kind;
    enum xlf_provenance provenance;
    struct xlf_str label, reason;
    bool has_pc;
    uint64_t pc;
};
struct xlf_acquisition {
    uint64_t seq;
    struct xlf_opt_u64 start_ns, end_ns;
    uint64_t declared_stacks, seen_stacks;
    struct xlf_cite cite;
};
struct xlf_stack {
    struct xlf_str id, trigger, reason, exception_type;
    uint32_t acquisition, thread;
    struct xlf_opt_u64 start_ns, end_ns, omitted;
    uint64_t weight;
    enum xlf_state state;
    uint32_t first_frame, frame_count; /* innermost first */
    struct xlf_cite cite;
};
struct xlf_loss {
    struct xlf_str reason;
    uint64_t count;
    uint32_t acquisition;
    struct xlf_cite cite;
};

enum xlf_warning {
    XLF_W_NO_END = 1u << 0,           /* no end record: input truncated/interrupted */
    XLF_W_TRUNCATED_TAIL = 1u << 1,   /* final line lacks newline; ignored */
    XLF_W_INTERRUPTED = 1u << 2,      /* producer reported interruption */
    XLF_W_OS_TID_SHARED = 1u << 3,    /* language thread to OS TID ambiguity */
    XLF_W_ACQ_INCOMPLETE = 1u << 4,   /* acquisition missing stacks (no end) */
    XLF_W_LOSS = 1u << 5,             /* explicit loss records present */
    XLF_W_PARTIAL_STACKS = 1u << 6,   /* truncated/partial stacks present */
    XLF_W_CODE_PATH_REUSED = 1u << 7, /* same path, different content identity */
    XLF_W_ADDRESS_REUSE = 1u << 8,    /* overlapping code ranges with unknown lifetimes */
    XLF_W_NO_CLOCK = 1u << 9,
};
/* Warnings that make the document itself incomplete evidence. */
#define XLF_W_INCOMPLETE (XLF_W_NO_END | XLF_W_TRUNCATED_TAIL | XLF_W_INTERRUPTED | XLF_W_ACQ_INCOMPLETE)

struct xlf_header {
    struct xlf_str producer_name, producer_version, producer_kind, producer_sha256;
    struct xlf_str source_kind, language, implementation, runtime_version, runtime_build;
    struct xlf_str executable_path, executable_sha256, executable_build_id, executable_unavailable;
    struct xlf_str library_path, library_sha256, library_build_id;
    struct xlf_str process_unavailable, boot_id, clock_domain, clock_unavailable;
    struct xlf_str method, trigger, atomicity, notes, weight_unit, weight_semantics;
    int64_t pid; /* -1 unknown */
    struct xlf_opt_u64 start_ticks, interval_ns;
    bool has_clock;
    uint32_t command_count;
    struct xlf_str *command;
};

/* C05-R4: whether bytes read from a file are known to be one version of it.
 * Size/inode/mtime/ctime comparisons do not detect a concurrent same-size
 * rewrite on common filesystems (XFS included), so they never make a read
 * "stable" on their own. */
enum xlf_stability {
    XLF_STABILITY_CALLER,     /* caller-supplied bytes (xlf_decode): their stability is the caller's */
    XLF_STABILITY_LEASED,     /* read under a kernel read lease held from before the first byte to after
                                 the last: no process had the file open for writing, none could open it
                                 for writing or truncate it meanwhile; the bytes are one version */
    XLF_STABILITY_UNVERIFIED, /* no lease was possible (file owned by another user without CAP_LEASE,
                                 filesystem or kernel without leases, no helper thread): only size, inode
                                 and times were compared, which a concurrent same-size or mmap writer can
                                 evade; the bytes may mix versions. Producers should write then rename. */
};
const char *xlf_stability_name(enum xlf_stability stability); /* "caller_bytes", "leased", "unverified" */

struct xlf_doc {
    struct xlf_header header;
    uint8_t sha256[32];
    char sha256_hex[65];
    uint64_t input_bytes, records;
    bool ended;
    struct xlf_str end_status;
    uint32_t warnings;
    struct xlf_cite truncated_tail;
    struct xlf_code *codes;
    struct xlf_function *functions;
    struct xlf_thread *threads;
    struct xlf_frame *frames;
    struct xlf_acquisition *acquisitions;
    struct xlf_stack *stacks;
    struct xlf_loss *losses;
    size_t code_count, function_count, thread_count, frame_count, acquisition_count, stack_count,
        loss_count;
    struct xlf_count lost;         /* exact sum of loss counts */
    struct xlf_count total_weight; /* exact sum of all stack weights */
    size_t retained_bytes;         /* live bytes owned by this document until xlf_free */
    size_t decode_peak_bytes;      /* peak charged bytes during decode (<= limits.max_memory) */
    bool input_charged;            /* the input copy was part of the decode budget */
    void *private_state;
    enum xlf_stability input_stability; /* C05-R4: how the input bytes were protected (xlf_read_stable) */
};

/* Decode and validate caller-owned bytes (not charged; never retained).
 * cancel may be NULL. On failure returns NULL and fills err. */
struct xlf_doc *xlf_decode(const void *bytes, size_t size, const struct xlf_limits *limits,
                           const struct xlf_cancel *cancel, struct xlf_error *err);
/* Read a regular file (bounded by max_input_bytes before reading) into a
 * buffer charged to the decode budget, decode it and release the buffer.
 * C05-R3: the path is pinned with O_PATH and only a regular file is opened, so a
 * FIFO or device is refused (XLF_E_IO) without open side effects or blocking; a
 * cancellation already requested is observed before the path is touched. The
 * reopen uses /proc/self/fd; without /proc the call fails with XLF_E_IO.
 * C05-R4: the read goes through xlf_read_stable; doc->input_stability says
 * whether the bytes are known to be one version of the file. */
struct xlf_doc *xlf_decode_file(const char *path, const struct xlf_limits *limits,
                                const struct xlf_cancel *cancel, struct xlf_error *err);
/* C05-R4: stable read of a regular file. Pins the path (O_PATH), refuses
 * anything but a regular file (XLF_E_IO, without opening it), reopens the pinned
 * inode read-only and takes a read lease (F_SETLEASE, F_RDLCK). The kernel
 * grants it only while no process has the file open for writing and, while it is
 * held, makes every open for writing and every truncate wait until it is
 * released. The lease-break notification signal is directed at a short-lived
 * helper thread that blocks all signals, so the calling process is never
 * signalled; a writer that tries to open the file waits at most until this call
 * returns (or the system lease-break-time).
 *   - The file is open for writing when the lease is requested: XLF_E_IO,
 *     nothing is read (no stable read is possible while a writer holds it).
 *   - The lease was taken: sink(ctx, fd, size) reads the file; afterwards the
 *     lease must still be intact (no writer tried to open it) and size, inode,
 *     mtime and ctime unchanged, else XLF_E_IO ("changed while it was read").
 *     *stability = XLF_STABILITY_LEASED.
 *   - A file with bytes beyond the size observed before the read (a /proc or
 *     /sys pseudo-file, or a file that grew) is XLF_E_IO, never a short copy.
 *   - No lease is possible (see XLF_STABILITY_UNVERIFIED): the read proceeds,
 *     a detected change is XLF_E_IO, and *stability = XLF_STABILITY_UNVERIFIED.
 * sink fills err itself when it fails; its status is returned unchanged. When
 * this call fails after a successful sink, the sink's output must be discarded.
 * size is the st_size observed before the read. */
typedef enum xlf_status (*xlf_read_sink)(void *ctx, int fd, uint64_t size, struct xlf_error *err);
enum xlf_status xlf_read_stable(const char *path, xlf_read_sink sink, void *ctx, enum xlf_stability *stability,
                                struct xlf_error *err);
void xlf_free(struct xlf_doc *doc);

/* Reference aggregate (analysis "xlf-aggregate-v1") over one document.
 * thread == XLF_NONE selects all threads. self/inclusive have function_count
 * entries (NULL when function_count is 0). self = innermost frame's function;
 * inclusive counts a function once per stack even when it recurs. Marker
 * frames (no function) put the stack's weight once in marker_weight; a stack
 * whose innermost frame is a marker, or that has no frames, counts in
 * unknown_leaf_weight. Truncated/partial stacks are included in every counter
 * and also in partial_weight. input_incomplete repeats the document's
 * incompleteness (XLF_W_INCOMPLETE) so a result never looks complete when its
 * evidence is not. On failure *out is zeroed and owns nothing. */
struct xlf_aggregate {
    struct xlf_count *self, *inclusive;
    size_t function_count;
    struct xlf_count total_weight, partial_weight, marker_weight, unknown_leaf_weight;
    uint64_t stacks, partial_stacks;
    bool input_incomplete;
    size_t result_bytes;        /* retained by this result until xlf_aggregate_free */
    size_t query_peak_bytes;    /* incremental peak (scratch + result) */
    size_t combined_peak_bytes; /* doc->retained_bytes + query_peak_bytes */
};
enum xlf_status xlf_aggregate(const struct xlf_doc *doc, uint32_t thread, const struct xlf_query_limits *limits,
                              const struct xlf_cancel *cancel, struct xlf_aggregate *out, struct xlf_error *err);
void xlf_aggregate_free(struct xlf_aggregate *aggregate);
/* Thread index by id, else by unique name; XLF_NONE if absent, XLF_AMBIGUOUS if the name repeats. */
uint32_t xlf_find_thread(const struct xlf_doc *doc, const char *id_or_name);
#endif
