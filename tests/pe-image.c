#include "../src/binary/pe.h"
#include "check.h"
#include <string.h>
struct bytes {unsigned char *data;size_t size, reads, fail_at;enum xpe_status failure;};
static unsigned le32(const unsigned char *p){return (unsigned)p[0]|(unsigned)p[1]<<8|(unsigned)p[2]<<16|(unsigned)p[3]<<24;}
static void put32(unsigned char *p,unsigned value){for(unsigned i=0;i<4;++i)p[i]=(unsigned char)(value>>(i*8));}
static enum xpe_status read_bytes(void *user,uint64_t at,void *out,size_t n) {
    struct bytes *b=user;if(++b->reads==b->fail_at)return b->failure;
    if(at>b->size || n>b->size-at)return XPE_IO;
    memcpy(out,b->data+(size_t)at,n);return XPE_OK;
}
int main(int argc,char **argv) {
    CHECK(argc>=2);FILE *in=fopen(argv[1],"rb");CHECK(in);CHECK(!fseek(in,0,SEEK_END));long length=ftell(in);CHECK(length>0);rewind(in);
    struct bytes file={.data=malloc((size_t)length),.size=(size_t)length};CHECK(file.data);CHECK(fread(file.data,1,file.size,in)==file.size);CHECK(!fclose(in));
    struct xpe_source source={&file,file.size,XPE_FILE,read_bytes};struct xpe_image *p=NULL;
    enum xpe_status status=xpe_load(&source,&p);fprintf(stderr,"file status=%u\n",status);if(argc>2 && !strncmp(argv[2],"status=",7)){CHECK(status==(enum xpe_status)strtoul(argv[2]+7,NULL,10));CHECK((p!=NULL)==(status==XPE_OK));xpe_destroy(p);free(file.data);return 0;}
    CHECK(status==XPE_OK);
    if(argc>2 && !strncmp(argv[2],"functions=",10)) {
        /* functions=KEPT,SKIPPED: empty rows are counted, never looked up. */
        char *end;unsigned long kept=strtoul(argv[2]+10,&end,10),skipped=strtoul(end+1,NULL,10);
        const struct xpe_info *info=xpe_info(p);
        CHECK(info->function_count==kept && info->function_skipped==skipped);
        for(unsigned i=0;i<info->function_count;i+=info->function_count/64+1) {
            const struct xpe_function *f=xpe_function(p,i);
            CHECK(f->begin<f->end && xpe_function_at(p,f->begin)==f && xpe_function_at(p,f->end-1)==f);
        }
        printf("functions=%u skipped=%u source=%llu reads=%llu retained=%llu\n",info->function_count,info->function_skipped,
               (unsigned long long)info->source_bytes,(unsigned long long)info->source_reads,(unsigned long long)info->retained_bytes);
        xpe_destroy(p);free(file.data);return 0;
    }
    if(argc>2 && !strcmp(argv[2],"faults")) {
        size_t calls=file.reads;xpe_destroy(p);p=NULL;CHECK(calls>10);
        for(enum xpe_status failure=XPE_IO;failure<=XPE_CANCELLED;++failure) {
            for(size_t at=1;at<=calls;++at) {
                file.reads=0;file.fail_at=at;file.failure=failure;
                CHECK(xpe_load(&source,&p)==failure && !p);
            }
            file.reads=0;file.fail_at=0;CHECK(xpe_load(&source,&p)==XPE_OK);
            file.fail_at=file.reads+1;unsigned char byte;
            CHECK(xpe_read_rva(p,0,&byte,1)==failure);xpe_destroy(p);p=NULL;
        }
        printf("source faults: %zu parse read boundaries and post-load reads passed\n",calls);
        free(file.data);return 0;
    }
    if(argc>2 && !strcmp(argv[2],"bound")){CHECK(xpe_info(p)->import_count==1);const struct xpe_import *entry=xpe_import(p,0);CHECK(entry->lookup_unavailable && !entry->name && !entry->by_ordinal);xpe_destroy(p);free(file.data);return 0;}
    const struct xpe_info *info=xpe_info(p);CHECK(info && info->machine==0x8664 && info->preferred_base==0x180000000);
    uint64_t parsed_bytes=info->source_bytes,parsed_reads=info->source_reads;
    unsigned char later[4];
    CHECK(xpe_read_range(p,0,later,4)==XPE_OK && later[0]=='M' && later[1]=='Z');
    CHECK(info->source_bytes==parsed_bytes && info->source_reads==parsed_reads);
    CHECK(xpe_read_range(p,0,later,4097)==XPE_LIMIT);
    CHECK(xpe_read_range(p,info->image_size,later,4)==XPE_MALFORMED);
    const struct xpe_export *inner=xpe_find_export(p,"pe_inner"),*outer=xpe_find_export(p,"pe_outer"),*forward=xpe_find_export(p,"forwarded_pid"),*data=xpe_find_export(p,"exported_counter");
    CHECK(inner && outer && forward && data);CHECK(inner->ordinal==(argc>2 && !strcmp(argv[2],"wrong-result")?8:7) && outer->ordinal==11);
    CHECK(forward->forwarder && !strcmp(forward->forwarder,"KERNEL32.GetCurrentProcessId"));
    CHECK(xpe_function_at(p,inner->rva) && xpe_function_at(p,outer->rva));CHECK(!xpe_function_at(p,data->rva));
    /* Address-ordered labels: exact starts only, and never a forwarder. */
    CHECK(!strcmp(xpe_export_name_at(p,inner->rva),"pe_inner") && !strcmp(xpe_export_name_at(p,outer->rva),"pe_outer"));
    CHECK(!xpe_export_name_at(p,inner->rva+1) && !xpe_export_name_at(p,forward->rva) && !xpe_export_name_at(p,0));
    for(unsigned i=0;i<info->export_name_count;++i) {
        const struct xpe_export_name *n=xpe_export_name(p,i);const struct xpe_export *e=xpe_export(p,n->export_index);
        if(!e->rva || e->forwarder)continue;
        const char *first=NULL;
        for(unsigned j=0;j<info->export_name_count && !first;++j) {
            const struct xpe_export *other=xpe_export(p,xpe_export_name(p,j)->export_index);
            if(other->rva==e->rva && !other->forwarder)first=xpe_export_name(p,j)->name;
        }
        CHECK(xpe_export_name_at(p,e->rva)==first);
    }
    CHECK(info->import_count==1 && !strcmp(xpe_import(p,0)->dll,"KERNEL32.dll") && !strcmp(xpe_import(p,0)->name,"GetCurrentProcessId"));
    CHECK(info->codeview_count==1 && xpe_codeview(p,0)->age==1 && strstr(xpe_codeview(p,0)->path,"owned-pe.pdb"));
    struct bytes memory={.data=calloc(1,info->image_size),.size=info->image_size};CHECK(memory.data);memcpy(memory.data,file.data,info->headers_size);
    for(unsigned i=0;i<info->section_count;++i){const struct xpe_section *s=xpe_section(p,i);if(s->raw_size)memcpy(memory.data+s->rva,file.data+s->raw_offset,s->raw_size);}
    /* A loaded debug directory's disk pointer is irrelevant. Force it out of
     * range so using file offsets on a memory image cannot pass by accident. */
    unsigned pe=le32(memory.data+60),debug=le32(memory.data+pe+24+112+6*8);
    CHECK(debug && debug+28<=memory.size);put32(memory.data+debug+24,0xfffffff0u);
    source=(struct xpe_source){&memory,memory.size,XPE_MEMORY,read_bytes};struct xpe_image *loaded=NULL;status=xpe_load(&source,&loaded);fprintf(stderr,"memory status=%u\n",status);CHECK(status==XPE_OK);
    CHECK(xpe_validate_loaded_headers(p,&source)==XPE_OK);
    unsigned optional=pe+24,table=optional+(unsigned)memory.data[pe+20]+((unsigned)memory.data[pe+21]<<8);
    /* A loader can relocate ImageBase; section placement cannot silently change. */
    unsigned saved_base=le32(memory.data+optional+24);
    put32(memory.data+optional+24,0x70000000u);
    CHECK(xpe_validate_loaded_headers(p,&source)==XPE_OK);
    put32(memory.data+optional+24,saved_base);
    unsigned saved_stamp=le32(memory.data+pe+8);
    put32(memory.data+pe+8,saved_stamp+1);
    CHECK(xpe_validate_loaded_headers(p,&source)==XPE_CHANGED);
    put32(memory.data+pe+8,saved_stamp);
    unsigned saved_size=le32(memory.data+table+8);
    put32(memory.data+table+8,saved_size+1);
    CHECK(xpe_validate_loaded_headers(p,&source)==XPE_CHANGED);
    put32(memory.data+table+8,saved_size);
    CHECK(xpe_find_export(loaded,"pe_inner")->rva==inner->rva);
    CHECK(xpe_info(loaded)->function_count==info->function_count);
    CHECK(!memcmp(xpe_codeview(loaded,0)->guid,xpe_codeview(p,0)->guid,16));
    unsigned char zero[4];CHECK(xpe_read_rva(loaded,data->rva,zero,sizeof zero)==XPE_OK && !zero[0] && !zero[1] && !zero[2] && !zero[3]);
    for(unsigned i=0;i<info->export_name_count;++i){const struct xpe_export_name *n=xpe_export_name(p,i);const struct xpe_export *e=xpe_export(p,n->export_index);printf("export\t%s\t%u\t%u\t%s\n",n->name,e->ordinal,e->rva,e->forwarder?e->forwarder:"");}
    for(unsigned i=0;i<info->function_count;++i){const struct xpe_function *f=xpe_function(p,i);printf("function\t%u\t%u\t%u\n",f->begin,f->end,f->unwind);}
    printf("counts sections=%u exports=%u names=%u imports=%u functions=%u source=%llu retained=%llu\n",info->section_count,info->export_count,info->export_name_count,info->import_count,info->function_count,(unsigned long long)info->source_bytes,(unsigned long long)info->retained_bytes);
    xpe_destroy(loaded);xpe_destroy(p);free(memory.data);free(file.data);return 0;
}
