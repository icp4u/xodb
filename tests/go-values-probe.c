/* Host-only bridge for the owned Go fixture. Never loaded into the target. */
#include "../src/language/go_value.h"
#include <fcntl.h>
#include <unistd.h>
const char *probe_layout(const char *path, const uint8_t *id, size_t n, struct xgv_layout *out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return "fixture open failed";
    Dwarf *dwarf = dwarf_begin(fd, DWARF_C_READ);
    const char *why = xgv_layout_build(dwarf, id, n, out);
    if (!why) {
        /* The shared walker must still accept the existing stack profile. */
        struct xgo_layout stack;
        why = xgo_layout_build(dwarf, id, n, &stack);
    }
    if (dwarf) dwarf_end(dwarf);
    close(fd);
    return why;
}
size_t probe_size(unsigned which) {
    switch (which) {
    case 0: return sizeof(struct xgv_layout);
    case 1: return sizeof(struct xgo_reader);
    case 2: return sizeof(struct xgv_type_info);
    case 3: return sizeof(struct xgv_interface);
    case 4: return sizeof(struct xgv_channel);
    default: return 0;
    }
}

const char *probe_stack(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return "fixture open failed";
    Dwarf *dwarf = dwarf_begin(fd, DWARF_C_READ);
    struct xgo_layout layout; const uint8_t id = 1;
    const char *why = xgo_layout_build(dwarf, &id, 1, &layout);
    if (dwarf) dwarf_end(dwarf);
    close(fd);
    return why;
}
