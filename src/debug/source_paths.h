#ifndef XODB_DEBUG_SOURCE_PATHS_H
#define XODB_DEBUG_SOURCE_PATHS_H
#include "../binary/object.h"
/* Only a file table referenced by a real CU root can authorize a path.
 * The caller supplies a verified, pinned mapped ELF. No filesystem access
 * happens here except through its ranged source. Unsupported/compressed/split
 * debug information fails closed. Paths are lexical absolute POSIX paths;
 * no realpath(), cwd fallback, basename match or host-supplied compilation dir.
 * OK means the entire matching table header was validated, not that file
 * contents match the compiler's original source. The caller validates the
 * ELF identity again before publishing or opening the authorized source. */
#define XDW_SOURCE_PATH_MAX 4096
/* Normalize an absolute spelling, removing '.', redundant separators and
 * lexical '..'. Escaping above root refuses. The caller must open this same
 * normalized spelling with symlinks/magic links forbidden beneath its root;
 * this is not realpath() or an equivalence check across symlinks. */
enum xbo_status xdw_source_normalize(const char *, char out[XDW_SOURCE_PATH_MAX]);
enum xbo_status xdw_source_path(struct xbo_object *, const char *absolute_path,
                                struct xbo_budget *);
#endif
