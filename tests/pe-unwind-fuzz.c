#include "../src/debug/pe_unwind.h"
#include "check.h"
#include <string.h>
struct input {const unsigned char *bytes;size_t size,reads,stack_bytes;};
static uint32_t u32(const unsigned char *p) {return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int read_image(void *user,uint32_t at,void *out,size_t n) {
    struct input *in=user;CHECK(++in->reads<=16384);
    if(at>in->size || n>in->size-at)return 0;
    memcpy(out,in->bytes+at,n);return 1;
}
static int read_stack(void *user,uint64_t at,void *out,size_t n) {
    struct input *in=user;CHECK(++in->reads<=16384);in->stack_bytes+=n;CHECK(in->stack_bytes<=16384);
    if(at<0x100000 || at>0x200000 || n>0x200000-at)return 0;
    memset(out,0x22,n);return 1;
}
/* One mutated table row at image offset 0x300 answers every lookup it covers. */
static int lookup(void *user,uint32_t rva,struct xpu_function *out) {
    struct input *in=user;CHECK(++in->reads<=16384);
    if(in->size<0x30c)return in->size&1?-1:0;
    *out=(struct xpu_function){u32(in->bytes+0x300),u32(in->bytes+0x304),u32(in->bytes+0x308)};
    return rva>=out->begin && rva<out->end;
}
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size) {
    if(size<17)return 0;
    struct input in={data+16,size-16,0,0};
    struct xpu_source source={&in,(uint32_t)in.size,read_image,read_image,read_stack,(data[11]&0x80)?NULL:lookup};
    struct xpu_function fn={0x100,0x180,u32(data+12)};
    struct xpu_context context={.gpr_known=0xffff,.xmm_known=0xffff};
    for(unsigned i=0;i<16;++i)context.gpr[i]=0x180000;
    context.gpr[4]-=u32(data+4);context.gpr[5]+=u32(data+8);
    struct xpu_result out,zero={0};memset(&out,0xff,sizeof out);
    enum xpu_status status=xpu_step(&source,&fn,u32(data),&context,&out);
    if(status!=XPU_OK)CHECK(!memcmp(&out,&zero,sizeof out));
    else {CHECK(out.caller.gpr[4]>context.gpr[4]);CHECK((out.caller.gpr_known&~0xf0f8u)==0);}
    in.reads=0;in.stack_bytes=0;source.code=NULL;source.stack=NULL;
    enum xpu_status audited=xpu_validate(&source,&fn);
    CHECK(in.stack_bytes==0);
    if(status==XPU_OK)CHECK(audited==XPU_OK);
    return 0;
}
