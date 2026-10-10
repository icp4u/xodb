/* Periodic: malformed bounded snapshots; successful builds conserve all fds. */
#define FD_TREEMAP_NO_MAIN
#include "runtime-fdtreemap.c"
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    struct fixture f;fixture(&f);
    struct xrt_fdtreemap_options o=options;o.max_nodes=16;o.max_text=256;
    if (size>0) o.max_nodes=16+data[0]%49;
    if (size>1) o.max_depth=1+data[1]%32;
    if (size>2) o.max_text=256+data[2]*3;
    for (size_t k=3;k+4<size && k<128;k+=5) {
        struct xrt_fd *fd=&f.fds[data[k]%12];
        switch (data[k+1]%8) {
        case 0:fd->link=data[k+2]*4;fd->link_length=(uint16_t)(data[k+3]*4);break;
        case 1:fd->flags=data[k+2];break;
        case 2:fd->kind=data[k+2]%16;break;
        case 3:fd->fd=(int8_t)data[k+2];break;
        case 4:f.names[data[k+2]]=data[k+3];break;
        case 5:f.rows[data[k]%12].inode=data[k+2];break;
        case 6:f.processes[data[k]%3].flags=data[k+2];break;
        case 7:f.rates[data[k]%12].read=data[k+2]==0?NAN:data[k+2];break;
        }
    }
    struct xrt_fdtreemap *t=NULL;enum xrt_status status=xrt_fdtreemap_build(&f.snapshot,&f.flow,&o,&t);
    if (status==XRT_OK) {
        CHECK(t && t->nodes[0].total.descriptors==f.snapshot.fd_count && t->count<=o.max_nodes && t->text_length<=o.max_text);
        uint32_t total=0;for (uint32_t i=0;i<t->count;++i) total+=t->nodes[i].own.descriptors+t->nodes[i].overflow.descriptors;
        CHECK(total==f.snapshot.fd_count);
        for (uint32_t i=0;i<t->fd_count;++i) CHECK((t->fd_nodes[i]&~XRT_FDT_OVERFLOW_BIT)<t->count);
        static char seen[64][4098];
        for (uint32_t i=0;i<t->count;++i) {
            char *name=seen[i];size_t needed;uint32_t found;
            CHECK(xrt_fdtreemap_path(t,i,name,sizeof seen[i],&needed)==XRT_OK && needed==strlen(name)+1);
            CHECK(xrt_fdtreemap_relocate(t,i,t,&found)==XRT_OK && found==i);
            CHECK(!i || t->nodes[i].kind || t->nodes[i].name_length); /* empty components dropped */
            for (uint32_t j=0;j<i;++j) CHECK(t->nodes[i].kind!=t->nodes[j].kind || strcmp(seen[i],seen[j])); /* injective */
        }
        geometry(t,0,size?1+data[0]%16:1,1.6);xrt_fdtreemap_free(t);
    } else CHECK(!t && (status==XRT_INVALID_ARGUMENT || status==XRT_OUT_OF_MEMORY));
    return 0;
}
