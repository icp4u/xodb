#include "../src/language/ruby.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define BASE UINT64_C(0x100000)
static unsigned char bytes[65536], saved[65536];
static size_t used=4096,attempts,fail_at;
static struct xrb_layout p={.succinct_lines=1,.fields={
    [XRB_CFP_PC]={0,8},
    [XRB_CFP_SP]={8,8},
    [XRB_CFP_ISEQ]={16,8},
    [XRB_CFP_SELF]={24,8},
    [XRB_CFP_EP]={32,8},
    [XRB_CFP_JIT]={48,8},
    [XRB_EC_STACK]={0,8},
    [XRB_EC_STACK_SIZE]={8,8},
    [XRB_EC_CFP]={16,8},
    [XRB_EC_THREAD]={48,8},
    [XRB_THREAD_SELF]={16,8},
    [XRB_THREAD_EC]={48,8},
    [XRB_ISEQ_FLAGS]={0,8},
    [XRB_ISEQ_BODY]={8,8},
    [XRB_BODY_TYPE]={0,4},
    [XRB_BODY_SIZE]={4,4},
    [XRB_BODY_CODE]={8,8},
    [XRB_BODY_PATH]={64,8},
    [XRB_BODY_LABEL]={72,8},
    [XRB_BODY_INFO]={104,8},
    [XRB_BODY_POSITIONS]={112,8},
    [XRB_BODY_INFO_SIZE]={120,4},
    [XRB_BODY_LOCALS]={128,8},
    [XRB_BODY_LOCAL_SIZE]={192,4},
    [XRB_BODY_PARENT]={152,8},
    [XRB_INFO_LINE]={0,4},
    [XRB_INDEX_IMMEDIATE]={0,48},
    [XRB_RANK_BASE]={0,4},
    [XRB_RANK_SMALL]={8,8},
    [XRB_RANK_BITS]={16,64},
    [XRB_STRING_FLAGS]={0,8},
    [XRB_STRING_LEN]={16,8},
    [XRB_STRING_PTR]={24,8},
    [XRB_STRING_EMBED]={24,1},
    [XRB_ARRAY_FLAGS]={0,8},
    [XRB_ARRAY_LEN]={16,8},
    [XRB_ARRAY_PTR]={32,8},
    [XRB_ARRAY_EMBED]={16,8},
    [XRB_DATA_FLAGS]={0,8},
    [XRB_DATA_PTR]={32,8},
    [XRB_DIRECTORY_CAPA]={0,8},
    [XRB_DIRECTORY_ENTRIES]={8,8},
    [XRB_ID_NAME]={8,8},
    [XRB_SYMBOLS_NEXT]={0,4},
    [XRB_SYMBOLS_IDS]={16,8},
    [XRB_DARRAY_SIZE]={0,8},
    [XRB_DARRAY_CAPA]={8,8},
    [XRB_ENV_FLAGS]={0,8},
    [XRB_ENV_ISEQ]={8,8},
    [XRB_ENV_EP]={16,8},
    [XRB_ENV_DATA]={24,8},
    [XRB_ENV_SIZE]={32,4},
    [XRB_FLOAT_FLAGS]={0,8},
    [XRB_FLOAT_VALUE]={16,8},
},.sizes={[XRB_T_CFP]=56,[XRB_T_INFO]=12,[XRB_T_INDEX]=48,[XRB_T_RANK]=80,[XRB_T_DARRAY]=16,[XRB_T_ID]=16}};

static uint64_t alloc(size_t n) { uint64_t a=BASE+used;used+=(n+7)&~(size_t)7;assert(used<sizeof bytes);return a; }
static void put(uint64_t a,uint64_t v,size_t n) { assert(a>=BASE && a-BASE<=sizeof bytes && n<=sizeof bytes-(a-BASE));for(size_t i=0;i<n;++i)bytes[a-BASE+i]=(unsigned char)(v>>(i*8)); }
static void set(uint64_t a,enum xrb_field f,uint64_t v) { put(a+p.fields[f].offset,v,p.fields[f].size); }
static uint64_t str(const char *text) { size_t n=strlen(text);uint64_t a=alloc(32+n);set(a,XRB_STRING_FLAGS,5);set(a,XRB_STRING_LEN,n);memcpy(bytes+(a+24-BASE),text,n);return a; }
static int rd(void *ctx,uint64_t a,void *out,size_t n) { (void)ctx;if(++attempts==fail_at||a<BASE||a-BASE>used||n>used-(a-BASE))return -1;memcpy(out,bytes+(a-BASE),n);return 0; }
static struct xrb_value value(uint64_t v) { struct xrb_reader r={.read=rd};struct xrb_value out;xrb_value_read(&p,&r,v,&out);assert(r.reads<=XRB_READ_LIMIT&&r.bytes<=XRB_BYTE_LIMIT);return out; }
static uint64_t data(uint64_t address) { uint64_t a=alloc(40);set(a,XRB_DATA_FLAGS,12);set(a,XRB_DATA_PTR,address);return a; }
static uint64_t iseq(const char *label,uint64_t parent,uint64_t local_id) {
 uint64_t q=alloc(32),b=alloc(304),code=alloc(80),info=alloc(12),table=alloc(8);
 set(q,XRB_ISEQ_FLAGS,26+(7<<12));set(q,XRB_ISEQ_BODY,b);set(b,XRB_BODY_CODE,code);set(b,XRB_BODY_SIZE,10);set(b,XRB_BODY_INFO,info);set(b,XRB_BODY_INFO_SIZE,1);set(info,XRB_INFO_LINE,17);
 set(b,XRB_BODY_LABEL,str(label));set(b,XRB_BODY_PATH,str("synthetic.rb"));set(b,XRB_BODY_LOCAL_SIZE,1);set(b,XRB_BODY_LOCALS,table);put(table,local_id,8);set(b,XRB_BODY_PARENT,parent);return q;
}
static uint64_t get(uint64_t a) { uint64_t v=0;for(size_t i=0;i<8;++i)v|=(uint64_t)bytes[a-BASE+i]<<(i*8);return v; }
static struct xrb_locals locals(uint64_t ec,uint64_t symbols,size_t frame,size_t start,size_t limit) {
 struct xrb_reader r={.read=rd};struct xrb_locals out;xrb_locals_read(&p,&r,ec,0,symbols,frame,start,limit,&out);
 assert(out.count<=XRB_LOCAL_ITEMS&&out.total<=4096&&r.reads<=XRB_READ_LIMIT&&r.bytes<=XRB_BYTE_LIMIT);return out;
}
static void samples(void) {
 struct xrb_sample out;struct xrb_reader r;
 #define SAMPLE(v) do {r=(struct xrb_reader){.read=rd};xrb_sample_read(&p,&r,(v),&out);}while(0)
 SAMPLE(UINT64_MAX);assert(!out.reason&&out.kind==1&&out.size==8);for(size_t i=0;i<8;++i)assert(out.bytes[i]==255);
 SAMPLE(4);assert(!out.reason&&out.kind==3&&!out.size);
 SAMPLE(0);assert(!out.reason&&out.kind==4&&!out.size);
 SAMPLE(20);assert(!out.reason&&out.kind==5&&!out.size);
 SAMPLE(UINT64_C(0x8000000000000002));assert(!out.reason&&out.kind==2&&out.size==8);for(size_t i=0;i<8;++i)assert(!out.bytes[i]);
 uint64_t heap=alloc(32);set(heap,XRB_FLOAT_FLAGS,4);set(heap,XRB_FLOAT_VALUE,UINT64_C(0x8000000000000000));
 SAMPLE(heap);assert(!out.reason&&out.kind==2&&out.bytes[7]==128);
 uint64_t text=alloc(32),data_=alloc(4096);memset(bytes+(data_-BASE),'a',4096);set(text,XRB_STRING_FLAGS,5|8192|(1<<22));set(text,XRB_STRING_PTR,data_);set(text,XRB_STRING_LEN,4095);
 SAMPLE(text);assert(!out.reason&&out.kind==6&&out.size==4096&&out.bytes[0]==1&&out.bytes[4095]=='a');
 bytes[data_-BASE+4094]='b';SAMPLE(text);assert(!out.reason&&out.bytes[4095]=='b');
 set(text,XRB_STRING_LEN,4096);SAMPLE(text);assert(out.reason&&!strcmp(out.reason,"RubyWatchSampleLimit")&&!out.size);
 set(text,XRB_STRING_LEN,0);set(text,XRB_STRING_FLAGS,5|8192|(127<<22));SAMPLE(text);assert(out.reason&&!strcmp(out.reason,"RubyWatchEncodingUnsupported"));
 set(text,XRB_STRING_FLAGS,5|8192);SAMPLE(text);assert(!out.reason&&out.size==1&&!out.bytes[0]);
 set(text,XRB_STRING_LEN,10);set(text,XRB_STRING_PTR,UINT64_MAX);SAMPLE(text);assert(out.reason&&!out.size);
 SAMPLE(12);assert(out.reason&&!strcmp(out.reason,"RubyWatchValueUnsupported"));
 set(heap,XRB_FLOAT_FLAGS,10);SAMPLE(heap);assert(out.reason&&!strcmp(out.reason,"RubyWatchValueUnsupported"));
 #undef SAMPLE
}
int main(void) {
 samples();
 struct xrb_value v=value(15);assert(!v.reason&&!strcmp(v.display,"7"));v=value(UINT64_MAX);assert(!strcmp(v.display,"-1"));
 v=value(4);assert(!strcmp(v.display,"nil"));v=value(0);assert(!strcmp(v.display,"false"));v=value(20);assert(!strcmp(v.display,"true"));
 v=value(UINT64_C(0x8000000000000002));assert(!v.reason&&!strcmp(v.display,"0"));
 uint64_t string=str("hi\n\"");v=value(string);assert(!v.reason&&strstr(v.display,"\\x0a\\x22"));
 uint64_t ar=alloc(40);set(ar,XRB_ARRAY_FLAGS,7|8192|(2<<15));put(ar+16,15,8);put(ar+24,ar,8);v=value(ar);assert(!v.reason&&v.item_count==2&&!strcmp(v.items[0].display,"7")&&!strcmp(v.items[1].type,"Array"));
 set(ar,XRB_ARRAY_FLAGS,7);set(ar,XRB_ARRAY_LEN,UINT64_MAX);v=value(ar);assert(v.reason&&!strcmp(v.reason,"RubyArrayLengthInvalid"));
 uint64_t symbols=alloc(24),dir=alloc(16),entries=alloc(8),block=alloc(16+512*16);
 set(symbols,XRB_SYMBOLS_NEXT,300);set(symbols,XRB_SYMBOLS_IDS,data(dir));set(dir,XRB_DIRECTORY_CAPA,1);set(dir,XRB_DIRECTORY_ENTRIES,entries);put(entries,data(block),8);set(block,XRB_DARRAY_SIZE,512);set(block,XRB_DARRAY_CAPA,512);
 set(block+16+200*16,XRB_ID_NAME,str("captured"));set(block+16+201*16,XRB_ID_NAME,str("captured"));
 uint64_t outer=iseq("outer",0,200<<4),inner=iseq("inner",outer,201<<4),ec=alloc(400),thread=alloc(480),stack=alloc(1024),end=stack+1024,cfp=end-3*56,ep=stack+128,outer_ep=stack+256;
 set(ec,XRB_EC_THREAD,thread);set(thread,XRB_THREAD_EC,ec);set(ec,XRB_EC_STACK,stack);set(ec,XRB_EC_STACK_SIZE,128);set(ec,XRB_EC_CFP,cfp);
 set(cfp,XRB_CFP_EP,ep);set(cfp,XRB_CFP_ISEQ,inner);set(cfp,XRB_CFP_PC,get(get(inner+8)+8)+8);
 put(ep,0x22220001,8);put(ep-8,outer_ep|1,8);put(ep-24,199,8);
 set(cfp+56,XRB_CFP_EP,outer_ep);set(cfp+56,XRB_CFP_ISEQ,outer);set(cfp+56,XRB_CFP_PC,get(get(outer+8)+8)+8);put(outer_ep,0x11110001|2,8);put(outer_ep-24,83,8);
 set(cfp+112,XRB_CFP_EP,stack+512);put(stack+512,0x79990001,8);
 struct xrb_reader r={.read=rd};struct xrb_stack frames;xrb_stack_read(&p,&r,ec,0,&frames);
 assert(!frames.reason&&frames.count==2&&!frames.frames[0].reason&&frames.frames[0].line==17&&!strcmp(frames.frames[0].name,"inner"));
 struct xrb_locals out=locals(ec,symbols,0,0,32);assert(!out.reason&&out.count==2&&out.total==2);
 assert(!out.items[0].reason&&!strcmp(out.items[0].name,"captured")&&!strcmp(out.items[0].value.display,"99")&&out.items[0].depth==0);
 assert(!strcmp(out.items[1].value.display,"41")&&out.items[1].depth==1);
 r=(struct xrb_reader){.read=rd};xrb_local_find(&p,&r,ec,0,symbols,0,"captured",&out);assert(!out.reason&&out.count==1&&!strcmp(out.items[0].value.display,"99"));
 r=(struct xrb_reader){.read=rd};xrb_local_find(&p,&r,ec,0,symbols,0,"captured()",&out);assert(out.reason&&!strcmp(out.reason,"RubyExpressionUnsupported")&&!r.reads);
 out=locals(ec,symbols,0,1,1);assert(!out.reason&&out.total==2&&out.count==1&&out.items[0].depth==1&&!out.truncated);
 out=locals(ec,symbols,0,0,33);assert(out.reason&&!strcmp(out.reason,"RubyLocalPageInvalid"));
 // Escaped environments must prove their own ep, iseq and allocation bounds.
 uint64_t storage=alloc(64),heap_ep=storage+24,env=alloc(40);put(heap_ep,0x11110001|2|4,8);put(storage,83,8);put(heap_ep+8,env,8);set(env,XRB_ENV_FLAGS,26);set(env,XRB_ENV_EP,heap_ep);set(env,XRB_ENV_ISEQ,outer);set(env,XRB_ENV_DATA,storage);set(env,XRB_ENV_SIZE,8);put(ep-8,heap_ep|1,8);
 out=locals(ec,symbols,0,0,32);assert(!out.reason&&out.items[1].escaped&&!strcmp(out.items[1].value.display,"41"));
 set(env,XRB_ENV_ISEQ,inner);out=locals(ec,symbols,0,0,32);assert(out.reason&&!strcmp(out.reason,"RubyEnvironmentIdentityMismatch"));set(env,XRB_ENV_ISEQ,outer);
 set(env,XRB_ENV_DATA,heap_ep);out=locals(ec,symbols,0,0,32);assert(out.reason&&!strcmp(out.reason,"RubyEnvironmentBoundsInvalid"));set(env,XRB_ENV_DATA,storage);
 put(ep-8,ep|1,8);out=locals(ec,symbols,0,0,32);assert(out.reason&&!strcmp(out.reason,"RubyEnvironmentCycle"));put(ep-8,heap_ep|1,8);
 set(cfp,XRB_CFP_JIT,1);r=(struct xrb_reader){.read=rd};xrb_stack_read(&p,&r,ec,1,&frames);assert(frames.frames[0].reason&&!strcmp(frames.frames[0].reason,"RubyZjitFrameUnsupported"));set(cfp,XRB_CFP_JIT,0);
 set(cfp,XRB_CFP_JIT,1);r=(struct xrb_reader){.read=rd};xrb_stack_read(&p,&r,ec,0,&frames);assert(frames.frames[0].reason&&!strcmp(frames.frames[0].reason,"RubyJitFrameUnsupported"));set(cfp,XRB_CFP_JIT,0);
 set(ec,XRB_EC_STACK_SIZE,UINT64_MAX);r=(struct xrb_reader){.read=rd};xrb_stack_read(&p,&r,ec,0,&frames);assert(frames.reason&&!strcmp(frames.reason,"RubyStackBoundsInvalid"));set(ec,XRB_EC_STACK_SIZE,128);
 p.succinct_lines=0;r=(struct xrb_reader){.read=rd};xrb_stack_read(&p,&r,ec,0,&frames);assert(!frames.frames[0].line&&!strcmp(frames.frames[0].line_reason,"RubyLineTableUnproved"));p.succinct_lines=1;
 r=(struct xrb_reader){.read=rd,.reads=XRB_READ_LIMIT};xrb_stack_read(&p,&r,ec,0,&frames);assert(frames.reason&&!strcmp(frames.reason,"RubyReadBudget"));
 attempts=0;out=locals(ec,symbols,0,0,32);size_t reads=attempts;assert(!out.reason);
 for(size_t i=1;i<=reads;++i){attempts=0;fail_at=i;out=locals(ec,symbols,0,0,32);assert(attempts>=i);}fail_at=0;
 memcpy(saved,bytes,sizeof bytes);uint32_t seed=123456;
 for(size_t i=0;i<4096;++i){seed=(uint32_t)((uint64_t)seed*1664525+1013904223);size_t at=seed%(used-8);put(BASE+at,((uint64_t)seed<<32)|~seed,8);out=locals(ec,symbols,0,i%4,1+i%32);memcpy(bytes,saved,sizeof bytes);}
 puts("Ruby reader: primitives, arrays, frames, lexical shadowing, pages, heap identity/bounds, cycles, JIT/line refusals, every-read failure and4096 corruptions passed");return 0;
}
