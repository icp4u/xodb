#ifndef XODB_LANGUAGE_JAI_H
#define XODB_LANGUAGE_JAI_H
#include <stddef.h>
#include <stdint.h>
/* Caller-owned immutable, relocated read-only image ranges. No target reads,
 * file access, allocation or target execution occurs in the layout detector. */
struct xjai_region { uint64_t address; const unsigned char *data; size_t size; };
struct xjai_image { const struct xjai_region *regions; size_t count; };
#define XJAI_IMAGE_BYTES (64u * 1024u * 1024u)
#define XJAI_REGIONS 128
#define XJAI_PROFILE 1 /* little-endian, 64-bit seed; see docs/JAI.md */
enum xjai_struct_field {
    XJAI_S_INFO, XJAI_S_NAME, XJAI_S_PARAMETERS, XJAI_S_SPECIFIED_PARAMETERS,
    XJAI_S_MEMBERS, XJAI_S_TAGGED_UNION_BINDINGS, XJAI_S_STATUS_FLAGS,
    XJAI_S_NONTEXTUAL_FLAGS, XJAI_S_TEXTUAL_FLAGS, XJAI_S_ALIGNMENT,
    XJAI_S_POLYMORPH_SOURCE_STRUCT, XJAI_S_INITIALIZER, XJAI_S_CONSTANT_STORAGE,
    XJAI_S_NOTES, XJAI_S_FIELDS
};
enum xjai_member_field {
    XJAI_M_NAME, XJAI_M_TYPE, XJAI_M_OFFSET, XJAI_M_FLAGS, XJAI_M_NOTES,
    XJAI_M_CONSTANT_OFFSET, XJAI_M_FIELDS
};
enum xjai_member_flag {
    XJAI_F_CONSTANT, XJAI_F_IMPORTED, XJAI_F_USING, XJAI_F_PROCEDURE_VOID_POINTER,
    XJAI_F_AS, XJAI_F_OVERLAY, XJAI_F_FLAGS
};
struct xjai_layout {
    uint32_t profile, struct_size, member_size;
    uint32_t so[XJAI_S_FIELDS], mo[XJAI_M_FIELDS];
    uint64_t flags[XJAI_F_FLAGS];
    /* Diagnostic fingerprint of the validated schema, NOT a runtime hash or
     * compiler version. Pair with image identity before caching a layout. */
    uint64_t fingerprint;
    uint64_t struct_type, member_type, header_type, tag_type, flags_type;
};
/* Sorted, nonoverlapping ranges, <=64MiB total, <=128 regions. Every read must
 * fit one supplied range. Zeroes output on failure and returns a typed reason.
 * The profile's tag values are checked against the image's own enum table. */
const char *xjai_layout_detect(const struct xjai_image *, struct xjai_layout *);

#define XJAI_TYPES 16384u
#define XJAI_MEMBERS 65536u
#define XJAI_ENUMS 65536u
#define XJAI_TEXT_BYTES (8u * 1024u * 1024u)
#define XJAI_NONE UINT32_MAX
struct xjai_limits { uint32_t types,members,enums,text_bytes; };
/* Name offsets refer to graph.text (NUL terminated). Type indices, including
 * element/base references, refer to graph.types; NONE means unavailable. */
struct xjai_type {
    uint64_t address,size;
    uint32_t tag,name,first_member,member_count,first_parameter,parameter_count;
    uint32_t first_enum,enum_count,element,polymorph;
    uint64_t array_count;
    uint32_t array_kind;
    int is_signed;
    const char *reason; /* NULL means this record's metadata was validated. */
};
struct xjai_member {
    uint32_t name,type,flags;
    uint64_t offset,constant_offset,constant_address;
    const char *reason;
};
struct xjai_enum_value { uint32_t name;uint64_t bits; };
struct xjai_graph {
    struct xjai_layout layout;
    struct xjai_type *types;struct xjai_member *members;
    struct xjai_enum_value *enums;char *text;
    uint32_t type_count,member_count,enum_count,text_bytes;
    uint32_t type_capacity,member_capacity,enum_capacity,text_capacity;
    uint32_t invalid_types,invalid_members,rejected_candidates;
    uint64_t scanned_bytes,allocated_bytes;
    int partial;
    const char *reason;
};
/* NULL limits selects hard caps above. Smaller nonzero limits are allowed.
 * On success owns a graph, which may be partial with per-record reasons. Fatal
 * bootstrap/argument/allocation errors return a typed reason and NULL output.
 * References are followed by a bounded queue; recursive types cannot recurse
 * the C stack. Caller bytes are not retained. Only read-only metadata is read. */
const char *xjai_graph_build(const struct xjai_image *,const struct xjai_limits *,struct xjai_graph **);
void xjai_graph_free(struct xjai_graph *);
uint32_t xjai_type_at(const struct xjai_graph *,uint64_t);
#define XJAI_FIELD_DEPTH 16
struct xjai_flat_field {
    uint32_t member,depth,path[XJAI_FIELD_DEPTH];
    uint64_t offset;
    const char *reason;
};
/* Expand USING struct fields (including AS bases), skip compiler-imported
 * duplicates and constants. Cycles/depth/caps are explicit. Each row retains
 * its member path, so equal leaf names are never silently collapsed. */
const char *xjai_fields_flatten(const struct xjai_graph *,uint32_t type,
    struct xjai_flat_field *,size_t capacity,size_t *count);

#define XJAI_VALUE_ROWS 256u
#define XJAI_VALUE_DEPTH 8u
#define XJAI_VALUE_PREVIEW 128u
typedef int (*xjai_read_fn)(void *,uint64_t,void *,size_t);
struct xjai_live_reader {
    void *context;xjai_read_fn read;
    size_t reads,bytes;
};
struct xjai_value_options {
    uint32_t depth,limit;uint64_t start;int follow_pointers;
};
struct xjai_value_row {
    uint32_t type,parent,member,referenced_type,enum_name;
    uint64_t address,bits,index,total_count;
    int has_bits;
    unsigned char preview[XJAI_VALUE_PREVIEW];uint32_t preview_bytes;
    int truncated;
    const char *reason;
};
struct xjai_values {
    struct xjai_value_row *rows;uint32_t count,capacity;
    int partial;const char *reason;
};
/* Caller guarantees a retained stopped generation for the duration. Reads are
 * exact; <=512 calls/64KiB, <=256 rows/depth8, no target execution or writes.
 * start/limit page root aggregate members/elements; nested aggregates start0.
 * Pointer traversal is opt-in. Preview bytes carry explicit lengths. */
const char *xjai_value_read(const struct xjai_graph *,uint32_t type,uint64_t address,
    const struct xjai_value_options *,struct xjai_live_reader *,struct xjai_values **);
void xjai_values_free(struct xjai_values *);
/* Explicit self-type field, not a name heuristic. The field must have tag TYPE,
 * and its value must name a validated struct equal to or containing the declared
 * type at offset0 through USING fields. Reads share the caller's budget. */
const char *xjai_self_type(const struct xjai_graph *,uint32_t declared,uint64_t address,
    uint32_t member,struct xjai_live_reader *,uint32_t *resolved);

struct xjai_array_span { uint64_t data,count,capacity;uint32_t element; };
/* Fixed/view/resizable span under the validated le64 profile. Resizable headers
 * require the documented 40-byte layout and count <= capacity; allocator words
 * are never followed. Sharing this decoder keeps previews and walkers identical. */
const char *xjai_array_span(const struct xjai_graph *,uint32_t type,uint64_t address,
    struct xjai_live_reader *,struct xjai_array_span *);
#define XJAI_CONTAINER_ROWS 256u
#define XJAI_BUCKET_SLOTS 16384u
struct xjai_container_row { uint64_t address,slot;uint32_t type; };
struct xjai_container_page {
    uint64_t total_count,capacity;uint32_t count;int truncated;
};
/* Caller-owned bounded page of array elements or occupied Bucket data slots.
 * Bucket fields and offsets come from RTTI, including the bool-array occupancy
 * representation. Validate every flag and the stored count before publishing
 * any row. start is an occupied-element ordinal; slot retains the physical index.
 * Returned addresses describe storage, not proof of an object's lifetime.
 * On any error the page is zeroed and no rows are published. */
const char *xjai_container_read(const struct xjai_graph *,uint32_t type,uint64_t address,
    uint64_t start,struct xjai_container_row *,size_t capacity,struct xjai_live_reader *,
    struct xjai_container_page *);
/* A type-pointer search hit is only a candidate. An explicit direct TYPE field
 * gives its offset; re-read it and check the compatible self-type prefix. This
 * corroborates bytes at a stopped generation, never proves allocation/liveness. */
const char *xjai_instance_candidate(const struct xjai_graph *,uint32_t declared,
    uint32_t member,uint64_t hit,struct xjai_live_reader *,uint64_t *address,uint32_t *actual);
#define XJAI_WRITE_BYTES 64u
#define XJAI_WRITE_PATH 256u
#define XJAI_WRITE_VALUE (XJAI_WRITE_BYTES * 2u)
struct xjai_write_plan {
    uint64_t address,type_address;
    uint32_t type,size;
    unsigned char bytes[XJAI_WRITE_BYTES];
};
/* Resolve direct dot fields and bounded array indices, then encode one value.
 * Integers/bools/floats/enumerators are checked against the retained metadata.
 * raw accepts exactly size*2 hex characters, including pointer/string/array
 * headers. Constants, unresolved types and >64-byte leaves are always refused.
 * No target writes occur. Caller must separately enforce the current stop,
 * mutation authority, writable non-code/non-metadata destination and readback.
 * Array headers share the live-read budget. Work <=4096 member/enum visits and depth16.
 * Clears the output on error. Inputs have explicit lengths; embedded NUL fails. */
const char *xjai_write_plan(const struct xjai_graph *,uint32_t type,uint64_t address,
    const char *path,size_t path_size,const char *value,size_t value_size,int raw,
    struct xjai_live_reader *,struct xjai_write_plan *);

#define XJAI_WRITE_RECORDS 1024u
#define XJAI_WRITE_PROTECTED_RANGES 512u
#define XJAI_WRITE_MAP_READ 1u
#define XJAI_WRITE_MAP_WRITE 2u
#define XJAI_WRITE_MAP_EXEC 4u
#define XJAI_WRITE_MAP_SHARED 8u
struct xjai_write_range { uint64_t address,size; };
struct xjai_write_mapping { uint64_t start,end;uint32_t permissions; };
typedef int (*xjai_mapping_fn)(void *,uint64_t,struct xjai_write_mapping *);
/* Check the complete destination before touching bytes, including raw undo.
 * Mapping query returns a covering half-open range. At most64 queries are needed.
 * Every retained runtime-metadata range must be included in protected_ranges. */
const char *xjai_write_destination(xjai_mapping_fn,void *,const struct xjai_write_range *,
    size_t protected_count,uint64_t address,size_t size);
struct xjai_write_stamp {
    uint64_t session_id,target_id,image_epoch,generation,client_id;
    uint32_t actor; /* 0 human, 1 agent; descriptive, not authorization */
};
struct xjai_write_io {
    void *context;
    xjai_read_fn read;
    const char *(*write)(void *,uint64_t,const void *,size_t);
    /* Mandatory: check stopped target identity/authority and destination policy.
     * Called before the old-byte read and again immediately before writing. */
    const char *(*guard)(void *,uint64_t,size_t);
    uint64_t (*generation)(void *);
};
struct xjai_write_change {
    uint64_t id,address,before_generation,after_generation;
    uint32_t size;
    int raw,undo,before_valid,observed_valid,write_attempted,verified;
    unsigned char before[XJAI_WRITE_BYTES],requested[XJAI_WRITE_BYTES],observed[XJAI_WRITE_BYTES];
    const char *reason,*backend_reason;
};
struct xjai_write_record {
    uint64_t id,attempts,after_generation;
    struct xjai_write_stamp initial,last;
    struct xjai_write_plan plan;
    char path[XJAI_WRITE_PATH+1];
    unsigned char before[XJAI_WRITE_BYTES],observed[XJAI_WRITE_BYTES];
    int raw,last_raw,last_undo,observed_valid,undone;
    const char *last_reason,*backend_reason;
};
struct xjai_write_journal;
struct xjai_write_journal *xjai_write_journal_create(void);
void xjai_write_journal_free(struct xjai_write_journal *);
size_t xjai_write_journal_count(const struct xjai_write_journal *);
size_t xjai_write_journal_bytes(const struct xjai_write_journal *);
/* Borrowed until next apply/free. Current-target entries are never evicted;
 * the first valid write for a new target/image releases the old incarnation.
 * IDs remain unique. Page indices refer only to the currently retained rows. */
const struct xjai_write_record *xjai_write_journal_get(const struct xjai_write_journal *,uint64_t id);
const struct xjai_write_record *xjai_write_journal_at(const struct xjai_write_journal *,size_t index);
uint64_t xjai_write_journal_last(const struct xjai_write_journal *,const struct xjai_write_stamp *);
/* Single-owner calls. target_id must change on every new target incarnation.
 * All IO callbacks must refuse a replaced/resumed target; guards alone cannot
 * prove that identity stays current during a callback.
 * Caller callback reasons must be static strings. Mutation cannot precede a
 * complete old-byte read and reserved journal storage. Changes with nonzero id
 * retain before bytes even on write/readback failure. Failed preflight gets id0. */
const char *xjai_write_apply(struct xjai_write_journal *,const struct xjai_write_plan *,
    const char *path,size_t path_size,int raw,const struct xjai_write_stamp *,
    const struct xjai_write_io *,struct xjai_write_change *);
/* Checked undo compares current bytes with the last observed result. Explicit
 * raw mode bypasses only that comparison, never identity/guard/readback checks.
 * Partial/unverified failures retain their original before bytes for recovery.
 * Comparison/readback are sampled, not atomic and not proof of object lifetime. */
const char *xjai_write_undo(struct xjai_write_journal *,uint64_t id,int raw,
    const struct xjai_write_stamp *,const struct xjai_write_io *,struct xjai_write_change *);
#endif
