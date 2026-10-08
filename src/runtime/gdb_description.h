#ifndef XODB_GDB_DESCRIPTION_H
#define XODB_GDB_DESCRIPTION_H
#include "xrt_arch.h"
#define XRT_GDB_REGISTERS_MAX 1024
#define XRT_GDB_REGISTER_BYTES_MAX (4u * 1024u * 1024u)
#define XRT_GDB_XML_MAX (1024u * 1024u)
struct xrt_gdb_register {
    char name[64];
    uint32_t number, offset, bytes;
};
struct xrt_gdb_description {
    char architecture[64];
    const struct xrt_arch *arch;
    struct xrt_gdb_register registers[XRT_GDB_REGISTERS_MAX];
    uint32_t count, register_bytes, next_number, xml_bytes, documents;
    char reason[128];
};
/* Includes are remote qXfer annexes only. The loader allocates *text; the
 * parser frees it. No local file, URL or XML entity is ever opened. */
typedef enum xrt_status (*xrt_gdb_annex)(void *ctx, const char *name,
                                        char **text, size_t *size);
enum xrt_status xrt_gdb_description_parse(struct xrt_gdb_description *,
                                          const char *, size_t,
                                          xrt_gdb_annex, void *);
const struct xrt_gdb_register *xrt_gdb_description_register(
    const struct xrt_gdb_description *, const struct xrt_register_desc *);
enum xrt_status xrt_gdb_description_decode(const struct xrt_gdb_description *,
                                            const uint8_t *, size_t,
                                            struct xrt_registers *);
#endif
