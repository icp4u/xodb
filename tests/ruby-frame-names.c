#include "../src/language/ruby.h"
#include "check.h"
#include <string.h>
#define BASE UINT64_C(0x200000)
static unsigned char data[65536];
static size_t used=20000;
static struct xrb_layout p={.fields={
    [XRB_STRING_FLAGS]={0,8},[XRB_STRING_LEN]={8,8},[XRB_STRING_EMBED]={24,1},
    [XRB_DATA_PTR]={8,8},[XRB_SYMBOLS_NEXT]={0,4},[XRB_SYMBOLS_IDS]={8,8},
    [XRB_DIRECTORY_CAPA]={0,8},[XRB_DIRECTORY_ENTRIES]={8,8},
    [XRB_DARRAY_SIZE]={0,8},[XRB_DARRAY_CAPA]={8,8},[XRB_ID_NAME]={8,8},
    [XRB_CALLABLE_CLASS]={8,8},[XRB_CALLABLE_DEF]={16,8},[XRB_CALLABLE_ID]={24,8},[XRB_CALLABLE_OWNER]={32,8},
    [XRB_METHOD_TYPE]={0,4},[XRB_METHOD_ORIGINAL_ID]={8,8},[XRB_CLASS_PATH]={128,8},[XRB_CLASS_ATTACHED]={136,8},[XRB_CLASS_BOX_TABLE]={160,8},
    [XRB_SVAR_METHOD]={8,8},[XRB_ISEQ_BODY]={8,8},[XRB_BODY_PARENT]={0,8},
},.sizes={[XRB_T_DARRAY]=16,[XRB_T_ID]=16}};
static uint64_t alloc(size_t n) {uint64_t at=BASE+used;used+=(n+7)&~(size_t)7;CHECK(used<sizeof data);return at;}
static void put(uint64_t at,uint64_t v,size_t n) {CHECK(at>=BASE && at-BASE+n<=sizeof data);for(size_t i=0;i<n;++i)data[at-BASE+i]=(unsigned char)(v>>(i*8));}
static void field(uint64_t at,enum xrb_field key,uint64_t value) {put(at+p.fields[key].offset,value,p.fields[key].size);}
static uint64_t string(const char *text) {size_t n=strlen(text);uint64_t at=alloc(32+n);put(at,5,8);field(at,XRB_STRING_LEN,n);memcpy(data+(at-BASE+24),text,n);return at;}
static uint64_t typed(uint64_t address) {uint64_t at=alloc(16);put(at,12,8);field(at,XRB_DATA_PTR,address);return at;}
static int read_(void *unused,uint64_t at,void *out,size_t n) {(void)unused;if(at<BASE || at-BASE>sizeof data || n>sizeof data-(at-BASE))return -1;memcpy(out,data+(at-BASE),n);return 0;}
static void expect(struct xrb_stack *stack,uint64_t symbols,const char *label,const char *why) {
    struct xrb_reader r={.read=read_};xrb_stack_names(&p,&r,symbols,stack);
    CHECK(r.reads<=XRB_READ_LIMIT && r.bytes<=XRB_BYTE_LIMIT && !stack->reason);
    CHECK(!strcmp(stack->frames[0].name,"<cfunc>"));
    CHECK(!strcmp(stack->frames[0].qualified_name,label?label:""));
    CHECK(why?(stack->frames[0].name_reason && !strcmp(stack->frames[0].name_reason,why)):!stack->frames[0].name_reason);
}
void ruby_frame_names_test(void) {
    uint64_t symbols=alloc(16),directory=alloc(16),entries=alloc(8),block=alloc(16+512*16);
    field(symbols,XRB_SYMBOLS_NEXT,300);field(symbols,XRB_SYMBOLS_IDS,typed(directory));
    field(directory,XRB_DIRECTORY_CAPA,1);field(directory,XRB_DIRECTORY_ENTRIES,entries);put(entries,typed(block),8);
    field(block,XRB_DARRAY_SIZE,512);field(block,XRB_DARRAY_CAPA,512);field(block+16+200*16,XRB_ID_NAME,string("digits"));
    uint64_t me=alloc(40),klass=alloc(176),definition=alloc(16),path=string("Integer"),ep=BASE+9000;
    put(me,26|(6<<12),8);field(me,XRB_CALLABLE_CLASS,klass);field(me,XRB_CALLABLE_OWNER,klass);
    field(me,XRB_CALLABLE_ID,200<<4);field(me,XRB_CALLABLE_DEF,definition);field(definition,XRB_METHOD_TYPE,1);field(definition,XRB_METHOD_ORIGINAL_ID,200<<4);
    put(klass,2,8);field(klass,XRB_CLASS_PATH,path);put(ep,0x55550001|2,8);put(ep-16,me,8);
    struct xrb_stack stack={.count=1,.stack_lo=BASE+4096,.cfp=BASE+16384};
    stack.frames[0]=(struct xrb_frame){.ep=ep,.name="<cfunc>",.kind="cfunc"};
    expect(&stack,symbols,"Integer#digits",NULL);
    field(block+16+201*16,XRB_ID_NAME,string("original_digits"));
    field(definition,XRB_METHOD_ORIGINAL_ID,201<<4);expect(&stack,symbols,"Integer#digits (alias of original_digits)",NULL);
    field(definition,XRB_METHOD_ORIGINAL_ID,0);expect(&stack,symbols,NULL,"RubyLocalIdInvalid");
    field(definition,XRB_METHOD_ORIGINAL_ID,200<<4);
    put(ep,0x22220001|64,8);expect(&stack,symbols,NULL,"RubyFrameMethodUnproved");
    field(definition,XRB_METHOD_TYPE,4);strcpy(stack.frames[0].kind,"block");
    expect(&stack,symbols,"Integer#digits (define_method)",NULL);
    put(ep,0x22220001,8);expect(&stack,symbols,"block in Integer#digits (define_method)",NULL);
    field(definition,XRB_METHOD_TYPE,1);strcpy(stack.frames[0].kind,"cfunc");put(ep,0x55550001|2,8);
    put(klass,3,8);expect(&stack,symbols,"Integer#digits",NULL);put(klass,2,8);
    uint64_t singleton=alloc(176);put(singleton,2|8192,8);field(singleton,XRB_CLASS_ATTACHED,klass);field(me,XRB_CALLABLE_OWNER,singleton);
    expect(&stack,symbols,"Integer.digits",NULL);
    put(klass,1,8);expect(&stack,symbols,NULL,"RubyFrameDefinedClassUnproved");put(klass,2,8);
    field(singleton,XRB_CLASS_ATTACHED,me);expect(&stack,symbols,NULL,"RubyFrameSingletonOwnerUnproved");
    field(me,XRB_CALLABLE_OWNER,klass);field(klass,XRB_CLASS_PATH,0);expect(&stack,symbols,NULL,"RubyFrameOwnerUnnamed");field(klass,XRB_CLASS_PATH,path);
    put(klass,2|(1<<16),8);field(klass,XRB_CLASS_BOX_TABLE,me);expect(&stack,symbols,NULL,"RubyFrameBoxUnsupported");put(klass,2,8);
    field(definition,XRB_METHOD_TYPE,2);expect(&stack,symbols,NULL,"RubyFrameMethodUnproved");field(definition,XRB_METHOD_TYPE,1);
    uint64_t svar=alloc(16);put(svar,26|(2<<12),8);field(svar,XRB_SVAR_METHOD,me);put(ep-16,svar,8);
    expect(&stack,symbols,"Integer#digits",NULL);
    field(svar,XRB_SVAR_METHOD,svar);expect(&stack,symbols,NULL,"RubyFrameMethodUnproved");
    put(ep-16,0,8);expect(&stack,symbols,NULL,"RubyFrameMethodUnavailable");
    put(ep,0x22220001,8);put(ep-8,ep|1,8);
    uint64_t iseq=alloc(16),body=alloc(8);put(iseq,26|(7<<12),8);field(iseq,XRB_ISEQ_BODY,body);field(body,XRB_BODY_PARENT,iseq);stack.frames[0].iseq=iseq;
    expect(&stack,symbols,NULL,"RubyEnvironmentCycle");
    put(ep,0x22220001|16,8);expect(&stack,symbols,NULL,"RubyIsolatedEnvironmentBoundary");
    for(size_t i=0;i<65;++i){uint64_t at=ep+i*24;put(at,0x22220001,8);put(at-16,0,8);put(at-8,(at+24)|1,8);}
    expect(&stack,symbols,NULL,"RubyEnvironmentDepthLimit");
    put(ep,0x55550001|2,8);put(ep-16,me,8);stack.frames[0].ep=BASE;expect(&stack,symbols,NULL,"RubyEnvironmentBoundsInvalid");stack.frames[0].ep=ep;
    expect(&stack,0,NULL,"RubyRuntimeSymbolsUnavailable");
    struct xrb_reader r={.read=read_,.reads=XRB_READ_LIMIT};xrb_stack_names(&p,&r,symbols,&stack);
    CHECK(!stack.frames[0].qualified_name[0] && !strcmp(stack.frames[0].name_reason,"RubyReadBudget"));
}
