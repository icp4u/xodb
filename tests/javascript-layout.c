#include "../src/language/javascript.h"
#include <assert.h>
#include <fcntl.h>
#include <dwarf.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static unsigned direct, indirect, unrelated;
static void handles(Dwarf_Die *die, unsigned depth) {
    assert(depth < 32);
    int tag = dwarf_tag(die);
    const char *name = dwarf_diename(die);
    if ((tag == DW_TAG_class_type || tag == DW_TAG_structure_type) && name &&
        (!strncmp(name, "Local<", 6) || !strncmp(name, "Tagged<", 7))) {
        int mode = xjs_dwarf_handle(die);
        if (mode == 1) ++direct;
        else if (mode == 2) ++indirect;
        else ++unrelated;
    }
    Dwarf_Die child;
    if (!dwarf_child(die, &child)) do { handles(&child, depth + 1); } while (!dwarf_siblingof(&child, &child));
}
int main(int argc, char **argv) {
    assert(argc == 3);
    for (int i = 1; i < argc; ++i) {
        int fd = open(argv[i], O_RDONLY); assert(fd >= 0);
        Dwarf *d = dwarf_begin(fd, DWARF_C_READ); assert(d);
        struct xjs_dwarf_profile p; xjs_dwarf_profile(d, &p);
        if (i == 1) {
            if (p.error) fprintf(stderr, "%s\n", p.error);
            /* Some compilers omit unused namespace constants. They still
             * must find the nested ScopeInfo enum and the array offset;
             * absence must not become an asserted frame configuration. */
            assert(!p.error && (p.fields & 0x7f) == 0x7f);
            printf("DWARF frame configuration: %s\n", p.frame_config ? "proved" : "unavailable (omitted constants)");
            Dwarf_Off offset = 0, next; size_t header;
            while (!dwarf_nextcu(d, offset, &next, &header, NULL, NULL, NULL)) {
                Dwarf_Die unit; assert(dwarf_offdie(d, offset + header, &unit));
                handles(&unit, 0); assert(next > offset); offset = next;
            }
            assert(direct && indirect && unrelated);
        } else assert(p.error);
        dwarf_end(d); close(fd);
    }
    puts("JavaScript DWARF: namespaces, nested constants and conflicting layout checks passed");
}
