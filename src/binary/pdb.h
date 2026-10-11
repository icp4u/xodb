#ifndef XODB_PDB_H
#define XODB_PDB_H
#include <stddef.h>
#include <stdint.h>

/* Minimal MSF 7 reader: public symbols and C13 source lines. No types, source
 * execution, symbol-server access or embedded source extraction. The caller
 * supplies immutable bytes and the PE's RSDS identity and section placement.
 * Successful output owns all data; it does not borrow the source buffer. */
#define XPDB_MAX_FILE_BYTES (64u * 1024u * 1024u)
#define XPDB_MAX_ALLOCATED_BYTES (64u * 1024u * 1024u)
#define XPDB_MAX_ROWS 1048576u
enum xpdb_status { XPDB_OK, XPDB_NOT_PDB, XPDB_MALFORMED, XPDB_UNSUPPORTED,
    XPDB_MISMATCH, XPDB_LIMIT, XPDB_NOMEM };
struct xpdb_section { uint32_t rva, size; };
struct xpdb_public { const char *name; uint32_t rva, flags; uint16_t section; };
struct xpdb_line { const char *path; uint32_t rva, end, line, column; unsigned statement; };
struct xpdb_info { uint32_t public_count, line_count; uint64_t retained_bytes, peak_bytes, work_bytes; };
struct xpdb;
enum xpdb_status xpdb_load(const void *, size_t, const unsigned char guid[16], uint32_t age,
    const struct xpdb_section *, unsigned section_count, struct xpdb **);
void xpdb_destroy(struct xpdb *);
const struct xpdb_info *xpdb_info(const struct xpdb *);
const struct xpdb_public *xpdb_public(const struct xpdb *, unsigned);
const struct xpdb_public *xpdb_find_public(const struct xpdb *, const char *);
/* Nearest preceding public in the same section. Public records have no size:
 * callers must additionally constrain this to a proven function extent. */
const struct xpdb_public *xpdb_public_at(const struct xpdb *, uint32_t);
const struct xpdb_line *xpdb_line(const struct xpdb *, unsigned);
const struct xpdb_line *xpdb_line_at(const struct xpdb *, uint32_t);
const char *xpdb_status_name(enum xpdb_status);
#endif
