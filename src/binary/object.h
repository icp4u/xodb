#ifndef XODB_BINARY_OBJECT_H
#define XODB_BINARY_OBJECT_H
#include <stddef.h>
#include <stdint.h>

/* A borrowed, pinned source; callbacks must not execute target code. The
 * transport bounds each callback's latency. Successful reads fill all bytes.
 * Identity must describe that same source, not a pathname looked up again. */
enum xbo_status {
    XBO_OK, XBO_AGAIN, XBO_CANCELLED, XBO_CHANGED, XBO_IO,
    XBO_NOT_ELF, XBO_MALFORMED, XBO_LIMIT, XBO_NOMEM, XBO_NOT_FOUND
};
struct xbo_identity {
    uint64_t device, inode, size;
    int64_t mtime_sec, ctime_sec;
    uint32_t mtime_nsec, ctime_nsec;
};
struct xbo_source {
    void *context;
    enum xbo_status (*identity)(void *, struct xbo_identity *);
    enum xbo_status (*read)(void *, uint64_t, void *, size_t);
};
struct xbo_budget {
    uint64_t bytes_left, reads_left, deadline_ns;
    void *context;
    int (*cancelled)(void *);
    uint64_t bytes_read, reads; /* Reserved bytes/calls, including failed reads. */
};
struct xbo_section {
    uint64_t flags, address, offset, size, alignment, entry_size;
    uint32_t name, type, link, info;
};
struct xbo_segment {
    uint64_t offset, address, file_size, memory_size, alignment;
    uint32_t type, flags;
};
struct xbo_object;
struct xbo_progress {
    uint64_t source_size, bytes_charged, read_calls, memory_bytes;
    unsigned phase; /* 0-2 header, 3-4 tables, 5-6 names, 7 notes, 8 ready */
    uint32_t cursor, sections, segments;
    int ready, changed;
};
void xbo_progress(const struct xbo_object *, struct xbo_progress *);
/* No I/O here. The source and its context must outlive the object. */
enum xbo_status xbo_create(const struct xbo_source *, struct xbo_object **);
void xbo_destroy(struct xbo_object *);
/* Retains progress on AGAIN/CANCELLED. Metadata is exposed only after OK.
 * A changed source is permanently invalid; construct a new object to retry. */
enum xbo_status xbo_prepare(struct xbo_object *, struct xbo_budget *);
enum xbo_status xbo_validate(struct xbo_object *, struct xbo_budget *);
/* Caller owns storage. Only bytes [0,*done) are initialized; retain the
 * same offset/size/storage when resuming. No borrowed mutable file mappings. */
enum xbo_status xbo_read(struct xbo_object *, uint64_t offset, void *, size_t,
                         size_t *done, struct xbo_budget *);
const struct xbo_identity *xbo_identity(const struct xbo_object *);
uint32_t xbo_section_count(const struct xbo_object *);
uint32_t xbo_segment_count(const struct xbo_object *);
const struct xbo_section *xbo_section(const struct xbo_object *, uint32_t);
const struct xbo_segment *xbo_segment(const struct xbo_object *, uint32_t);
const char *xbo_section_name(const struct xbo_object *, uint32_t);
enum xbo_status xbo_find_section(const struct xbo_object *, const char *, uint32_t *);
const unsigned char *xbo_build_id(const struct xbo_object *, size_t *);
unsigned xbo_address_size(const struct xbo_object *);
unsigned xbo_little_endian(const struct xbo_object *);
unsigned xbo_machine(const struct xbo_object *);
uint64_t xbo_memory_bytes(const struct xbo_object *);
const char *xbo_status_name(enum xbo_status);
uint64_t xbo_now_ns(void);
/* Local adapter borrows an O_RDONLY regular-file descriptor. No path reopen. */
struct xbo_local { int fd; };
struct xbo_source xbo_local_source(struct xbo_local *);
#endif
