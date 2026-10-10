/* Compare the decoder with the platform unwinder using the same compiler
 * tables and synthetic register/stack states at exact instruction boundaries. */
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "../../../src/debug/pe_unwind.h"
#include "unwind-cases.h"
static unsigned char memory[1024*1024] __attribute__((aligned(16)));
static unsigned char chain_image[4096] __attribute__((aligned(16)));
static unsigned char *image;
static uint32_t image_size;
static void fail(unsigned line) {
    char text[]="runtime unwind check failed 00000000\n";
    const char hex[]="0123456789abcdef";
    for(unsigned i=0;i<8;++i)text[27+i]=hex[(line>>(28-i*4))&15];
    DWORD done;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof text-1,&done,NULL);ExitProcess(90);
}
#define REQUIRE(x) do { if(!(x))fail(__LINE__); } while(0)
static void say(const char *text) {
    DWORD done;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,(DWORD)strlen(text),&done,NULL);
}
static int image_read(void *user,uint32_t at,void *out,size_t size) {
    (void)user;if(at>image_size || size>image_size-at)return 0;
    memcpy(out,image+at,size);return 1;
}
static int stack_read(void *user,uint64_t at,void *out,size_t size) {
    (void)user;uint64_t base=(uintptr_t)memory;
    if(at<base || at-base>sizeof memory || size>sizeof memory-(at-base))return 0;
    memcpy(out,(void *)(uintptr_t)at,size);return 1;
}
static RUNTIME_FUNCTION shape_rows[3];
static int shape_lookup(void *user,uint32_t rva,struct xpu_function *out) {
    (void)user;
    for(unsigned i=0;i<3;++i)if(rva>=shape_rows[i].BeginAddress && rva<shape_rows[i].EndAddress) {
        *out=(struct xpu_function){shape_rows[i].BeginAddress,shape_rows[i].EndAddress,shape_rows[i].UnwindData};return 1;
    }
    return 0;
}
void entry(void) {
    image=(unsigned char *)LoadLibraryA("unwind.dll");REQUIRE(image);
    IMAGE_DOS_HEADER *dos=(void *)image;
    IMAGE_NT_HEADERS64 *headers=(void *)(image+dos->e_lfanew);image_size=headers->OptionalHeader.SizeOfImage;
    uint64_t top=(uintptr_t)memory+0x90008,ret=0x180123456;
    const uint64_t rbx=0x1234567887654321,rbp=0x1234567887654322,r12=0x1234567887654323;
    memcpy((void *)(uintptr_t)top,&ret,8);
    const struct {const char *name;unsigned used;unsigned changed;} cases[]={
        {"uw_push",0,0},{"uw_push_pushed",8,3},{"uw_push_body",40,3},{"uw_push_epilog",40,3},{"uw_push_pop",8,3},{"uw_push_ret",0,0},
        {"uw_frame",0,0},{"uw_frame_pushed",8,0},{"uw_frame_allocated",72,0},{"uw_frame_body",328,5},{"uw_frame_epilog",328,5},{"uw_frame_pop",8,5},{"uw_frame_ret",0,0},
        {"uw_saved",0,0},{"uw_saved_allocated",88,0},{"uw_saved_gpr",88,12},{"uw_saved_body",88,12},{"uw_saved_epilog",88,0},{"uw_saved_ret",0,0},
        {"uw_large",0,0},{"uw_large_body",4096,0},{"uw_large_epilog",4096,0},{"uw_large_ret",0,0},
        {"uw_far",0,0},{"uw_far_body",524296,0},{"uw_far_epilog",524296,0},{"uw_far_ret",0,0},{"uw_leaf",0,0}
    };
    int wrong=strstr(GetCommandLineA(),"wrong-result")!=NULL;
    for(unsigned i=0;i<sizeof cases/sizeof cases[0];++i) {
        const char *name=cases[i].name;
        uint64_t pc=(uintptr_t)GetProcAddress((HMODULE)image,name);REQUIRE(pc);
        DWORD64 base=(uintptr_t)image;
        RUNTIME_FUNCTION *function=RtlLookupFunctionEntry(pc,&base,NULL);
        struct xpu_function fn={0};
        if(function)fn=(struct xpu_function){function->BeginAddress,function->EndAddress,function->UnwindData};
        CONTEXT runtime={0};runtime.ContextFlags=CONTEXT_ALL;runtime.Rip=pc;
        struct xpu_context input={.gpr_known=0xffff,.xmm_known=0xffff,.rip=pc};
        for(unsigned j=0;j<16;++j)input.gpr[j]=0xdead0000+j;
        input.gpr[3]=rbx;input.gpr[5]=rbp;input.gpr[12]=r12;input.gpr[4]=top-cases[i].used;
        memset(input.xmm,0x66,sizeof input.xmm);
        if(cases[i].changed)input.gpr[cases[i].changed]=0xdead;
        if(!strncmp(name,"uw_frame",8)) {
            memcpy((void *)(uintptr_t)(top-8),&rbp,8);
            if(cases[i].changed==5)input.gpr[5]=top-72+32;
        } else memcpy((void *)(uintptr_t)(top-8),&rbx,8);
        if(!strncmp(name,"uw_saved",8)) {
            memcpy((void *)(uintptr_t)(top-88+32),&r12,8);
            memset((void *)(uintptr_t)(top-88+48),0x66,16);
            if(!strcmp(name,"uw_saved_body"))memset(input.xmm[6],0,16);
        }
        _Static_assert(offsetof(CONTEXT,Rip)==offsetof(CONTEXT,Rax)+16*8,"SDK register ordering");
        memcpy((unsigned char *)&runtime+offsetof(CONTEXT,Rax),input.gpr,sizeof input.gpr);
        memcpy((unsigned char *)&runtime+offsetof(CONTEXT,Xmm0),input.xmm,sizeof input.xmm);
        struct xpu_source source={NULL,image_size,image_read,image_read,stack_read};
        struct xpu_result result;
        REQUIRE(xpu_step(&source,function?&fn:NULL,(uint32_t)(pc-(uintptr_t)image),&input,&result)==XPU_OK);
        void *data=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(0,base,pc,function,&runtime,&data,&establisher,NULL);
        REQUIRE(result.caller.rip==runtime.Rip+(wrong?1:0));
        REQUIRE(result.caller.gpr[4]==runtime.Rsp && runtime.Rsp==top+8);
        for(unsigned j=0;j<16;++j)if(result.caller.gpr_known&(1u<<j)) {
            uint64_t actual;memcpy(&actual,(unsigned char *)&runtime+offsetof(CONTEXT,Rax)+j*8,8);
            REQUIRE(result.caller.gpr[j]==actual);
        }
        REQUIRE(!memcmp(result.caller.xmm[6],(unsigned char *)&runtime+offsetof(CONTEXT,Xmm6),10*16));
    }
    const char text[]="28 RtlVirtualUnwind boundary comparisons passed\n";
    DWORD done;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof text-1,&done,NULL);
    /* Delayed nonvolatile saves chain to the primary frame establishment.
     * These records have independent platform and explicit value oracles. */
    image=chain_image;image_size=sizeof chain_image;memset(image,0x90,sizeof chain_image);
    const unsigned char secondary[]={0x21,4,2,0x25,4,0xc4,2,0};
    const unsigned char primary[]={1,10,3,0x25,10,3,5,0x72,1,0x50,0,0};
    RUNTIME_FUNCTION parent={0x80,0x100,0x240},function={0x100,0x180,0x200};
    memcpy(image+0x200,secondary,sizeof secondary);memcpy(image+0x208,&parent,sizeof parent);memcpy(image+0x240,primary,sizeof primary);
    memcpy((void *)(uintptr_t)(top-8),&rbp,8);memcpy((void *)(uintptr_t)(top-72+16),&r12,8);
    for(unsigned offset=0;offset<=4;offset+=4) {
        CONTEXT runtime={0};runtime.ContextFlags=CONTEXT_ALL;runtime.Rip=(uintptr_t)image+0x100+offset;
        runtime.Rsp=top-328;runtime.Rbp=top-72+32;runtime.R12=offset?0xdead:r12;
        struct xpu_context input={.gpr_known=(1u<<4)|(1u<<5)|(1u<<12),.rip=runtime.Rip};
        input.gpr[4]=runtime.Rsp;input.gpr[5]=runtime.Rbp;input.gpr[12]=runtime.R12;
        struct xpu_function fn={function.BeginAddress,function.EndAddress,function.UnwindData};
        struct xpu_source source={NULL,image_size,image_read,image_read,stack_read};struct xpu_result result;
        REQUIRE(xpu_step(&source,&fn,0x100+offset,&input,&result)==XPU_OK);
        void *data=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(0,(uintptr_t)image,runtime.Rip,&function,&runtime,&data,&establisher,NULL);
        REQUIRE(result.caller.rip==runtime.Rip && runtime.Rip==ret);
        REQUIRE(result.caller.gpr[4]==runtime.Rsp && runtime.Rsp==top+8);
        REQUIRE(result.caller.gpr[5]==runtime.Rbp && runtime.Rbp==rbp);
        REQUIRE(result.caller.gpr[12]==runtime.R12 && runtime.R12==r12);
    }
    const char chain_text[]="2 RtlVirtualUnwind chained-save comparisons passed\n";
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),chain_text,sizeof chain_text-1,&done,NULL);
    /* Crafted epilog and record shapes. The table is registered so that the
     * platform can look up what a jmp lands on, as the decoder does. Dynamic
     * tables are consulted only outside loaded modules, hence the allocation. */
    image=VirtualAlloc(NULL,image_size,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);REQUIRE(image);
    for(unsigned i=0;i<3;++i)shape_rows[i]=(RUNTIME_FUNCTION){uw_rows[i][0],uw_rows[i][1],uw_rows[i][2]};
    REQUIRE(RtlAddFunctionTable(shape_rows,3,(uintptr_t)image));
    int wrong_shape=strstr(GetCommandLineA(),"wrong-shape")!=NULL;
    unsigned compared=0,apart=0;
    for(unsigned i=0;i<sizeof uw_cases/sizeof uw_cases[0];++i) {
        const struct uw_case *k=&uw_cases[i];
        memset(image,0x90,image_size);
        memcpy(image+0x200,k->record,k->record_size);memcpy(image+k->pc,k->code,k->code_size);
        memcpy(image+0x240,uw_callee_record,sizeof uw_callee_record);memcpy(image+0x250,uw_cold_record,sizeof uw_cold_record);
        memset((void *)(uintptr_t)(top-64),0,64);
        if(k->frame){memcpy((void *)(uintptr_t)(top-8),&rbp,8);memcpy((void *)(uintptr_t)(top-16),&rbx,8);}
        else memcpy((void *)(uintptr_t)(top-8),&rbx,8);
        struct xpu_context input={.gpr_known=0xffff,.xmm_known=0xffff,.rip=(uintptr_t)image+k->pc};
        for(unsigned j=0;j<16;++j)input.gpr[j]=0xdead0000+j;
        input.gpr[3]=k->saved?0xdead:rbx;input.gpr[5]=k->frame?top-8:rbp;input.gpr[12]=r12;input.gpr[4]=top-k->used;
        CONTEXT runtime={0};runtime.ContextFlags=CONTEXT_ALL;runtime.Rip=input.rip;
        memcpy((unsigned char *)&runtime+offsetof(CONTEXT,Rax),input.gpr,sizeof input.gpr);
        struct xpu_function fn={shape_rows[0].BeginAddress,shape_rows[0].EndAddress,shape_rows[0].UnwindData};
        struct xpu_source source={NULL,image_size,image_read,image_read,stack_read,shape_lookup};struct xpu_result result;
        REQUIRE(xpu_step(&source,&fn,k->pc,&input,&result)==XPU_OK);
        REQUIRE(result.method==(k->expect==UW_EPILOG?XPU_EPILOG:XPU_UNWIND));
        REQUIRE(result.caller.rip==ret && result.caller.gpr[4]==top+8);
        REQUIRE(result.caller.gpr[3]==rbx && result.caller.gpr[5]==rbp);
        DWORD64 base=0;RUNTIME_FUNCTION *function=RtlLookupFunctionEntry(input.rip,&base,NULL);
        REQUIRE(function==&shape_rows[0] && base==(uintptr_t)image);
        void *data=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(0,base,input.rip,function,&runtime,&data,&establisher,NULL);
        int same=runtime.Rip==result.caller.rip && runtime.Rsp==result.caller.gpr[4] &&
            runtime.Rbx==result.caller.gpr[3] && runtime.Rbp==result.caller.gpr[5];
        if(!k->platform){apart+=!same;continue;}
        if(wrong_shape)same=result.caller.rip+1==runtime.Rip;
        if(!same){say("shape ");say(k->name);say(": RtlVirtualUnwind disagrees\n");ExitProcess(90);}
        ++compared;
    }
    REQUIRE(RtlDeleteFunctionTable(shape_rows));
    char shape_text[]="00 RtlVirtualUnwind shape comparisons passed, 00 documented platform differences seen\n";
    shape_text[0]+=compared/10;shape_text[1]+=compared%10;
    const unsigned at=sizeof "00 RtlVirtualUnwind shape comparisons passed, "-1;
    shape_text[at]+=apart/10;shape_text[at+1]+=apart%10;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),shape_text,sizeof shape_text-1,&done,NULL);ExitProcess(0);
}
