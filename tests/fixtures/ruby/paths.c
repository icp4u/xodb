#ifdef XODB_RUBY_PATH_ORACLE
#define XODB_RUBY_WATCH_ORACLE
#endif
#include "watches.c"
#ifdef XODB_RUBY_PATH_ORACLE
#include <dlfcn.h>
#include <gelf.h>
static struct xrb_path_context path_context;
static uint64_t elf_symbol(const char *wanted) {
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
    elf_end(elf);close(fd);if(!address){fprintf(stderr,"missing symbol %s\n",wanted);abort();}return address;
}
#endif
static void set(VALUE hash,const char *name,VALUE value) {rb_hash_aset(hash,rb_str_new_cstr(name),value);}
static VALUE path_oracle(VALUE self,VALUE root,VALUE expression,VALUE expected,VALUE reason) {
    (void)self;
    const char *text=StringValueCStr(expression),*why=NIL_P(reason)?NULL:StringValueCStr(reason);
#ifdef XODB_RUBY_PATH_ORACLE
    struct xrb_reader r={.read=owned_read};struct xrb_path_value actual;
    xrb_path_read(&layout,&r,&path_context,(uintptr_t)root,text,&actual);
    if(why) {
        if(!actual.reason || strcmp(actual.reason,why)) {fprintf(stderr,"%s: wanted %s got %s\n",text,why,actual.reason?actual.reason:"value");abort();}
    } else {
        if(actual.reason) {fprintf(stderr,"%s: %s\n",text,actual.reason);abort();}
#ifdef XODB_RUBY_PATH_ORACLE_NEGATIVE
        actual.tagged ^= 2; /* A mismatched element must fail the oracle. */
#endif
        CHECK(actual.tagged==expected && actual.address);
    }
    ++verified;
#else
    (void)text;(void)why;
#endif
    VALUE result=rb_hash_new();
    set(result,"expression",expression);set(result,"root",ULL2NUM((uint64_t)root));
    set(result,"tagged",ULL2NUM((uint64_t)expected));set(result,"reason",reason);
    if(NIL_P(reason))set(result,"sample",sample(Qnil,expected));
    return result;
}
static VALUE wrong_seed(VALUE self,VALUE root,VALUE expression) {
    (void)self;
#ifdef XODB_RUBY_PATH_ORACLE
    uint8_t salt[24];memcpy(salt,(void *)(uintptr_t)path_context.hash_salt,sizeof salt);
    /* Both halves change: integer/static-symbol and SipHash string key paths. */
    salt[0]^=0x40;salt[8]^=0x40;
    struct xrb_path_context bad=path_context;bad.hash_salt=(uintptr_t)salt;
    struct xrb_reader r={.read=owned_read};struct xrb_path_value actual;
    xrb_path_read(&layout,&r,&bad,(uintptr_t)root,StringValueCStr(expression),&actual);
    CHECK(actual.reason && !strcmp(actual.reason,"RubyPathHashUnproved") && !actual.address);
    ++verified;
#else
    (void)root;(void)expression;
#endif
    return Qnil;
}
#ifdef XODB_RUBY_PATH_ORACLE
struct path_fault { size_t calls, fail; };
static int fault_read(void *context,uint64_t address,void *out,size_t n) {
    struct path_fault *fault=context;
    if(++fault->calls==fault->fail)return -1;
    return owned_read(NULL,address,out,n);
}
#endif
static VALUE path_faults(VALUE self,VALUE root,VALUE expression) {
    (void)self;
#ifdef XODB_RUBY_PATH_ORACLE
    const char *text=StringValueCStr(expression);
    struct path_fault fault={0};struct xrb_reader r={.context=&fault,.read=fault_read};
    struct xrb_path_value actual;
    xrb_path_read(&layout,&r,&path_context,(uintptr_t)root,text,&actual);
    CHECK(!actual.reason && actual.address && fault.calls);
    size_t reads=fault.calls;
    for(size_t i=1;i<=reads;++i) {
        fault=(struct path_fault){.fail=i};r=(struct xrb_reader){.context=&fault,.read=fault_read};
        xrb_path_read(&layout,&r,&path_context,(uintptr_t)root,text,&actual);
        CHECK(actual.reason && !actual.address && !actual.tagged && fault.calls==i);
    }
    return SIZET2NUM(reads);
#else
    (void)root;(void)expression;return INT2NUM(0);
#endif
}
#ifdef XODB_RUBY_PATH_ORACLE
struct overlay { uint64_t address,value; size_t width,hits; };
static int overlay_read(void *context,uint64_t address,void *out,size_t n) {
    struct overlay *o=context;
    if(owned_read(NULL,address,out,n))return -1;
    if(address==o->address && n==o->width) {
        memcpy(out,&o->value,n);++o->hits;
    }
    return 0;
}
#endif
static VALUE corrupt_metadata(VALUE self,VALUE root,VALUE expression) {
    (void)self;
#ifdef XODB_RUBY_PATH_ORACLE
    const char *text=StringValueCStr(expression);CHECK(RB_TYPE_P(root,T_HASH));
    struct xrb_reader baseline={.read=owned_read};struct xrb_path_value actual;
    xrb_path_read(&layout,&baseline,&path_context,root,text,&actual);CHECK(!actual.reason);
    uint64_t table=root+layout.sizes[XRB_T_HASH];
    struct overlay cases[8];size_t count=0;
    cases[count++]=(struct overlay){root,(RBASIC(root)->flags&~RUBY_T_MASK)|T_OBJECT,8,0};
    cases[count++]=(struct overlay){root+layout.fields[XRB_HASH_DEFAULT].offset,Qtrue,8,0};
    if(RB_FL_TEST_RAW(root,RUBY_FL_USER3)) {
        cases[count++]=(struct overlay){table+layout.fields[XRB_ST_POWER].offset,63,1,0};
        cases[count++]=(struct overlay){table+layout.fields[XRB_ST_COUNT].offset,UINT64_MAX,8,0};
        cases[count++]=(struct overlay){table+layout.fields[XRB_ST_ENTRIES].offset,0,8,0};
        uint64_t entries=0,hash=0;uint32_t start=0;
        CHECK(!owned_read(NULL,table+layout.fields[XRB_ST_ENTRIES].offset,&entries,8));
        CHECK(!owned_read(NULL,table+layout.fields[XRB_ST_START].offset,&start,4));
        uint64_t at=entries+(uint64_t)start*layout.sizes[XRB_T_ST_ENTRY]+layout.fields[XRB_ST_HASH].offset;
        CHECK(!owned_read(NULL,at,&hash,8) && hash!=UINT64_MAX);
        cases[count++]=(struct overlay){at,hash^64,8,0};
    } else {
        uint64_t hint=table+layout.fields[XRB_AR_HINTS].offset;uint8_t value=0;
        CHECK(!owned_read(NULL,hint,&value,1) && value);
        cases[count++]=(struct overlay){hint,value^64,1,0};
    }
    for(size_t i=0;i<count;++i) {
        struct xrb_reader r={.context=&cases[i],.read=overlay_read};
        xrb_path_read(&layout,&r,&path_context,root,text,&actual);
        CHECK(cases[i].hits && actual.reason && !actual.tagged && !actual.address);
    }
    return SIZET2NUM(count);
#else
    (void)root;(void)expression;return INT2NUM(0);
#endif
}
static VALUE shape(VALUE self,VALUE root) {
    (void)self;VALUE out=rb_hash_new();
    set(out,"st",RB_TYPE_P(root,T_HASH)&&RB_FL_TEST_RAW(root,RUBY_FL_USER3)?Qtrue:Qfalse);
    set(out,"tagged",ULL2NUM((uint64_t)root));return out;
}
void Init_xodb_paths(void) {
    Init_xodb_watches();
#ifdef XODB_RUBY_PATH_ORACLE
#define ADDRESS(field,name) path_context.field=elf_symbol(name)
    ADDRESS(symbols,"ruby_global_symbols");ADDRESS(hash_salt,"hash_salt");
    ADDRESS(hash_class,"rb_cHash");ADDRESS(array_class,"rb_cArray");ADDRESS(string_class,"rb_cString");
    ADDRESS(integer_class,"rb_cInteger");ADDRESS(symbol_class,"rb_cSymbol");
    ADDRESS(hash_aref,"rb_hash_aref");ADDRESS(array_aref,"rb_ary_aref");
    ADDRESS(string_hash,"rb_str_hash_m");ADDRESS(string_eql,"rb_str_eql");
    ADDRESS(object_hash,"rb_obj_hash");ADDRESS(object_eql,"rb_obj_equal");ADDRESS(numeric_eql,"num_eql");
    ADDRESS(any_hash,"rb_any_hash");ADDRESS(any_cmp,"rb_any_cmp");
#undef ADDRESS
#endif
    VALUE mod=rb_define_module("XodbPaths");
    rb_define_singleton_method(mod,"oracle",path_oracle,4);
    rb_define_singleton_method(mod,"wrong_seed",wrong_seed,2);
    rb_define_singleton_method(mod,"shape",shape,1);
    rb_define_singleton_method(mod,"faults",path_faults,2);
    rb_define_singleton_method(mod,"corrupt_metadata",corrupt_metadata,2);
}
