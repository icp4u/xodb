#ifndef XODB_LANGUAGE_GO_TYPE_INDEX_H
#define XODB_LANGUAGE_GO_TYPE_INDEX_H
#include <elfutils/libdw.h>
#include <stdint.h>
#include <stddef.h>
enum { XGO_META_KIND=1, XGO_META_RUNTIME=2, XGO_META_KEY=4, XGO_META_ELEM=8, XGO_META_IFACE=16 };
struct xgo_type_metadata {
    Dwarf_Die key, element;
    uint64_t runtime_offset;
    unsigned kind, present, interface_nonempty;
};
/* Go linker extensions: runtime_offset is section relative, despite its
 * DW_FORM_addr encoding. No target/load address arithmetic is done here. */
const char *xgo_type_metadata(Dwarf_Die *, struct xgo_type_metadata *);
struct xgo_type_index;
const char *xgo_type_index_create(Dwarf *, struct xgo_type_index **);
void xgo_type_index_free(struct xgo_type_index *);
const char *xgo_type_index_find(const struct xgo_type_index *, uint64_t runtime_offset, Dwarf_Die *);
size_t xgo_type_index_count(const struct xgo_type_index *);
#endif
