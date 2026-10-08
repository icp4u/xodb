#ifndef XODB_DWARF_CURSOR_H
#define XODB_DWARF_CURSOR_H
#include "../binary/object.h"

/* DWARF 2-5 cursor over a checked ranged ELF source. No target execution,
 * whole-section allocation, borrowed file mapping or libdw global scan. */
#define XDW_ATTRIBUTES 64
struct xdw_attribute {
    uint64_t value;
    uint32_t name, form;
};
struct xdw_die {
    uint64_t unit, offset, end, unit_end, abbrev, str_offsets_base;
    uint32_t tag, depth, count;
    unsigned address_size, offset_size, version, children;
    struct xdw_attribute attributes[XDW_ATTRIBUTES];
};
enum xdw_action { XDW_DESCEND, XDW_SKIP_CHILDREN, XDW_STOP };
/* Callback borrows the DIE until it returns. It may use xdw_name with the
 * current budget. Non-OK leaves this DIE unconsumed; commit callback output
 * only on success. A STOP consumes this DIE. */
typedef enum xbo_status (*xdw_visit)(void *, const struct xdw_die *, enum xdw_action *);
struct xdw_cursor;
struct xdw_progress {
    uint64_t unit, next, info_size, units, dies, memory_bytes;
    int complete;
};
enum xbo_status xdw_create(struct xbo_object *, struct xdw_cursor **);
void xdw_destroy(struct xdw_cursor *);
/* Start one independently bounded CU walk. The offset is an untrusted hint:
 * its header, abbreviations and DIE structure are checked by xdw_walk. Cached
 * pages remain bound to the original file identity. No I/O in this reset. */
enum xbo_status xdw_select_unit(struct xdw_cursor *, uint64_t offset);
/* Every successful slice validates source identity. AGAIN is resumable and
 * also returned at the work limit. A callback STOP returns OK, not complete. */
enum xbo_status xdw_walk(struct xdw_cursor *, struct xbo_budget *, uint64_t work,
                         xdw_visit, void *);
const struct xdw_attribute *xdw_attribute(const struct xdw_die *, unsigned);
/* Explicitly typed name limit; no silent truncation. The DIE's CU context is
 * copied with it so indexed string forms remain tied to the original CU. */
enum xbo_status xdw_name(struct xdw_cursor *, const struct xdw_die *, char *, size_t,
                         struct xbo_budget *);
enum xbo_status xdw_string_attribute(struct xdw_cursor *, const struct xdw_die *, unsigned,
                                     char *, size_t, struct xbo_budget *);
void xdw_progress(const struct xdw_cursor *, struct xdw_progress *);
const char *xdw_error(const struct xdw_cursor *);
#endif
