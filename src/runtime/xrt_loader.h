#ifndef XODB_RUNTIME_LOADER_H
#define XODB_RUNTIME_LOADER_H
#include "xrt_target.h"
#include <signal.h>
/* Bounded, read-only ELF loader discovery. No mapped image is downloaded.
 * A zero rendezvous means static, unsupported, or not initialized yet; retry
 * at a later ordinary stop. Counters remain available on failure. */
struct xrt_loader {
    uint64_t debug_address, break_address, main_phdr, interpreter;
    uint64_t bytes, reads, elapsed_ns;
};
/* Kernel placement facts only; no loader symbols, image download or target
 * memory walk. The page size belongs to the target, including remote guests. */
struct xrt_auxv {
    uint64_t main_phdr, phnum, phent, interpreter, page_size, entry;
};
enum xrt_status xrt_target_auxv(const struct xrt_target *, struct xrt_auxv *);
enum xrt_status xrt_target_loader(const struct xrt_target *, struct xrt_loader *,
                                  const volatile sig_atomic_t *cancel);
#endif
