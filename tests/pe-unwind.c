#include "../src/debug/pe_unwind.h"
#include "../src/binary/pe.h"
#include "check.h"
#include "fixtures/pe/unwind-cases.h"
#include <string.h>

#define STACK_BASE UINT64_C(0x100000000)
#define ENTRY (STACK_BASE+0x90008)
#define RETURN_PC UINT64_C(0x180123456)
#define OLD_RBX UINT64_C(0x1234567887654321)
#define OLD_RBP UINT64_C(0x1234567887654322)
#define OLD_R12 UINT64_C(0x1234567887654323)
struct fixture {
    unsigned char *image, *memory;
    size_t size, reads, fail_at;
    unsigned rows; /* 12-byte table rows at image+0x300, when nonzero */
};
static void put32(unsigned char *p,uint32_t n) { for(unsigned i=0;i<4;++i)p[i]=(unsigned char)(n>>(8*i)); }
static void put64(unsigned char *p,uint64_t n) { for(unsigned i=0;i<8;++i)p[i]=(unsigned char)(n>>(8*i)); }
static int read_image(void *user,uint32_t at,void *out,size_t n) {
    struct fixture *f=user;
    if (++f->reads==f->fail_at || at>f->size || n>f->size-at)return 0;
    memcpy(out,f->image+at,n);return 1;
}
static int read_stack(void *user,uint64_t at,void *out,size_t n) {
    struct fixture *f=user;
    if (++f->reads==f->fail_at || at<STACK_BASE || at-STACK_BASE>0x100000 || n>0x100000-(at-STACK_BASE))return 0;
    memcpy(out,f->memory+(size_t)(at-STACK_BASE),n);return 1;
}
static uint32_t get32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static int lookup(void *user,uint32_t rva,struct xpu_function *out) {
    struct fixture *f=user;
    if (++f->reads==f->fail_at)return -1;
    for(unsigned i=0;i<f->rows;++i) {
        const unsigned char *row=f->image+0x300+i*12;
        if(rva<get32(row) || rva>=get32(row+4))continue;
        *out=(struct xpu_function){get32(row),get32(row+4),get32(row+8)};return 1;
    }
    return 0;
}
static void save(struct fixture *f,uint64_t at,uint64_t value) {
    CHECK(at>=STACK_BASE && at+8<=STACK_BASE+0x100000);put64(f->memory+(size_t)(at-STACK_BASE),value);
}
static struct xpu_context context(uint64_t rsp) {
    struct xpu_context c={.gpr_known=0xffff,.xmm_known=0xffff,.rip=0x180001000};
    for(unsigned i=0;i<16;++i)c.gpr[i]=0xdead0000+i;
    c.gpr[3]=OLD_RBX;c.gpr[5]=OLD_RBP;c.gpr[12]=OLD_R12;c.gpr[4]=rsp;
    memset(c.xmm,0x66,sizeof c.xmm);return c;
}
static unsigned checks;
static struct xpu_result run(struct fixture *f,const struct xpu_function *fn,uint32_t pc,
                             struct xpu_context input,enum xpu_status expected,int faults) {
    struct xpu_source source={f,(uint32_t)f->size,read_image,read_image,read_stack,f->rows?lookup:NULL};
    struct xpu_result out;memset(&out,0xab,sizeof out);f->reads=0;f->fail_at=0;
    enum xpu_status status=xpu_step(&source,fn,pc,&input,&out);
    if(status!=expected)fprintf(stderr,"pc=%x: status=%u expected=%u\n",pc,status,expected);
    CHECK(status==expected);++checks;
    if(status!=XPU_OK){struct xpu_result zero={0};CHECK(!memcmp(&out,&zero,sizeof out));return out;}
    CHECK(out.caller.rip==RETURN_PC && out.caller.gpr[4]==ENTRY+8 && out.cfa==ENTRY+8);
    CHECK(out.caller.gpr_known==0xf0f8 && out.caller.xmm_known==0xffc0);
    CHECK(!out.caller.gpr[0] && !out.caller.gpr[1] && !out.caller.gpr[2] && !out.caller.gpr[8]);
    if(faults) {
        size_t count=f->reads;CHECK(count);
        for(size_t i=1;i<=count;++i) {
            struct xpu_result failed,zero={0};memset(&failed,0xab,sizeof failed);
            f->reads=0;f->fail_at=i;status=xpu_step(&source,fn,pc,&input,&failed);
            CHECK(status==XPU_METADATA_MISSING || status==XPU_CODE_MISSING || status==XPU_STACK_MISSING);
            CHECK(!memcmp(&failed,&zero,sizeof failed));++checks;
        }
        f->fail_at=0;
    }
    if(fn && faults) {
        /* Capture-time audit must need neither live code nor a stack reader. */
        struct xpu_source audit={f,(uint32_t)f->size,read_image,NULL,NULL,NULL};
        f->reads=0;CHECK(xpu_validate(&audit,fn)==XPU_OK);++checks;
        size_t count=f->reads;CHECK(count);
        for(size_t i=1;i<=count;++i) {
            f->reads=0;f->fail_at=i;
            CHECK(xpu_validate(&audit,fn)==XPU_METADATA_MISSING);++checks;
        }
        f->fail_at=0;
    }
    return out;
}
static void metadata(struct fixture *f,unsigned at,const unsigned char *bytes,size_t n) {
    CHECK(at+n<=f->size);memcpy(f->image+at,bytes,n);
}
#define META(f,at,...) do { const unsigned char b[]={__VA_ARGS__};metadata(f,at,b,sizeof b); } while(0)
static void synthetic(struct fixture *f) {
    struct xpu_function fn={0x100,0x180,0x200};
    memset(f->image,0x90,f->size);save(f,ENTRY,RETURN_PC);save(f,ENTRY-8,OLD_RBX);
    META(f,0x200,1,5,2,0, 5,0x32, 1,0x30);
    for(unsigned pc=0;pc<=5;++pc) {
        struct xpu_context c=context(ENTRY-(pc?8:0)-(pc>=5?32:0));
        if(pc)c.gpr[3]=0xdead;
        struct xpu_result out=run(f,&fn,0x100+pc,c,XPU_OK,1);
        CHECK(out.caller.gpr[3]==OLD_RBX && out.method==XPU_UNWIND);
    }
    struct xpu_context c=context(ENTRY-40);c.gpr[3]=0xdead;
    META(f,0x170,0x48,0x83,0xc4,32,0x5b,0xc3);
    CHECK(run(f,&fn,0x170,c,XPU_OK,1).method==XPU_EPILOG);
    c.gpr[4]=ENTRY-8;CHECK(run(f,&fn,0x174,c,XPU_OK,1).caller.gpr[3]==OLD_RBX);
    c.gpr[4]=ENTRY;c.gpr[3]=OLD_RBX;CHECK(run(f,&fn,0x175,c,XPU_OK,1).method==XPU_EPILOG);
    CHECK(run(f,NULL,0x180,c,XPU_OK,1).method==XPU_LEAF);
    /* A matching prefix followed by body code must not partly mutate input. */
    META(f,0x170,0x48,0x83,0xc4,32,0x5b,0x90);
    c=context(ENTRY-40);CHECK(run(f,&fn,0x170,c,XPU_OK,1).method==XPU_UNWIND);
    /* Saved nonvolatile addressing stays at the fixed allocation base even
     * after an ALLOC code has already advanced the simulated stack pointer. */
    META(f,0x200,1,8,3,0, 8,0x32, 4,0xc4, 5,0);
    save(f,ENTRY+8,OLD_R12);c=context(ENTRY-32);c.gpr[12]=0xdead;
    CHECK(run(f,&fn,0x120,c,XPU_OK,1).caller.gpr[12]==OLD_R12);
    /* Primary frame establishment + secondary delayed save. */
    META(f,0x200,0x21,4,2,0x25, 4,0xc4, 2,0);
    put32(f->image+0x208,0x80);put32(f->image+0x20c,0x100);put32(f->image+0x210,0x240);
    META(f,0x240,1,10,3,0x25, 10,3, 5,0x72, 1,0x50, 0,0);
    save(f,ENTRY-8,OLD_RBP);save(f,ENTRY-72+16,OLD_R12);
    c=context(ENTRY-72-0x100);c.gpr[5]=ENTRY-72+32;c.gpr[12]=0xdead;
    struct xpu_result out=run(f,&fn,0x120,c,XPU_OK,1);
    CHECK(out.caller.gpr[5]==OLD_RBP && out.caller.gpr[12]==OLD_R12);
    /* A cold code fragment can chain without adding saves of its own. Its
     * partially executed epilog must not unwind the primary allocation twice. */
    META(f,0x200,0x21,0,0,0x25);
    put32(f->image+0x204,0x80);put32(f->image+0x208,0x100);put32(f->image+0x20c,0x240);
    META(f,0x170,0x5d,0xc3);
    c=context(ENTRY-8);c.gpr[5]=ENTRY-72+32;
    out=run(f,&fn,0x170,c,XPU_OK,1);CHECK(out.caller.gpr[5]==OLD_RBP && out.method==XPU_EPILOG);
    META(f,0x200,0x21,4,2,0x25,4,0xc4,2,0);
    put32(f->image+0x208,0x80);put32(f->image+0x20c,0x100);put32(f->image+0x210,0x240);
    /* Chain cycle, incompatible frame register, and the low-bit extension. */
    put32(f->image+0x210,0x200);run(f,&fn,0x120,c,XPU_MALFORMED,0);
    put32(f->image+0x210,0x240);f->image[0x243]=0;run(f,&fn,0x120,c,XPU_MALFORMED,0);
    struct xpu_function indirect=fn;indirect.unwind|=1;run(f,&indirect,0x120,c,XPU_UNSUPPORTED_CHAIN,0);
    /* Both long save forms, including XMM bytes, have independent oracles. */
    META(f,0x200,1,12,7,0, 12,0x69,0x10,0,0,0, 8,0xc5,8,0,0,0, 4,0x32,0,0);
    c=context(ENTRY-32);c.gpr[12]=0xdead;memset(c.xmm[6],0,16);
    save(f,ENTRY-24,OLD_R12);memset(f->memory+(ENTRY-16-STACK_BASE),0x77,16);
    out=run(f,&fn,0x120,c,XPU_OK,1);CHECK(out.caller.gpr[12]==OLD_R12);
    for(unsigned i=0;i<16;++i)CHECK(out.caller.xmm[6][i]==0x77);
    /* Versions, truncated operands, ordering, reserved fields and flags. */
    const struct { unsigned char bytes[12];enum xpu_status status; } bad[]={
        {{2,0,0,0},XPU_UNSUPPORTED_VERSION},{{3,0,0,0},XPU_UNSUPPORTED_VERSION},
        {{1,4,1,0,4,1},XPU_MALFORMED},{{1,4,1,0,4,0x21},XPU_MALFORMED},
        {{1,4,1,0,4,6},XPU_UNSUPPORTED_OPCODE},{{1,4,1,0,4,10},XPU_MACHINE_FRAME},
        {{1,4,1,0,4,0x2a},XPU_MALFORMED},{{1,4,1,0,4,0x40},XPU_MALFORMED},
        {{1,4,2,0,4,0x32,5,0x30},XPU_MALFORMED},{{0x29,0,0,0},XPU_MALFORMED},
        {{1,4,1,0,4,3},XPU_MALFORMED},{{1,4,1,0x25,4,0x13},XPU_MALFORMED},
        {{1,4,2,0,4,0x58,0,0},XPU_MALFORMED},{{1,4,3,0,4,0xc5,1,0,0,0},XPU_MALFORMED},
        {{1,4,3,0,4,0x69,8,0,0,0},XPU_MALFORMED},{{1,4,1,0x25,4,0x32},XPU_MALFORMED},
        {{1,4,1,0x21,4,3},XPU_MALFORMED},{{1,4,1,0x20,4,0x32},XPU_MALFORMED},
    };
    for(size_t i=0;i<sizeof bad/sizeof bad[0];++i){metadata(f,0x200,bad[i].bytes,sizeof bad[i].bytes);run(f,&fn,0x120,c,bad[i].status,0);}
    META(f,0x200,1,5,2,0,5,0x32,1,0x30);save(f,ENTRY-8,OLD_RBX);c=context(ENTRY-40);
    /* After a pop a branch out is a tail call. A bare one is refused when
     * no function table can say what it lands on. */
    META(f,0x170,0x48,0x83,0xc4,32,0x5b,0xeb,0x7f);
    CHECK(run(f,&fn,0x170,c,XPU_OK,1).method==XPU_EPILOG);
    META(f,0x170,0xeb,0x7f);
    run(f,&fn,0x170,c,XPU_UNSUPPORTED_EPILOG,0);
    META(f,0x170,0x48,0x83,0xc4,32,0x5b,0xff,0x25,0,0,0,0);
    CHECK(run(f,&fn,0x170,c,XPU_OK,1).method==XPU_EPILOG);
    META(f,0x170,0x48,0x83,0xc4,32,0x5b,0xf3,0xc3);
    CHECK(run(f,&fn,0x170,c,XPU_OK,1).method==XPU_EPILOG);
    /* Frame register R12 needs the SIB encoding in LEA. */
    META(f,0x200,1,10,3,0x2c,10,3,5,0x72,1,0xc0,0,0);
    META(f,0x170,0x49,0x8d,0x64,0x24,32,0x41,0x5c,0xc3);
    save(f,ENTRY-8,OLD_R12);c=context(ENTRY-72-0x100);c.gpr[12]=ENTRY-72+32;
    out=run(f,&fn,0x170,c,XPU_OK,1);CHECK(out.caller.gpr[12]==OLD_R12);
    c.gpr_known&=~(1u<<12);run(f,&fn,0x170,c,XPU_REGISTER_MISSING,0);
    c.gpr_known=0;run(f,&fn,0x170,c,XPU_REGISTER_MISSING,0);
    c=context(UINT64_MAX-7);run(f,NULL,0x180,c,XPU_MALFORMED,0);
    c=context(ENTRY+1);run(f,NULL,0x180,c,XPU_MALFORMED,0);
    /* No stack reads after metadata exhaustion. */
    for(unsigned i=0;i<32;++i) {
        unsigned at=0x400+i*16;META(f,at,0x21,0,0,0);
        put32(f->image+at+4,0x100);put32(f->image+at+8,0x180);put32(f->image+at+12,at+16);
    }
    fn.unwind=0x400;c=context(ENTRY);run(f,&fn,0x120,c,XPU_LIMIT,0);
}

/* The shared shapes, with explicit expected callers. wrong plants the old
 * reading of a body "jmp [rax]" as an epilog, which must fail. */
static void shapes(struct fixture *f,int wrong) {
    struct xpu_function fn={uw_rows[0][0],uw_rows[0][1],uw_rows[0][2]};
    for(size_t i=0;i<sizeof uw_cases/sizeof uw_cases[0];++i) {
        const struct uw_case *k=&uw_cases[i];
        memset(f->image,0x90,f->size);memset(f->memory,0,0x100000);
        for(unsigned r=0;r<3;++r)for(unsigned j=0;j<3;++j)put32(f->image+0x300+r*12+j*4,uw_rows[r][j]);
        f->rows=3;
        metadata(f,0x200,k->record,k->record_size);metadata(f,k->pc,k->code,k->code_size);
        metadata(f,0x240,uw_callee_record,sizeof uw_callee_record);metadata(f,0x250,uw_cold_record,sizeof uw_cold_record);
        save(f,ENTRY,RETURN_PC);
        struct xpu_context c=context(ENTRY-k->used);
        if(k->frame){save(f,ENTRY-8,OLD_RBP);save(f,ENTRY-16,OLD_RBX);c.gpr[5]=ENTRY-8;}
        else save(f,ENTRY-8,OLD_RBX);
        if(k->saved)c.gpr[3]=0xdead;
        fprintf(stderr,"shape %s\n",k->name);
        struct xpu_result out=run(f,&fn,k->pc,c,XPU_OK,1);
        enum xpu_method method=k->expect==UW_EPILOG?XPU_EPILOG:XPU_UNWIND;
        if(wrong && !strcmp(k->name,"body-jmp-mem"))method=XPU_EPILOG;
        CHECK(out.method==method);
        CHECK(out.caller.gpr[3]==OLD_RBX && out.caller.gpr[5]==OLD_RBP);
    }
    f->rows=0;
}
struct file {unsigned char *bytes;size_t size;};
static enum xpe_status file_read(void *u,uint64_t at,void *out,size_t n) {
    struct file *f=u;if(at>f->size || n>f->size-at)return XPE_IO;
    memcpy(out,f->bytes+(size_t)at,n);return XPE_OK;
}
static void compiled(const char *path, int wrong) {
    FILE *in=fopen(path,"rb");CHECK(in);CHECK(!fseek(in,0,SEEK_END));long length=ftell(in);CHECK(length>0);rewind(in);
    struct file file={malloc((size_t)length),(size_t)length};CHECK(file.bytes);CHECK(fread(file.bytes,1,file.size,in)==file.size);CHECK(!fclose(in));
    struct xpe_source source={&file,file.size,XPE_FILE,file_read};struct xpe_image *image=NULL;CHECK(xpe_load(&source,&image)==XPE_OK);
    const struct xpe_info *info=xpe_info(image);CHECK(info->function_count==5 && info->codeview_count==1);
    struct fixture f={.image=calloc(1,info->image_size),.memory=calloc(1,0x100000),.size=info->image_size};CHECK(f.image && f.memory);
    memcpy(f.image,file.bytes,info->headers_size);
    for(unsigned i=0;i<info->section_count;++i){const struct xpe_section *s=xpe_section(image,i);memcpy(f.image+s->rva,file.bytes+s->raw_offset,s->raw_size);}
    save(&f,ENTRY,RETURN_PC);save(&f,ENTRY-8,OLD_RBX);
    const struct {const char *name;unsigned used;int changed;enum xpu_method method;} rows[]={
        {"uw_push",0,0,XPU_UNWIND},{"uw_push_pushed",8,3,XPU_UNWIND},{"uw_push_body",40,3,XPU_UNWIND},
        {"uw_push_epilog",40,3,XPU_EPILOG},{"uw_push_pop",8,3,XPU_EPILOG},{"uw_push_ret",0,0,XPU_EPILOG},
        {"uw_frame",0,0,XPU_UNWIND},{"uw_frame_pushed",8,0,XPU_UNWIND},{"uw_frame_allocated",72,0,XPU_UNWIND},
        {"uw_frame_body",328,5,XPU_UNWIND},{"uw_frame_epilog",328,5,XPU_EPILOG},{"uw_frame_pop",8,5,XPU_EPILOG},{"uw_frame_ret",0,0,XPU_EPILOG},
        {"uw_saved",0,0,XPU_UNWIND},{"uw_saved_allocated",88,0,XPU_UNWIND},{"uw_saved_gpr",88,12,XPU_UNWIND},
        {"uw_saved_body",88,12,XPU_UNWIND},{"uw_saved_epilog",88,0,XPU_EPILOG},{"uw_saved_ret",0,0,XPU_EPILOG},
        {"uw_large",0,0,XPU_UNWIND},{"uw_large_body",4096,0,XPU_UNWIND},{"uw_large_epilog",4096,0,XPU_EPILOG},{"uw_large_ret",0,0,XPU_EPILOG},
        {"uw_far",0,0,XPU_UNWIND},{"uw_far_body",524296,0,XPU_UNWIND},{"uw_far_epilog",524296,0,XPU_EPILOG},{"uw_far_ret",0,0,XPU_EPILOG},
        {"uw_leaf",0,0,XPU_LEAF}
    };
    for(size_t i=0;i<sizeof rows/sizeof rows[0];++i) {
        const char *name=rows[i].name;const struct xpe_export *e=xpe_find_export(image,name);CHECK(e && !e->forwarder);
        const struct xpe_function *pe=xpe_function_at(image,e->rva);struct xpu_function fn={0};
        if(pe)fn=(struct xpu_function){pe->begin,pe->end,pe->unwind};
        struct xpu_context c=context(ENTRY-rows[i].used);
        if(rows[i].changed)c.gpr[rows[i].changed]=0xdead;
        if(!strncmp(name,"uw_frame",8)){save(&f,ENTRY-8,OLD_RBP);if(rows[i].changed==5)c.gpr[5]=ENTRY-72+32;}
        else save(&f,ENTRY-8,OLD_RBX);
        if(!strncmp(name,"uw_saved",8)) {
            save(&f,ENTRY-88+32,OLD_R12);memset(f.memory+(ENTRY-88+48-STACK_BASE),0x66,16);
            if(!strcmp(name,"uw_saved_body"))memset(c.xmm[6],0,16);
        }
        fprintf(stderr,"compiler boundary %s rva=%x\n",name,e->rva);
        struct xpu_result out=run(&f,pe?&fn:NULL,e->rva,c,XPU_OK,1);
        CHECK(out.method==rows[i].method);
        CHECK(out.caller.gpr[3]==OLD_RBX && out.caller.gpr[5]==OLD_RBP && out.caller.gpr[12]==OLD_R12);
        if(!strcmp(name,"uw_saved_body"))for(unsigned j=0;j<16;++j)CHECK(out.caller.xmm[6][j]==0x66);
        if(wrong)CHECK(out.caller.rip==RETURN_PC+1);
    }
    xpe_destroy(image);free(f.image);free(f.memory);free(file.bytes);
}
int main(int argc,char **argv) {
    CHECK(argc==2 || argc==3);
    const int wrong_shape=argc==3 && !strcmp(argv[2],"wrong-shape");
    compiled(argv[1],argc==3 && !wrong_shape);
    struct fixture f={.image=calloc(1,0x2000),.memory=calloc(1,0x100000),.size=0x2000};CHECK(f.image && f.memory);
    synthetic(&f);shapes(&f,wrong_shape);free(f.image);free(f.memory);
    printf("%u unwind and every-read fault checks passed\n",checks);return 0;
}
