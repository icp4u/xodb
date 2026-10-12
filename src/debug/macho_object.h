#ifndef XODB_MACHO_OBJECT_H
#define XODB_MACHO_OBJECT_H
#include "macho_dwarf.h"

#define XMO_MAX_DEBUG_OBJECTS 64u
#define XMO_MAX_OBJECT_SYMBOLS 16384u
struct xmo_object_map;
/* Object coordinates remain private. Code maps use the owning N_OSO's
 * individual N_FUN ranges; data maps require unique definitions in both
 * files. Missing/ambiguous data names stay unavailable. */
enum xmo_status xmo_object_map_create(struct xmo_image *linked, struct xmo_image *object,
    uint32_t object_index, uint64_t allowance, struct xmo_object_map **);
void xmo_object_map_free(struct xmo_object_map *);
size_t xmo_object_map_bytes(const struct xmo_object_map *);
enum xmo_status xmo_object_pc(const struct xmo_object_map *, uint64_t linked, uint64_t *object);
enum xmo_status xmo_object_address(const struct xmo_object_map *, uint64_t object, uint64_t *linked);
enum xmo_status xmo_object_external(void *, uint32_t symbol, uint64_t addend, uint64_t *token);
#endif
