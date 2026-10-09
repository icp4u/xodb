/* An owned CRuby fixture checks external-memory labels against Ruby reflection. */
#define XODB_RUBY_WATCH_ORACLE
#include "watches.c"
#include <dlfcn.h>
#include <gelf.h>
#include <ruby/debug.h>
static uint64_t symbols;
static unsigned frame_checks,fault_checks,refusal_checks;
static uint64_t symbol_address(const char *wanted) {
    Dl_info image;CHECK(dladdr((void *)rb_hash_aref,&image));
    int fd=open(getenv("XODB_RUBY_ORACLE_IMAGE"),O_RDONLY|O_CLOEXEC);CHECK(fd>=0);
    Elf *elf=elf_begin(fd,ELF_C_READ,NULL);CHECK(elf);Elf_Scn *section=NULL;uint64_t address=0;
    while((section=elf_nextscn(elf,section))) {
        GElf_Shdr sh;CHECK(gelf_getshdr(section,&sh));if(sh.sh_type!=SHT_SYMTAB)continue;
        Elf_Data *data=elf_getdata(section,NULL);CHECK(data && sh.sh_entsize);
        for(size_t i=0;i<sh.sh_size/sh.sh_entsize;++i) {
            GElf_Sym symbol;CHECK(gelf_getsym(data,(int)i,&symbol));
            const char *name=elf_strptr(elf,sh.sh_link,symbol.st_name);
            if(name && !strcmp(name,wanted) && symbol.st_shndx!=SHN_UNDEF) {
                CHECK(!address);address=(uintptr_t)image.dli_fbase+symbol.st_value;
            }
        }
    }
    elf_end(elf);close(fd);CHECK(address);return address;
}
struct fault { size_t calls,fail; };
static int fault_read(void *context,uint64_t at,void *out,size_t n) {
    struct fault *f=context;if(++f->calls==f->fail)return -1;
    return owned_read(NULL,at,out,n);
}
static struct xrb_stack *read_stack(void) {
    uint64_t thread=(uintptr_t)RTYPEDDATA_DATA(rb_thread_current()),ec=0;
    CHECK(!owned_read(NULL,thread+layout.fields[XRB_THREAD_EC].offset,&ec,8));
    struct xrb_stack *stack=calloc(1,sizeof *stack);CHECK(stack);
    struct xrb_reader r={.read=owned_read};xrb_stack_read(&layout,&r,ec,0,stack);
    CHECK(!stack->reason && stack->count>1);
    xrb_stack_names(&layout,&r,symbols,stack);
    return stack;
}
static VALUE capture(VALUE self,VALUE expected) {
    (void)self;
    const char *wanted=StringValueCStr(expected);
    struct xrb_stack *stack=read_stack();
    size_t found=stack->count;
    for(size_t i=0;i<stack->count;++i) {
#ifdef XODB_RUBY_FRAME_ORACLE_NEGATIVE
        stack->frames[i].qualified_name[0]='?';
#endif
        if(!strcmp(stack->frames[i].qualified_name,wanted))found=i;
    }
    if(found==stack->count) {
        fprintf(stderr,"wanted %s; observed:\n",wanted);
        for(size_t i=0;i<stack->count;++i)fprintf(stderr,"%s | %s | %s\n",stack->frames[i].name,
            stack->frames[i].qualified_name,stack->frames[i].name_reason?stack->frames[i].name_reason:"proved");
    }
    CHECK(found<stack->count && !stack->frames[found].name_reason);
    ++frame_checks;
    /* Every failed read in the selected name path must clear that label. */
    stack->frames[0]=stack->frames[found];stack->count=1;
    struct fault fault={0};struct xrb_reader r={.read=fault_read,.context=&fault};
    xrb_stack_names(&layout,&r,symbols,stack);CHECK(!strcmp(stack->frames[0].qualified_name,wanted));
    size_t reads=fault.calls;CHECK(reads>0 && reads<=XRB_READ_LIMIT);
    for(size_t i=1;i<=reads;++i) {
        fault=(struct fault){.fail=i};r=(struct xrb_reader){.read=fault_read,.context=&fault};
        xrb_stack_names(&layout,&r,symbols,stack);
        CHECK(!stack->frames[0].qualified_name[0] && stack->frames[0].name_reason && fault.calls==i);
        ++fault_checks;
    }
    free(stack);return Qnil;
}
static VALUE capture_unproved(VALUE self,VALUE expected) {
    (void)self;const char *why=StringValueCStr(expected);
    struct xrb_stack *stack=read_stack();struct xrb_frame *caller=&stack->frames[1];
    if(!caller->name_reason || strcmp(caller->name_reason,why))fprintf(stderr,"wanted %s, got %s (%s)\n",why,caller->name_reason?caller->name_reason:"proved",caller->qualified_name);
    CHECK(!caller->qualified_name[0] && caller->name_reason && !strcmp(caller->name_reason,why));
    CHECK(caller->name[0] && caller->line && !caller->reason && !caller->line_reason);
    ++refusal_checks;free(stack);return Qnil;
}
static VALUE report(VALUE self) {
    (void)self;fprintf(stderr,"verified %u qualified frame labels, %u read refusals and %u unproved owners\n",frame_checks,fault_checks,refusal_checks);return Qnil;
}
void Init_xodb_frame_names(void) {
    Init_xodb_watches();symbols=symbol_address("ruby_global_symbols");
    VALUE mod=rb_define_module("XodbFrameNames");
    rb_define_singleton_method(mod,"capture",capture,1);
    rb_define_singleton_method(mod,"capture_unproved",capture_unproved,1);
    rb_define_singleton_method(mod,"report",report,0);
}
