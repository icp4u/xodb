#include "pe_unwind.h"
#include <string.h>

#define NONVOL 0xf0e8u
#define RSP 4u
#define CHAINS 32u
struct record {
    struct xpu_function function;
    unsigned char codes[512];
    unsigned flags, prolog, slots, frame, bias;
};
struct step {
    const struct xpu_source *source;
    struct xpu_context context;
    size_t stack_bytes;
};
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | (unsigned)p[1]<<8); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p+4)<<32; }
static int nonvolatile(unsigned reg) { return (NONVOL & (1u<<reg)) != 0; }
static int add(uint64_t a, uint64_t b, uint64_t *out) {
    if (b>UINT64_MAX-a) return 0;
    *out=a+b; return 1;
}
static int displacement(uint64_t a, int64_t b, uint64_t *out) {
    if (b>=0) return add(a,(uint64_t)b,out);
    uint64_t n=(uint64_t)(-b);
    if (a<n) return 0;
    *out=a-n; return 1;
}
static enum xpu_status metadata(const struct xpu_source *s,uint64_t at,void *out,size_t n) {
    if (at>s->image_size || n>s->image_size-at) return XPU_MALFORMED;
    return s->metadata(s->context,(uint32_t)at,out,n)?XPU_OK:XPU_METADATA_MISSING;
}
static enum xpu_status stack(struct step *s,uint64_t at,void *out,size_t n) {
    if (n>16384-s->stack_bytes) return XPU_LIMIT;
    if (at>UINT64_MAX-n) return XPU_MALFORMED;
    s->stack_bytes+=n;
    return s->source->stack(s->source->context,at,out,n)?XPU_OK:XPU_STACK_MISSING;
}
static enum xpu_status pop(struct step *s,uint64_t *value) {
    unsigned char bytes[8]; uint64_t next;
    if (!add(s->context.gpr[RSP],8,&next)) return XPU_MALFORMED;
    enum xpu_status status=stack(s,s->context.gpr[RSP],bytes,8);
    if (status!=XPU_OK) return status;
    *value=u64(bytes); s->context.gpr[RSP]=next; return XPU_OK;
}
static unsigned slots(unsigned op,unsigned info) {
    if (op==1) return info==1?3:2;
    if (op==4 || op==8) return 2;
    if (op==5 || op==9) return 3;
    return 1;
}
static uint32_t operand(const unsigned char *p,unsigned op,unsigned info) {
    if (op==1) return info==1?u32(p+2):(uint32_t)u16(p+2)*8;
    if (op==2) return info*8+8;
    if (op==4) return (uint32_t)u16(p+2)*8;
    if (op==8) return (uint32_t)u16(p+2)*16;
    if (op==5 || op==9) return u32(p+2);
    return 0;
}
static enum xpu_status records(const struct xpu_source *s,struct xpu_function f,
                               struct record *out,unsigned *count) {
    unsigned frame=0;
    for (unsigned depth=0;depth<CHAINS;++depth) {
        if (f.begin>=f.end || f.end>s->image_size) return XPU_MALFORMED;
        /* The low-bit indirection extension needs different function lookup
         * semantics. Do not misinterpret its RUNTIME_FUNCTION as UNWIND_INFO. */
        if (f.unwind&1) return XPU_UNSUPPORTED_CHAIN;
        if (!f.unwind || (f.unwind&3)) return XPU_MALFORMED;
        for (unsigned i=0;i<depth;++i)
            if (out[i].function.unwind==f.unwind) return XPU_MALFORMED;
        unsigned char header[4];
        enum xpu_status status=metadata(s,f.unwind,header,sizeof header);
        if (status!=XPU_OK) return status;
        if ((header[0]&7)!=1) return XPU_UNSUPPORTED_VERSION;
        struct record *r=&out[depth]; r->function=f;
        r->flags=header[0]>>3; r->prolog=header[1]; r->slots=header[2];
        r->frame=header[3]&15; r->bias=(header[3]>>4)*16;
        if ((r->flags&~7u) || ((r->flags&4) && (r->flags&3)) ||
            (r->frame && !nonvolatile(r->frame)) || (!r->frame && r->bias) ||
            r->prolog>f.end-f.begin) return XPU_MALFORMED;
        if (depth && header[3]!=frame) return XPU_MALFORMED;
        frame=header[3];
        unsigned bytes=((r->slots+1)&~1u)*2;
        if (bytes) {
            status=metadata(s,(uint64_t)f.unwind+4,r->codes,bytes);
            if (status!=XPU_OK) return status;
        }
        /* Offsets descend from the prolog size. Offset 0 is valid: a code
         * fragment entered with its frame already built (a compiler's cold
         * half) lists every code there. Pushes and the frame-pointer set
         * may come in any order, as "push rbp; mov rbp,rsp; push ..." does. */
        unsigned previous=r->prolog, setframe=0;
        for (unsigned i=0;i<r->slots;) {
            const unsigned char *p=r->codes+2*i;
            unsigned op=p[1]&15,info=p[1]>>4,n=slots(op,info);
            if (n>r->slots-i || p[0]>previous) return XPU_MALFORMED;
            previous=p[0];
            if ((op==0 || op==4 || op==5) && !nonvolatile(info)) return XPU_MALFORMED;
            if ((op==8 || op==9) && info<6) return XPU_MALFORMED;
            if (op==1 && info>1) return XPU_MALFORMED;
            if (op==3 && (info || !r->frame || ++setframe>1)) return XPU_MALFORMED;
            if (op==10) return info>1?XPU_MALFORMED:XPU_MACHINE_FRAME;
            if (op==6 || op==7 || op>10) return XPU_UNSUPPORTED_OPCODE;
            uint32_t value=operand(p,op,info);
            if (op==1 && (!value || (value&7))) return XPU_MALFORMED;
            if ((op==5 && (value&7)) || (op==9 && (value&15))) return XPU_MALFORMED;
            /* Secondary records only describe delayed saves; stack allocation
             * and frame establishment belong to the primary record. */
            if ((r->flags&4) && op!=4 && op!=5 && op!=8 && op!=9) return XPU_UNSUPPORTED_CHAIN;
            i+=n;
        }
        if (!(r->flags&4) && (!!r->frame != !!setframe)) return XPU_MALFORMED;
        uint64_t trailer=(uint64_t)f.unwind+4+bytes;
        unsigned char tail[12];
        if (r->flags&4) {
            status=metadata(s,trailer,tail,12); if (status!=XPU_OK) return status;
            f=(struct xpu_function){u32(tail),u32(tail+4),u32(tail+8)};
        } else {
            if (r->flags&3) {
                status=metadata(s,trailer,tail,4); if (status!=XPU_OK) return status;
                if (!u32(tail) || u32(tail)>=s->image_size) return XPU_MALFORMED;
            }
            *count=depth+1; return XPU_OK;
        }
    }
    return XPU_LIMIT;
}

enum xpu_status xpu_validate(const struct xpu_source *source,const struct xpu_function *function) {
    if (!source || !source->metadata || !function) return XPU_MALFORMED;
    struct record chain[CHAINS]; unsigned count=0;
    return records(source,*function,chain,&count);
}
struct code_reader { const struct xpu_source *source; uint32_t start,end; unsigned at; };
static enum xpu_status code(struct code_reader *r,unsigned char *out,unsigned n) {
    if (n>64-r->at) return XPU_LIMIT;
    if (r->start>=r->end || r->at>r->end-r->start || n>r->end-r->start-r->at) return XPU_CODE_MISSING;
    if (!r->source->code(r->source->context,r->start+r->at,out,n)) return XPU_CODE_MISSING;
    r->at+=n; return XPU_OK;
}
/* A bare jmp that leaves the function is a tail call only if it lands on a
 * callee. Landing inside another table row, or on a row whose frame exists on
 * entry (a chained record, or codes with no prolog), is a jump between
 * fragments of one function and the frame is still intact. */
static enum xpu_status tail_target(const struct xpu_source *s,uint32_t target,int *tail) {
    struct xpu_function f; unsigned char header[4];
    if (!s->function) return XPU_UNSUPPORTED_EPILOG;
    int found=s->function(s->context,target,&f);
    if (found<0) return XPU_METADATA_MISSING;
    *tail=1;
    if (!found) return XPU_OK;
    if (target<f.begin || target>=f.end) return XPU_MALFORMED;
    if (f.begin!=target) { *tail=0; return XPU_OK; }
    if ((f.unwind&3) || !f.unwind) return XPU_UNSUPPORTED_EPILOG;
    enum xpu_status status=metadata(s,f.unwind,header,sizeof header);
    if (status!=XPU_OK) return status;
    if ((header[0]&7)!=1) return XPU_UNSUPPORTED_EPILOG;
    *tail=!((header[0]>>3)&4) && (header[1] || !header[2]);
    return XPU_OK;
}
/* Recognize the entire suffix before reading any stack data. This is the
 * platform's epilog grammar, not an instruction decoder or a stack scan:
 *   [add rsp,imm | lea rsp,disp[frame]]  pop reg ...  ret | jmp out
 * A jmp counts only in the forms compilers reserve for leaving a function.
 * Anything else, a doubtful case included, is body code and is unwound from
 * the unwind codes, as the platform does. */
static enum xpu_status epilog(struct step *s,const struct record *r,uint32_t pc,int *matched) {
    struct code_reader reader={s->source,pc,r->function.end,0};
    unsigned char b[8]; unsigned pops[16],pop_count=0,adjust_reg=RSP;
    int64_t adjust=0; unsigned extra=0; int adjusted=0,found=0;
    enum xpu_status status=code(&reader,b,1); if (status!=XPU_OK) return status;
    unsigned rex=0,opcode=b[0];
    if ((opcode&0xf0)==0x40) {
        rex=opcode; status=code(&reader,b,1); if (status!=XPU_OK) return status; opcode=b[0];
    }
    if ((rex==0x48 && (opcode==0x81 || opcode==0x83)) ||
        ((rex==0x48 || rex==0x49) && opcode==0x8d)) {
        status=code(&reader,b,1); if (status!=XPU_OK) return status;
        unsigned modrm=b[0];
        if (opcode==0x8d) {
            unsigned mode=modrm>>6,reg=(modrm&7)+((rex&1)*8);
            if (!r->frame || reg!=r->frame || ((modrm>>3)&7)!=RSP || (mode!=1 && mode!=2)) return XPU_OK;
            /* R12 uses a SIB byte for a base-only memory operand. */
            if ((modrm&7)==4) {
                status=code(&reader,b,1); if (status!=XPU_OK) return status;
                if (b[0]!=0x24) return XPU_OK;
            }
            status=code(&reader,b,mode==1?1:4); if (status!=XPU_OK) return status;
            adjust=mode==1?(int8_t)b[0]:(int32_t)u32(b); adjust_reg=reg;
        } else {
            if (modrm!=0xc4) return XPU_OK;
            status=code(&reader,b,opcode==0x83?1:4); if (status!=XPU_OK) return status;
            adjust=opcode==0x83?(int8_t)b[0]:(int32_t)u32(b);
            if (adjust<0) return XPU_OK;
        }
        adjusted=1; rex=0;
        status=code(&reader,b,1); if (status!=XPU_OK) return status; opcode=b[0];
    }
    for (;;) {
        if (!rex && (opcode&0xf0)==0x40) {
            rex=opcode; status=code(&reader,b,1); if (status!=XPU_OK) return status; opcode=b[0];
        }
        if (opcode<0x58 || opcode>0x5f) break;
        /* Only REX.B changes a pop. A volatile register is popped as well:
         * its value is dropped after the step, the stack slot is not. */
        unsigned reg=opcode-0x58+((rex&1)*8);
        if (reg==RSP) return XPU_UNSUPPORTED_EPILOG;
        if (pop_count==16) return XPU_LIMIT;
        pops[pop_count++]=reg; rex=0;
        status=code(&reader,b,1); if (status!=XPU_OK) return status; opcode=b[0];
    }
    if (!rex && opcode==0xc3) found=1;
    else if (!rex && opcode==0xf3) {
        status=code(&reader,b,1); if (status!=XPU_OK) return status;
        found=b[0]==0xc3;
    } else if (!rex && opcode==0xc2) {
        status=code(&reader,b,2); if (status!=XPU_OK) return status; extra=u16(b); found=1;
    } else if (opcode==0xff) {
        /* jmp [rip+disp32] is the import tail call. On any other indirect
         * jmp, REX.W is the compilers' mark for one that leaves the function;
         * without it "jmp rax" or "jmp [table+reg*8]" is a switch dispatch
         * in the body, with the frame intact. */
        status=code(&reader,b,1); if (status!=XPU_OK) return status;
        found=((b[0]>>3)&7)==4 && (rex?(rex&0xf8)==0x48:b[0]==0x25);
    } else if (!rex && (opcode==0xe9 || opcode==0xeb)) {
        status=code(&reader,b,opcode==0xeb?1:4); if (status!=XPU_OK) return status;
        int64_t target=(int64_t)pc+reader.at+(opcode==0xeb?(int8_t)b[0]:(int32_t)u32(b));
        if (target>=r->function.begin && target<r->function.end)
            /* Only a function with a prolog can restart itself. */
            found=target==r->function.begin && !(r->flags&4) && r->prolog;
        else if (adjusted || pop_count || target<0 || target>=s->source->image_size) found=1;
        else {
            status=tail_target(s->source,(uint32_t)target,&found); if (status!=XPU_OK) return status;
        }
    }
    if (!found) return XPU_OK;
    if (!(s->context.gpr_known&(1u<<adjust_reg))) return XPU_REGISTER_MISSING;
    if (!displacement(s->context.gpr[adjust_reg],adjust,&s->context.gpr[RSP])) return XPU_MALFORMED;
    for (unsigned i=0;i<pop_count;++i) {
        status=pop(s,&s->context.gpr[pops[i]]); if (status!=XPU_OK) return status;
        s->context.gpr_known|=(uint16_t)(1u<<pops[i]);
    }
    status=pop(s,&s->context.rip); if (status!=XPU_OK) return status;
    if (!add(s->context.gpr[RSP],extra,&s->context.gpr[RSP])) return XPU_MALFORMED;
    *matched=1; return XPU_OK;
}
static enum xpu_status unwind(struct step *s,const struct record *records,unsigned count,uint32_t pc) {
    uint64_t establisher=s->context.gpr[RSP];
    const struct record *first=&records[0];
    unsigned offset=pc-first->function.begin;
    int established=count>1 || offset>=first->prolog;
    if (first->frame && !established) {
        for (unsigned i=0;i<first->slots;) {
            const unsigned char *p=first->codes+2*i;
            if ((p[1]&15)==3 && p[0]<=offset) established=1;
            i+=slots(p[1]&15,p[1]>>4);
        }
    }
    if (first->frame && established) {
        if (!(s->context.gpr_known&(1u<<first->frame))) return XPU_REGISTER_MISSING;
        if (!displacement(s->context.gpr[first->frame],-(int64_t)first->bias,&establisher)) return XPU_MALFORMED;
    }
    for (unsigned depth=0;depth<count;++depth) {
        const struct record *r=&records[depth];
        for (unsigned i=0;i<r->slots;) {
            const unsigned char *p=r->codes+2*i;
            unsigned op=p[1]&15,info=p[1]>>4; i+=slots(op,info);
            if (!depth && p[0]>offset) continue;
            uint32_t value=operand(p,op,info); uint64_t address; unsigned char saved[16];
            enum xpu_status status;
            switch (op) {
            case 0:
                status=pop(s,&s->context.gpr[info]); if (status!=XPU_OK) return status;
                s->context.gpr_known|=(uint16_t)(1u<<info); break;
            case 1: case 2:
                if (!add(s->context.gpr[RSP],value,&s->context.gpr[RSP])) return XPU_MALFORMED;
                break;
            case 3: s->context.gpr[RSP]=establisher; break;
            case 4: case 5: case 8: case 9:
                if (r->frame && !established) return XPU_MALFORMED;
                if (!add(establisher,value,&address)) return XPU_MALFORMED;
                status=stack(s,address,saved,op<8?8:16); if (status!=XPU_OK) return status;
                if (op<8) { s->context.gpr[info]=u64(saved); s->context.gpr_known|=(uint16_t)(1u<<info); }
                else { memcpy(s->context.xmm[info],saved,16); s->context.xmm_known|=(uint16_t)(1u<<info); }
                break;
            default: return XPU_UNSUPPORTED_OPCODE;
            }
        }
    }
    return pop(s,&s->context.rip);
}
enum xpu_status xpu_step(const struct xpu_source *source,const struct xpu_function *function,
                         uint32_t pc,const struct xpu_context *input,struct xpu_result *out) {
    if (!out) return XPU_MALFORMED;
    /* Copy first so input may refer to the prior result's caller. */
    struct step s={.source=source}; if (input) s.context=*input;
    memset(out,0,sizeof *out);
    if (!source || !input || !source->stack || !source->metadata || !source->code || pc>=source->image_size) return XPU_MALFORMED;
    if (!(s.context.gpr_known&(1u<<RSP))) return XPU_REGISTER_MISSING;
    uint64_t old_sp=s.context.gpr[RSP];
    if (old_sp&7) return XPU_MALFORMED;
    enum xpu_method method=XPU_LEAF; enum xpu_status status;
    if (!function) status=pop(&s,&s.context.rip);
    else {
        if (pc<function->begin || pc>=function->end) return XPU_MALFORMED;
        struct record chain[CHAINS]; unsigned count=0;
        status=records(source,*function,chain,&count); if (status!=XPU_OK) return status;
        int matched=0; method=XPU_UNWIND;
        unsigned any_codes=0;
        for (unsigned i=0;i<count;++i) any_codes|=chain[i].slots;
        if (pc-function->begin>=chain[0].prolog && any_codes) {
            status=epilog(&s,&chain[0],pc,&matched); if (status!=XPU_OK) return status;
        }
        if (matched) method=XPU_EPILOG;
        else status=unwind(&s,chain,count,pc);
    }
    if (status!=XPU_OK) return status;
    if (s.context.gpr[RSP]<=old_sp || (s.context.gpr[RSP]&7)) return XPU_NO_PROGRESS;
    s.context.gpr_known&=(uint16_t)(NONVOL|(1u<<RSP)); s.context.xmm_known&=0xffc0u;
    for (unsigned i=0;i<16;++i) {
        if (!(s.context.gpr_known&(1u<<i))) s.context.gpr[i]=0;
        if (!(s.context.xmm_known&(1u<<i))) memset(s.context.xmm[i],0,16);
    }
    out->caller=s.context; out->cfa=s.context.gpr[RSP]; out->method=method;
    return XPU_OK;
}
