#include "../src/language/elisp.h"
#include <elfutils/libdwelf.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
size_t probe_size(const char *name) {
#define SIZE(type) if (!strcmp(name, #type)) return sizeof(struct type)
    SIZE(xel_layout); SIZE(xel_reader); SIZE(xel_context); SIZE(xel_frame); SIZE(xel_control); SIZE(xel_stack); SIZE(xel_value); SIZE(xel_value_item); SIZE(xel_binding); SIZE(xel_bindings);
#undef SIZE
    return 0;
}
const char *probe_layout(const char *path, struct xel_layout *out) {
    if (elf_version(EV_CURRENT) == EV_NONE) return "elf_version";
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "open";
    Elf *elf = elf_begin(fd, ELF_C_READ, NULL);
    Dwarf *d = elf ? dwarf_begin_elf(elf, DWARF_C_READ, NULL) : NULL;
    const void *id = NULL; ssize_t n = elf ? dwelf_elf_gnu_build_id(elf, &id) : 0;
    const char *why = xel_layout_build(d, id, n > 0 ? (size_t)n : 0, "31.1", out);
    if (d) dwarf_end(d);
    if (elf) elf_end(elf);
    close(fd); return why;
}
