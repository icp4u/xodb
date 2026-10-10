/* Run the PE reader and the unwind-record validator over the real PE files
 * listed in a response file and print counts only: no names, no paths. */
#include "../src/binary/pe.h"
#include "../src/debug/pe_unwind.h"
#include "check.h"
#include <string.h>
struct bytes {unsigned char *data;size_t size;};
static enum xpe_status read_bytes(void *user,uint64_t at,void *out,size_t n) {
    struct bytes *b=user;if(at>b->size || n>b->size-at)return XPE_IO;
    memcpy(out,b->data+(size_t)at,n);return XPE_OK;
}
static int metadata(void *user,uint32_t rva,void *out,size_t n) {
    return xpe_read_range(user,rva,out,n)==XPE_OK;
}
static void counts(const char *key,const char *const *names,const unsigned long *n,unsigned count) {
    printf("\"%s\":{",key);
    for(unsigned i=1,first=1;i<count;++i)if(n[i]){printf("%s\"%s\":%lu",first?"":",",names[i],n[i]);first=0;}
    printf("}");
}
int main(int argc,char **argv) {
    static const char *const load_names[]={"ok","not_pe","unsupported","malformed","limit","io","changed","cancelled","nomem","not_found"};
    static const char *const unwind_names[]={"ok","malformed","unsupported_version","unsupported_opcode","unsupported_chain",
        "unsupported_epilog","machine_frame","metadata_missing","code_missing","stack_missing","register_missing","limit","no_progress"};
    unsigned long files=0,functions=0,skipped=0,load[10]={0},unwind[13]={0};
    unsigned long long source=0,retained=0;
    /* One argument: @file listing a path per line. */
    CHECK(argc==2 && argv[1][0]=='@');
    FILE *list=fopen(argv[1]+1,"r");CHECK(list);
    char path[8192];
    while(fgets(path,sizeof path,list)) {
        size_t length_=strlen(path);CHECK(length_ && path[length_-1]=='\n');path[length_-1]=0;
        FILE *in=fopen(path,"rb");CHECK(in);CHECK(!fseek(in,0,SEEK_END));long length=ftell(in);CHECK(length>=0);rewind(in);
        struct bytes file={malloc((size_t)length+1),(size_t)length};CHECK(file.data);
        CHECK(fread(file.data,1,file.size,in)==file.size);CHECK(!fclose(in));
        struct xpe_source from={&file,file.size,XPE_FILE,read_bytes};struct xpe_image *image=NULL;
        enum xpe_status status=xpe_load(&from,&image);CHECK(status<10);
        ++files;++load[status];
        if(status==XPE_OK) {
            const struct xpe_info *info=xpe_info(image);
            struct xpu_source records={image,info->image_size,metadata,NULL,NULL,NULL};
            skipped+=info->function_skipped;source+=info->source_bytes;retained+=info->retained_bytes;
            for(unsigned j=0;j<info->function_count;++j) {
                const struct xpe_function *f=xpe_function(image,j);
                enum xpu_status result=xpu_validate(&records,&(struct xpu_function){f->begin,f->end,f->unwind});
                CHECK(result<13);++unwind[result];++functions;
            }
            xpe_destroy(image);
        }
        free(file.data);
    }
    CHECK(!ferror(list) && !fclose(list));
    printf("{\"files\":%lu,\"loaded\":%lu,",files,load[XPE_OK]);counts("load_refused",load_names,load,10);
    printf(",\"functions\":%lu,\"validated\":%lu,\"empty_rows\":%lu,",functions,unwind[XPU_OK],skipped);
    counts("unwind_refused",unwind_names,unwind,13);
    printf(",\"source_bytes\":%llu,\"retained_bytes\":%llu}\n",source,retained);
    return 0;
}
