#define _POSIX_C_SOURCE 200809L
#include "../src/debug/macho_object.h"
#include "check.h"
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

struct file { int fd; uint64_t bytes, calls; };
static enum xmo_status read_file(void *arg, uint64_t at, void *out, size_t n) {
    struct file *f=arg;
    if (n>XMO_MAX_READ_BYTES-f->bytes || ++f->calls>XMO_MAX_READS) return XMO_LIMIT;
    if (pread(f->fd,out,n,(off_t)at)!=(ssize_t)n) return XMO_IO;
    f->bytes+=n;return XMO_OK;
}
static struct xmo_image *open_image(const char *path, struct file *file) {
    file->fd=open(path,O_RDONLY);CHECK(file->fd>=0);
    struct stat st;CHECK(fstat(file->fd,&st)==0 && st.st_size>=0);
    struct xmo_source source={file,(uint64_t)st.st_size,XMO_FILE,read_file};
    struct xmo_image *image=NULL;
    CHECK(xmo_load(&source,NULL,&image)==XMO_OK);
    CHECK(xmo_prepare_labels(image)==XMO_OK);
    const struct xmo_symbol *unused=NULL;
    CHECK(xmo_symbol_unique(image,"__test_nonexistent_symbol__",&unused)==XMO_NOT_FOUND);
    return image;
}
int main(int argc, char **argv) {
    CHECK(argc==6);
    struct file lf={0},of={0};
    struct xmo_image *linked=open_image(argv[1],&lf),*object=open_image(argv[2],&of);
    uint32_t index=(uint32_t)strtoul(argv[3],NULL,0);
    uint64_t pc=strtoull(argv[4],NULL,0),limit=strtoull(argv[5],NULL,0),object_pc=0;
    struct xmo_object_map *map=NULL;
    enum xmo_status status=xmo_object_map_create(linked,object,index,limit,&map);
    printf("map\t%s\n",xmo_status_name(status));
    struct xmo_dwarf dwarf={0};
    if (status==XMO_OK) {
        CHECK(xmo_object_map_bytes(map)<=limit);
        status=xmo_dwarf_build_object(object,limit-xmo_object_map_bytes(map),xmo_object_external,NULL,&dwarf);
        printf("dwarf\t%s\n",xmo_status_name(status));
    }
    if (status==XMO_OK) {
        status=xmo_object_pc(map,pc,&object_pc);
        printf("pc\t%s\t%llx\n",xmo_status_name(status),(unsigned long long)object_pc);
        if (status==XMO_OK) {
            uint64_t back=0;CHECK(xmo_object_address(map,object_pc,&back)==XMO_OK && back==pc);
            CHECK(elf_version(EV_CURRENT)!=EV_NONE);
            Elf *elf=elf_memory((char *)dwarf.bytes,dwarf.size);CHECK(elf);
            Dwarf *debug=dwarf_begin_elf(elf,DWARF_C_READ,NULL);CHECK(debug);
            Dwarf_Off off=0,next;size_t head;
            while (dwarf_nextcu(debug,off,&next,&head,NULL,NULL,NULL)==0) {
                Dwarf_Die die;CHECK(dwarf_offdie(debug,off+head,&die));
                Dwarf_Line *row=dwarf_getsrc_die(&die,object_pc);
                if (row) {
                    int line=0,column=0;Dwarf_Addr address=0;
                    CHECK(dwarf_lineno(row,&line)==0 && dwarf_linecol(row,&column)==0 && dwarf_lineaddr(row,&address)==0);
                    CHECK(xmo_object_address(map,address,&back)==XMO_OK);
                    printf("source\t%s\t%d\t%d\t%llx\n",dwarf_linesrc(row,NULL,NULL),line,column,(unsigned long long)back);
                }
                off=next;
            }
            CHECK(dwarf_end(debug)==0 && elf_end(elf)==0);
        }
    }
    xmo_dwarf_free(&dwarf);xmo_object_map_free(map);xmo_destroy(object);xmo_destroy(linked);
    CHECK(close(of.fd)==0 && close(lf.fd)==0);return 0;
}
