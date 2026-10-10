#include "../src/binary/pe.h"
#include <string.h>
struct input {const unsigned char *data;size_t size;};
static enum xpe_status bytes(void *user,uint64_t at,void *out,size_t size) {
    struct input *in=user;if(at>in->size || size>in->size-at)return XPE_IO;
    memcpy(out,in->data+(size_t)at,size);return XPE_OK;
}
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size) {
    if(!size)return 0;
    struct input in={data+1,size-1};struct xpe_source source={&in,in.size,(data[0]&1)?XPE_MEMORY:XPE_FILE,bytes};
    struct xpe_image *p=NULL;
    if(xpe_load(&source,&p)==XPE_OK) {
        const struct xpe_info *info=xpe_info(p);
        struct xpe_source loaded=source;loaded.layout=XPE_MEMORY;
        (void)xpe_validate_loaded_headers(p,&loaded);
        for(unsigned i=0;i<info->export_name_count;++i){const struct xpe_export_name *n=xpe_export_name(p,i);(void)xpe_find_export(p,n->name);(void)xpe_export_name_at(p,xpe_export(p,n->export_index)->rva);}
        for(unsigned i=0;i<info->function_count;++i){const struct xpe_function *f=xpe_function(p,i);(void)xpe_function_at(p,f->begin);(void)xpe_function_at(p,f->end);}
        xpe_destroy(p);
    }
    return 0;
}
