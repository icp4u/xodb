#include "../src/language/go_map.h"
#include <fcntl.h>
#include <unistd.h>
const char *probe_map_layout(const char *path, const uint8_t *id, size_t n, struct xgm_layout *out) {
    int fd=open(path,O_RDONLY); if(fd<0) return "fixture open failed";
    Dwarf *dw=dwarf_begin(fd,DWARF_C_READ);
    const char *why=xgm_layout_build(dw,id,n,out);
    if(dw)dwarf_end(dw);
    close(fd);return why;
}
size_t probe_map_size(unsigned which) {
    return which==0 ? sizeof(struct xgm_layout) : which==1 ? sizeof(struct xgm_page) : 0;
}
