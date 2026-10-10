#ifndef XODB_ELF_SYMBOLS_H
#define XODB_ELF_SYMBOLS_H
#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

/* Produces a sparse, symbol-only ELF view. Program/section headers retain
 * their original offsets; symbol tables, linked string/index tables, notes
 * and dynamic metadata, section names and .gnu_debuglink have contents.
 * This is NOT a binary or DWARF snapshot. The caller
 * supplies an immutable ranged reader and owns the unsealed output fd. */
typedef enum xrt_status (*xrt_elf_read)(void *, uint64_t, void *, size_t);
enum xrt_status xrt_elf_symbols(xrt_elf_read, void *, int, uint64_t);
#endif
