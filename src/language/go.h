#ifndef XODB_LANGUAGE_GO_H
#define XODB_LANGUAGE_GO_H
#include <elfutils/libdw.h>
#include <stdint.h>
#include <stddef.h>
/* Tested toolchain. Layout always comes from the image's own DWARF; the
 * version only gates the frame-pointer and g.sched conventions below. */
#define XGO_VERSION "go1.27.1"
enum xgo_type {
#define XGO_TYPE(key, name) XGO_T_##key,
#include "go_types.inc"
#undef XGO_TYPE
    XGO_TYPE_COUNT
};
enum xgo_field {
#define XGO_FIELD(key, owner, path, kind, width) XGO_##key,
#include "go_fields.inc"
#undef XGO_FIELD
    XGO_FIELD_COUNT
};
enum xgo_constant {
#define XGO_CONSTANT(key, name, value) XGO_C_##key,
#include "go_constants.inc"
#undef XGO_CONSTANT
    XGO_CONSTANT_COUNT
};
struct xgo_field_info { uint32_t offset, size; };
struct xgo_layout {
    struct xgo_field_info fields[XGO_FIELD_COUNT];
    uint32_t sizes[XGO_TYPE_COUNT];
    uint64_t constants[XGO_CONSTANT_COUNT];
    uint8_t build_id[64], build_id_len;
};
/* Same-image DWARF offsets and sizes; runtime constants must match the values
 * this reader interprets (stored-value cross-check). Returns an error name. */
const char *xgo_layout_build(Dwarf *, const uint8_t *, size_t, struct xgo_layout *);
typedef int (*xgo_read_fn)(void *, uint64_t, void *, size_t);
struct xgo_reader { void *context; xgo_read_fn read; size_t reads, bytes; const char *error; };
#define XGO_READ_LIMIT 65536
#define XGO_BYTE_LIMIT (4 * 1024 * 1024)
#define XGO_GOROUTINES 128
#define XGO_FRAMES 48
#define XGO_NAME 160
/* Runtime addresses of globals, from the verified loaded image's symbols. */
struct xgo_globals {
    uint64_t allgs, allglen, moduledata;
    uint64_t wait_strings, wait_count, status_strings, status_count;
};
struct xgo_func {
    uint64_t entry;
    uint8_t id;
    char name[XGO_NAME];
    const char *reason;
};
struct xgo_frame {
    uint64_t pc, lookup_pc, fp;
    struct xgo_func func;
    const char *reason;
};
struct xgo_goroutine {
    uint64_t g, goid, parent, gopc, startpc, m, thread, stack_lo, stack_hi;
    uint64_t pc, sp, bp; /* unwind start (sched or syscall state) */
    uint32_t status, raw_status;
    uint8_t wait_reason;
    int scan, system, running, complete;
    char status_name[32], wait_name[64];
    struct xgo_func creator, start;
    size_t count;
    struct xgo_frame frames[XGO_FRAMES];
    const char *reason;
};
struct xgo_snapshot {
    size_t count, total, dead;
    int truncated;
    const char *reason;
    struct xgo_goroutine items[XGO_GOROUTINES];
};
/* pclntab lookup in the loaded first module; no symbol guessing. */
void xgo_func_at(const struct xgo_layout *, struct xgo_reader *, const struct xgo_globals *, uint64_t pc, struct xgo_func *);
/* Goroutines from runtime.allgs. Parked/syscall goroutines are unwound by the
 * amd64 frame-pointer chain inside [stack.lo, stack.hi); running ones only
 * report their thread (caller unwinds those from registers). No target calls. */
void xgo_goroutines_read(const struct xgo_layout *, struct xgo_reader *, const struct xgo_globals *, struct xgo_snapshot *);
/* Go's own traceback filter (showfuncinfo at GOTRACEBACK<=1). */
int xgo_traceback_visible(const struct xgo_layout *, const char *name, uint8_t id, int first, int have_callee, uint8_t callee);
#endif
