#ifndef XODB_XSQ_H
#define XODB_XSQ_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

/* Bounded static semantic queries over one exported function graph.
 *
 * Input is "xsg" version 1 (see XSG.md): image/spec/producer identity, address
 * spaces, blocks/edges, sized varnodes and high-p-code style SSA operations.
 * Results are static possibilities: a reported path is never an observed
 * execution. Unknown operations, calls and memory remain explicit boundaries;
 * nothing is silently treated as a no-op. Every query is bounded by a budget
 * and returns partial results with the limiting reason and frontier.
 *
 * Proposal only: names, limits and the file format are not a production API. */

#define XSQ_FORMAT_VERSION 1
#define XSQ_ANALYSIS_VERSION "xsq-0.3"
#define XSQ_NONE UINT32_MAX

/* Loader limits. Larger inputs fail with XSQ_LIMIT before use. */
#define XSQ_MAX_FILE_BYTES (64u << 20)
#define XSQ_MAX_LINE_BYTES 65536u
#define XSQ_MAX_FUNCTIONS 4096u
#define XSQ_MAX_BLOCKS (1u << 18)
#define XSQ_MAX_EDGES (1u << 19)
#define XSQ_MAX_VARNODES (1u << 21)
#define XSQ_MAX_OPS (1u << 20)
#define XSQ_MAX_OP_INPUTS 4096u
#define XSQ_MAX_TOKENS (XSQ_MAX_OP_INPUTS + 16u)
#define XSQ_MAX_INPUT_REFS (1u << 22)
#define XSQ_MAX_SPACES 64u
#define XSQ_MAX_READONLY 4096u
#define XSQ_MAX_VARNODE_BYTES 4096u
#define XSQ_MAX_STRING_BYTES (8u << 20)

enum xsq_status {
    XSQ_OK = 0,          /* complete within budget (may still contain boundaries) */
    XSQ_PARTIAL,         /* stopped early or shape not fully handled; see limit/frontier */
    XSQ_CANCELLED,       /* cancellation flag observed; partial results retained */
    XSQ_UNSUPPORTED,     /* query or graph shape not handled; no result claimed */
    XSQ_NOT_FOUND,       /* selector names no op/varnode (empty selection) */
    XSQ_INVALID_ARGUMENT,
    XSQ_MALFORMED,       /* input graph rejected; see graph error */
    XSQ_LIMIT,           /* loader limit exceeded */
    XSQ_NO_MEMORY,
    XSQ_IO,
};

/* Cancellation shared by graph loading and queries (C02-R2).  Any thread, or
 * a signal handler, may call xsq_cancel_request (a lock-free atomic release
 * store); the engine polls with acquire loads before any work and at least
 * every 256 work units.  Initialise with xsq_cancel_init before sharing. */
struct xsq_cancel { atomic_uint requested; };
void xsq_cancel_init(struct xsq_cancel *cancel);
void xsq_cancel_request(struct xsq_cancel *cancel);
int xsq_cancel_requested(const struct xsq_cancel *cancel);

/* Graph-loading budget (one phase of an operation).  max_bytes bounds the
 * cumulative bytes the loader requests from the allocator, including the file
 * buffer, tables, indices and validation scratch; frees do not refund.  Zero
 * takes XSQ_LOAD_DEFAULT_BYTES.  A cancelled load returns XSQ_CANCELLED; an
 * exceeded budget returns XSQ_LIMIT; allocator failure returns XSQ_NO_MEMORY. */
#define XSQ_LOAD_DEFAULT_BYTES ((size_t)1 << 30)
struct xsq_load_budget {
    size_t max_bytes;
    struct xsq_cancel *cancel;
};

/* Test support: make the allocation with 0-based index k (counted across
 * loader and query since the last call) fail; k < 0 disables.  Returns the
 * number of allocations made since the previous call. */
long xsq_test_alloc_fail_at(long k);
/* Test support: bytes the loader has hashed (process-wide counter; a
 * counted-work oracle for early cancellation).  reset != 0 also zeroes it. */
unsigned long long xsq_test_hashed_bytes(int reset);

enum xsq_space_class {
    XSQ_SPACE_CONSTANT,
    XSQ_SPACE_RAM,
    XSQ_SPACE_REGISTER,
    XSQ_SPACE_UNIQUE,
    XSQ_SPACE_STACK,
    XSQ_SPACE_JOIN,
    XSQ_SPACE_OTHER,
};

/* Ghidra p-code opcode spellings. XSQ_OP_UNKNOWN keeps unknown names as barriers. */
#define XSQ_OPCODES(X)                                                                            \
    X(COPY, DATA, W_UNARY) X(LOAD, LOAD, W_LOAD) X(STORE, STORE, W_STORE)                        \
    X(BRANCH, BRANCH, W_ANY) X(CBRANCH, CBRANCH, W_CBRANCH) X(BRANCHIND, BRANCHIND, W_ANY)        \
    X(CALL, CALL, W_ANY) X(CALLIND, CALL, W_ANY) X(CALLOTHER, BARRIER, W_ANY)                    \
    X(RETURN, RETURN, W_ANY) X(INT_EQUAL, DATA, W_CMP) X(INT_NOTEQUAL, DATA, W_CMP)               \
    X(INT_SLESS, DATA, W_CMP) X(INT_SLESSEQUAL, DATA, W_CMP) X(INT_LESS, DATA, W_CMP)            \
    X(INT_LESSEQUAL, DATA, W_CMP) X(INT_ZEXT, DATA, W_EXTEND) X(INT_SEXT, DATA, W_EXTEND)        \
    X(INT_ADD, DATA, W_BINARY) X(INT_SUB, DATA, W_BINARY) X(INT_CARRY, DATA, W_CMP)               \
    X(INT_SCARRY, DATA, W_CMP) X(INT_SBORROW, DATA, W_CMP) X(INT_2COMP, DATA, W_UNARY)           \
    X(INT_NEGATE, DATA, W_UNARY) X(INT_XOR, DATA, W_BINARY) X(INT_AND, DATA, W_BINARY)            \
    X(INT_OR, DATA, W_BINARY) X(INT_LEFT, DATA, W_SHIFT) X(INT_RIGHT, DATA, W_SHIFT)              \
    X(INT_SRIGHT, DATA, W_SHIFT) X(INT_MULT, DATA, W_BINARY) X(INT_DIV, DATA, W_BINARY)           \
    X(INT_SDIV, DATA, W_BINARY) X(INT_REM, DATA, W_BINARY) X(INT_SREM, DATA, W_BINARY)            \
    X(BOOL_NEGATE, DATA, W_BOOL) X(BOOL_XOR, DATA, W_BOOL) X(BOOL_AND, DATA, W_BOOL)              \
    X(BOOL_OR, DATA, W_BOOL) X(FLOAT_EQUAL, DATA, W_CMP) X(FLOAT_NOTEQUAL, DATA, W_CMP)           \
    X(FLOAT_LESS, DATA, W_CMP) X(FLOAT_LESSEQUAL, DATA, W_CMP) X(FLOAT_NAN, DATA, W_FLAG)         \
    X(FLOAT_ADD, DATA, W_BINARY) X(FLOAT_DIV, DATA, W_BINARY) X(FLOAT_MULT, DATA, W_BINARY)       \
    X(FLOAT_SUB, DATA, W_BINARY) X(FLOAT_NEG, DATA, W_UNARY) X(FLOAT_ABS, DATA, W_UNARY)          \
    X(FLOAT_SQRT, DATA, W_UNARY) X(FLOAT_INT2FLOAT, DATA, W_CONVERT)                              \
    X(FLOAT_FLOAT2FLOAT, DATA, W_CONVERT) X(FLOAT_TRUNC, DATA, W_CONVERT)                         \
    X(FLOAT_CEIL, DATA, W_UNARY) X(FLOAT_FLOOR, DATA, W_UNARY) X(FLOAT_ROUND, DATA, W_UNARY)      \
    X(MULTIEQUAL, PHI, W_PHI) X(INDIRECT, INDIRECT, W_INDIRECT) X(PIECE, DATA, W_PIECE)           \
    X(SUBPIECE, DATA, W_SUBPIECE) X(CAST, DATA, W_UNARY) X(PTRADD, DATA, W_PTRADD)                \
    X(PTRSUB, DATA, W_PTRSUB) X(SEGMENTOP, BARRIER, W_ANY) X(CPOOLREF, BARRIER, W_ANY)            \
    X(NEW, BARRIER, W_ANY) X(INSERT, DATA, W_ANY) X(EXTRACT, DATA, W_ANY)                         \
    X(POPCOUNT, DATA, W_CONVERT) X(LZCOUNT, DATA, W_CONVERT)

#define XSQ_OPCODE_ENUM(name, cls, width) XSQ_OP_##name,
enum xsq_opcode { XSQ_OPCODES(XSQ_OPCODE_ENUM) XSQ_OP_UNKNOWN };
#undef XSQ_OPCODE_ENUM

enum xsq_op_class {
    XSQ_CLASS_DATA, XSQ_CLASS_LOAD, XSQ_CLASS_STORE, XSQ_CLASS_BRANCH, XSQ_CLASS_CBRANCH,
    XSQ_CLASS_BRANCHIND, XSQ_CLASS_CALL, XSQ_CLASS_RETURN, XSQ_CLASS_PHI, XSQ_CLASS_INDIRECT,
    XSQ_CLASS_BARRIER,
};

enum xsq_edge_kind { XSQ_EDGE_FALL, XSQ_EDGE_TRUE, XSQ_EDGE_FALSE, XSQ_EDGE_JUMP, XSQ_EDGE_SWITCH };

enum xsq_vn_flag {
    XSQ_VN_INPUT = 1u << 0,      /* function input (no def inside the function) */
    XSQ_VN_PARAM = 1u << 1,      /* input that the prototype names as a parameter */
    XSQ_VN_SPACEBASE = 1u << 2,  /* input stack pointer; derived addresses are stack slots */
    XSQ_VN_ADDRTIED = 1u << 3,
    XSQ_VN_PERSIST = 1u << 4,
    XSQ_VN_SPACEBASE_HEURISTIC = 1u << 5, /* adapter inferred SPACEBASE by register name */
    XSQ_VN_ANNOTATION = 1u << 6, /* code address operand (branch/call target), not a value */
};

struct xsq_space { uint32_t id, name; uint8_t cls; };
struct xsq_vn {
    uint32_t id, func, def, name, origin, line, size;
    int32_t param;
    uint64_t offset;
    uint16_t space, flags;
};
struct xsq_op {
    uint32_t id, func, block, seq, out, in_first, in_count, iop, origin, name, line;
    uint64_t address;
    uint16_t opcode;
};
struct xsq_block {
    uint32_t id, func, op_first, op_count, succ_first, succ_count, pred_first, pred_count, line;
    uint64_t start;
};
struct xsq_edge { uint32_t from, to, line; uint8_t kind; };
struct xsq_func {
    uint32_t id, name, line, entry_block;
    uint32_t block_first, block_count, op_first, op_count, vn_first, vn_count;
    uint64_t entry;
    uint8_t cfg_incomplete; /* an indirect branch without resolved targets */
};
struct xsq_range { uint64_t low, high; }; /* [low, high) read-only image range */
struct xsq_call { uint32_t op; uint64_t target; uint32_t name; uint8_t known; };

struct xsq_graph {
    struct xsq_space *spaces;
    struct xsq_vn *vns;
    struct xsq_op *ops;
    struct xsq_block *blocks;
    struct xsq_edge *edges;
    struct xsq_func *funcs;
    struct xsq_range *readonly;
    struct xsq_call *calls;
    uint32_t *inputs;     /* op inputs as varnode indices (INDIRECT op ref in iop) */
    uint32_t *succ, *pred; /* edge indices grouped per block, in file order */
    uint32_t *op_by_id, *vn_by_id, *block_by_id; /* indices sorted by id */
    uint32_t space_count, vn_count, op_count, block_count, edge_count, func_count;
    uint32_t readonly_count, call_count, input_count;
    char *strings;
    size_t strings_len, strings_cap;
    /* identity, as recorded in the input; offsets into strings, 0 = absent */
    uint32_t image_sha256, image_build_id, image_name, language, compiler, producer,
        producer_version, source_kind, source_sha256;
    uint32_t addr_bytes;
    /* producer qualification carried from the graph's source (C01 export
     * contract, docs/SEMANTIC_QUERIES.md); 0 = absent (level "unknown") */
    uint32_t qual_level, qual_reasons, artifact_id;
    char input_sha256[65];
    /* load phase accounting */
    size_t load_bytes, load_max_bytes;
    /* first validation error */
    uint32_t error_line;
    char error[200];
};

enum xsq_status xsq_load_file(const char *path, struct xsq_graph *graph);
enum xsq_status xsq_load_buffer(const char *bytes, size_t size, struct xsq_graph *graph);
enum xsq_status xsq_load_file_budget(const char *path, const struct xsq_load_budget *budget,
                                     struct xsq_graph *graph);
enum xsq_status xsq_load_buffer_budget(const char *bytes, size_t size,
                                       const struct xsq_load_budget *budget,
                                       struct xsq_graph *graph);
void xsq_free(struct xsq_graph *graph);

const char *xsq_string(const struct xsq_graph *graph, uint32_t offset);
const char *xsq_opcode_name(const struct xsq_graph *graph, const struct xsq_op *op);
enum xsq_op_class xsq_opcode_class(unsigned opcode);
const char *xsq_status_name(enum xsq_status status);
const char *xsq_edge_kind_name(unsigned kind);
uint32_t xsq_find_op(const struct xsq_graph *graph, uint32_t id);  /* index or XSQ_NONE */
uint32_t xsq_find_vn(const struct xsq_graph *graph, uint32_t id);
uint32_t xsq_find_op_origin(const struct xsq_graph *graph, const char *origin);
uint32_t xsq_find_func(const struct xsq_graph *graph, const char *name);

/* Query budget (one phase of an operation). Zero fields take the defaults in
 * xsq_budget_default. Work is counted in deterministic units (one per
 * node/edge/op/dominator step examined); max_ns is an optional wall-clock
 * bound that makes the outcome timing dependent and is off by default.
 * max_bytes bounds the cumulative bytes the query requests from the
 * allocator: scratch, frontier, result arrays and growth (frees do not
 * refund). A process RLIMIT_AS is not a query budget. cancel (may be NULL)
 * is polled before any work and every 256 units. */
struct xsq_budget {
    uint32_t max_nodes, max_edges;
    uint64_t max_work, max_ns;
    size_t max_bytes;
    struct xsq_cancel *cancel;
};
void xsq_budget_default(struct xsq_budget *budget);

enum xsq_limit {
    XSQ_LIMIT_NONE, XSQ_LIMIT_NODES, XSQ_LIMIT_EDGES, XSQ_LIMIT_WORK, XSQ_LIMIT_MEMORY,
    XSQ_LIMIT_TIME, XSQ_LIMIT_CANCELLED,
    XSQ_LIMIT_ALLOCATION, /* the allocator itself failed (not the budget) */
};

/* How a slice node was reached from its parent. */
enum xsq_step {
    XSQ_STEP_ROOT,
    XSQ_STEP_OPERAND,        /* SSA def-use through a known data operation */
    XSQ_STEP_PHI,            /* MULTIEQUAL merge input */
    XSQ_STEP_INDIRECT_INPUT, /* INDIRECT carried value */
    XSQ_STEP_LOAD_ADDRESS,   /* address of the loaded location */
    XSQ_STEP_STORE_SAME,     /* reaching store to the proven same location */
    XSQ_STEP_STORE_MAY,      /* reaching store that may alias */
    XSQ_STEP_STORE_ADDRESS,  /* address of a may-alias store */
    XSQ_STEP_INDIRECT_STORE, /* value of a store an INDIRECT says may affect this value */
    XSQ_STEP_CALL_INPUT,     /* argument of an unknown callee whose result is used */
    XSQ_STEP_BARRIER_INPUT,  /* input of an operation without modelled semantics */
    XSQ_STEP_CONTROL,        /* condition of a branch the defining op is control dependent on */
    XSQ_STEP_GATING,         /* condition of a branch selecting a MULTIEQUAL input */
};

/* Strongest first. CONTROL: reaches the value only by deciding whether or
 * which definition executes (control/gating dependence), not as data. */
enum xsq_certainty { XSQ_DIRECT, XSQ_POSSIBLE, XSQ_CONTROL };

enum xsq_boundary_kind {
    XSQ_BOUND_CALL_RESULT,     /* value produced by a callee we do not analyse */
    XSQ_BOUND_CALL_MAY_WRITE,  /* reaching call may write the loaded location */
    XSQ_BOUND_INDIRECT_CALL,   /* INDIRECT: call may change this value */
    XSQ_BOUND_INDIRECT_OTHER,  /* INDIRECT caused by an op other than store/call */
    XSQ_BOUND_MEMORY_AT_ENTRY, /* location may hold its value from before entry */
    XSQ_BOUND_UNKNOWN_OP,      /* CALLOTHER/unknown/unsupported opcode */
    XSQ_BOUND_IMMUTABLE_LOAD,  /* load from declared read-only image range (terminal) */
    XSQ_BOUND_UNKNOWN_WRITE,   /* reaching CALLOTHER/unknown op may write the location */
};

enum xsq_exclusion_reason {
    XSQ_EXCLUDE_DISJOINT_STACK,  /* same frame base, non-overlapping offsets */
    XSQ_EXCLUDE_DISJOINT_GLOBAL, /* distinct constant addresses */
    XSQ_EXCLUDE_DISJOINT_SAME_BASE, /* same SSA base value, non-overlapping offsets */
    XSQ_EXCLUDE_STACK_VS_GLOBAL,
    XSQ_EXCLUDE_NONESCAPING_STACK, /* stack slot whose address never escapes */
    XSQ_EXCLUDE_KILLED,            /* an exact same-location store intervenes in-block */
};

struct xsq_node {
    uint32_t vn, parent, via_op; /* parent/via_op XSQ_NONE at root */
    uint16_t via_input;
    uint8_t step, certainty;
};
struct xsq_boundary { uint32_t op, vn, other; uint8_t kind, certainty; };
struct xsq_exclusion { uint32_t load_op, other_op; uint8_t reason; };
struct xsq_control {
    uint32_t branch_op, branch_block, condition_vn, controlled_block, edge;
    uint16_t depth;
    uint8_t certainty, nontermination;
};

enum xsq_partial_reason {
    XSQ_PARTIAL_BUDGET = 1u << 0,
    XSQ_PARTIAL_NONTERMINATING = 1u << 1, /* some branch can enter a region that never exits */
    XSQ_PARTIAL_CFG_INCOMPLETE = 1u << 2, /* unresolved indirect branch */
    XSQ_PARTIAL_PATH_TRUNCATED = 1u << 3,
};

struct xsq_result {
    enum xsq_status status;
    enum xsq_limit limit;
    uint32_t partial_reasons;
    uint32_t func, root_vn, root_op;
    int root_input; /* -1 output, -2 explicit varnode */
    uint8_t exhaustive;      /* slice: no boundaries, may-alias, partial CFG or budget stop */
    uint8_t control_included; /* slice followed control/gating dependences */
    uint8_t memory_complete; /* no load reached unknown memory/calls */
    struct xsq_node *nodes;
    uint32_t node_count;
    struct xsq_boundary *boundaries;
    uint32_t boundary_count;
    struct xsq_exclusion *exclusions;
    uint32_t exclusion_count;
    struct xsq_control *controls;
    uint32_t control_count;
    uint32_t *frontier; /* varnodes (slice) or blocks (controls) not expanded */
    uint32_t frontier_count;
    uint8_t frontier_complete; /* 0: the frontier itself could not be allocated */
    uint64_t work, edges, bytes, ns;
    char message[200];
    /* internal accounting */
    size_t bytes_used;
};

/* Select a value: an op output (input == -1), an op input (input >= 0) or,
 * when op_id is XSQ_NONE, a varnode by id. */
struct xsq_selector { uint32_t op_id, vn_id; int input; unsigned flags; };
#define XSQ_SLICE_DATA_ONLY 1u /* do not follow control/gating dependences */

enum xsq_status xsq_slice(const struct xsq_graph *graph, struct xsq_selector selector,
                          const struct xsq_budget *budget, struct xsq_result *result);
enum xsq_status xsq_controls(const struct xsq_graph *graph, uint32_t op_id,
                             const struct xsq_budget *budget, struct xsq_result *result);
void xsq_result_free(struct xsq_result *result);

/* Relevance of a varnode to a completed slice. */
enum xsq_relevance {
    XSQ_REL_DIRECT, XSQ_REL_POSSIBLE, XSQ_REL_CONTROL, XSQ_REL_IRRELEVANT, XSQ_REL_UNKNOWN,
};
enum xsq_relevance xsq_relevance(const struct xsq_result *slice, uint32_t vn_index,
                                 uint32_t *node_index);
const char *xsq_relevance_name(enum xsq_relevance relevance);

/* Names for report output. */
const char *xsq_step_name(unsigned step);
const char *xsq_boundary_name(unsigned kind);
const char *xsq_exclusion_name(unsigned reason);
const char *xsq_limit_name(unsigned limit);

#endif
