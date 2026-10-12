#ifndef XODB_MACHO_DWARF_H
#define XODB_MACHO_DWARF_H
#include "../binary/macho.h"

/* A private section container for libdw. It is not a loadable module and
 * never supplies code, symbols, mappings or a load bias. The caller matches
 * file identity, UUID and architecture before publishing its metadata. */
struct xmo_dwarf {
    unsigned char *bytes;
    size_t size;
    unsigned debug_sections, eh_frame;
};
enum xmo_status xmo_dwarf_build(const struct xmo_image *, uint64_t allowance,
                              struct xmo_dwarf *);
/* Object DWARF stays in object coordinates, including line programs. This
 * callback assigns a private address token to each undefined external; only
 * the caller's explicit object-to-linked mapping can resolve such a token. */
typedef enum xmo_status (*xmo_dwarf_external)(void *, uint32_t symbol, uint64_t addend, uint64_t *token);
enum xmo_status xmo_dwarf_build_object(struct xmo_image *, uint64_t allowance,
    xmo_dwarf_external, void *, struct xmo_dwarf *);
void xmo_dwarf_free(struct xmo_dwarf *);
#endif
