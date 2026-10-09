/* Independent CRuby public-macro oracle; executed by the owned fixture itself. */
#define _GNU_SOURCE 1
#include <ruby.h>
#include <ruby/encoding.h>
#include <sys/prctl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef XODB_RUBY_WATCH_ORACLE
#include "../../../src/language/ruby.h"
#include <assert.h>
#include <fcntl.h>
#include <sys/uio.h>
#include <unistd.h>
static struct xrb_layout layout;
static unsigned verified;
static int owned_read(void *unused,uint64_t address,void *out,size_t n) {
    (void)unused;
    struct iovec local={out,n},remote={(void *)(uintptr_t)address,n};
    return process_vm_readv(getpid(),&local,1,&remote,1,0)==(ssize_t)n?0:-1;
}
#endif
__attribute__((noinline)) void xodb_ruby_watch_stop(VALUE thread) {
    __asm__ volatile("" : : "m"(thread) : "memory"); /* WATCH_STOP */
}
static VALUE sample(VALUE self,VALUE v) {
    (void)self;
    unsigned kind=0;int complete=1;uint64_t bits=0;
    unsigned char bytes[4096];size_t n=0;
    if (RB_FIXNUM_P(v)) {kind=1;bits=(uint64_t)FIX2LONG(v);n=8;}
    else if (RB_FLOAT_TYPE_P(v)) {double number=RFLOAT_VALUE(v);kind=2;memcpy(&bits,&number,8);n=8;}
    else if (NIL_P(v)) kind=3;
    else if (v==Qfalse) kind=4;
    else if (v==Qtrue) kind=5;
    else if (RB_TYPE_P(v,T_STRING)) {
        long length=RSTRING_LEN(v);int encoding=RB_ENCODING_GET_INLINED(v);
        kind=6;
        if (length<0 || length>4095 || encoding==RUBY_ENCODING_INLINE_MAX) complete=0;
        else {bytes[0]=(unsigned char)encoding;memcpy(bytes+1,RSTRING_PTR(v),(size_t)length);n=(size_t)length+1;}
    } else complete=0;
    if (kind==1 || kind==2) for(size_t i=0;i<n;++i) bytes[i]=(unsigned char)(bits>>(i*8));
#ifdef XODB_RUBY_WATCH_ORACLE
    struct xrb_reader reader={.read=owned_read};struct xrb_sample got;
    xrb_sample_read(&layout,&reader,(uintptr_t)v,&got);
    assert((got.reason==NULL)==complete);
    if(complete)assert(got.kind==kind&&got.size==n&&!memcmp(got.bytes,bytes,n));
    ++verified;
#endif
    VALUE out=rb_hash_new();
    rb_hash_aset(out,rb_str_new_cstr("kind"),UINT2NUM(kind));
    rb_hash_aset(out,rb_str_new_cstr("complete"),complete?Qtrue:Qfalse);
    char hex[8193];size_t used=complete?n:0;
    for(size_t i=0;i<used;++i)snprintf(hex+i*2,3,"%02x",bytes[i]);
    hex[used*2]=0;
    rb_hash_aset(out,rb_str_new_cstr("hex"),rb_str_new_cstr(hex));
    return out;
}
static VALUE stop(VALUE self) {
    (void)self;
#ifdef XODB_RUBY_WATCH_ORACLE
    fprintf(stderr,"verified %u scalar samples\n",verified);
#endif
    xodb_ruby_watch_stop(rb_thread_current());return Qnil;
}
void Init_xodb_watches(void) {
    (void)prctl(PR_SET_PTRACER,PR_SET_PTRACER_ANY,0,0,0);
#ifdef XODB_RUBY_WATCH_ORACLE
    int fd=open(getenv("XODB_RUBY_ORACLE_IMAGE"),O_RDONLY|O_CLOEXEC);assert(fd>=0);
    Dwarf *dw=dwarf_begin(fd,DWARF_C_READ);assert(dw);uint8_t id[]={1};
    const char *why=xrb_layout_build(dw,id,sizeof id,XRB_VERSION,XRB_REVISION,&layout);
    if(why){fprintf(stderr,"%s\n",why);abort();}dwarf_end(dw);close(fd);
#endif
    VALUE mod=rb_define_module("XodbWatch");
    rb_define_singleton_method(mod,"sample",sample,1);
    rb_define_singleton_method(mod,"stop",stop,0);

}
