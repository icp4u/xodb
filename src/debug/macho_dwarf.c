#include "macho_dwarf.h"
#include <stdlib.h>
#include <string.h>

/* Mach-O section names have only sixteen bytes. Apple's truncated names
 * must be expanded before elfutils can find DWARF 5's indexed strings. */
static const struct { const char *segment, *mach, *elf; } names[] = {
    {"__DWARF", "__debug_abbrev", ".debug_abbrev"},
    {"__DWARF", "__debug_addr", ".debug_addr"},
    {"__DWARF", "__debug_aranges", ".debug_aranges"},
    {"__DWARF", "__debug_frame", ".debug_frame"},
    {"__DWARF", "__debug_info", ".debug_info"},
    {"__DWARF", "__debug_line", ".debug_line"},
    {"__DWARF", "__debug_line_str", ".debug_line_str"},
    {"__DWARF", "__debug_loc", ".debug_loc"},
    {"__DWARF", "__debug_loclists", ".debug_loclists"},
    {"__DWARF", "__debug_ranges", ".debug_ranges"},
    {"__DWARF", "__debug_rnglists", ".debug_rnglists"},
    {"__DWARF", "__debug_str", ".debug_str"},
    {"__DWARF", "__debug_str_offs", ".debug_str_offsets"},
    {"__DWARF", "__debug_types", ".debug_types"},
    {"__TEXT", "__eh_frame", ".eh_frame"},
};
#define COUNT (sizeof names / sizeof names[0])
static void w16(unsigned char *p, uint16_t x) {
    p[0]=(unsigned char)x;p[1]=(unsigned char)(x>>8);
}
static void w32(unsigned char *p, uint32_t x) {
    for (unsigned i=0;i<4;++i) p[i]=(unsigned char)(x>>(i*8));
}
static void w64(unsigned char *p, uint64_t x) {
    for (unsigned i=0;i<8;++i) p[i]=(unsigned char)(x>>(i*8));
}
static uint32_t r32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t r64(const unsigned char *p) {
    return (uint64_t)r32(p)|(uint64_t)r32(p+4)<<32;
}
static int offset_compare(const void *a, const void *b) {
    uint32_t x=*(const uint32_t *)a,y=*(const uint32_t *)b;
    return (x>y)-(x<y);
}
static enum xmo_status relocate(struct xmo_image *image, const struct xmo_section *section,
    unsigned char *bytes, xmo_dwarf_external external, void *user) {
    uint32_t symbols=0;
    enum xmo_status status=xmo_symbols(image,&symbols);
    if (status!=XMO_OK) return status;
    if (section->relocation_count>XMO_MAX_SYMBOLS) return XMO_LIMIT;
    unsigned char raw[XMO_MAX_CHUNK];
    /* Mach-O relocation lists are not required to be ordered. Refuse repeats
     * and partial overlaps instead of applying the same addend twice. A
     * sorted offset array also bounds this check without quadratic scans. */
    uint32_t *offsets=malloc((size_t)section->relocation_count*sizeof *offsets);
    if (!offsets && section->relocation_count) return XMO_NOMEM;
    for (uint32_t first=0;first<section->relocation_count;) {
        uint32_t count=section->relocation_count-first;
        if (count>XMO_MAX_CHUNK/8) count=XMO_MAX_CHUNK/8;
        status=xmo_read_relocations(image,section,first,count,raw);
        if (status!=XMO_OK) break;
        for (uint32_t i=0;i<count;++i) {
            uint32_t at=r32(raw+i*8), bits=r32(raw+i*8+4), symbol=bits&0x00ffffff;
            offsets[first+i]=at;
            /* Scattered, PC-relative, paired/subtractor and non-64-bit forms
             * need different relocation semantics; never guess an address. */
            if ((at&0x80000000u) || (bits>>28)!=0 || ((bits>>24)&1) || ((bits>>25)&3)!=3) { status=XMO_UNSUPPORTED;break; }
            if (at>section->size || section->size-at<8) { status=XMO_MALFORMED;break; }
            uint64_t value=r64(bytes+at);
            if ((bits>>27)&1) {
                if (symbol>=symbols) { status=XMO_MALFORMED;break; }
                const struct xmo_symbol *entry=xmo_symbol(image,symbol);
                unsigned flags=xmo_symbol_flags(entry);
                if (flags&(XMO_SYMBOL_DEFINED|XMO_SYMBOL_ABSOLUTE)) {
                    if (entry->value>UINT64_MAX-value) { status=XMO_MALFORMED;break; }
                    value+=entry->value;
                } else if ((flags&XMO_SYMBOL_UNDEFINED) && external) status=external(user,symbol,value,&value);
                else status=XMO_UNSUPPORTED;
                if (status!=XMO_OK) break;
                w64(bytes+at,value);
            } else {
                const struct xmo_section *target=symbol ? xmo_section(image,symbol-1) : NULL;
                /* Local UNSIGNED stores the object address, not an offset
                 * needing the section address added a second time. */
                if (!target || value<target->address || value-target->address>target->size) { status=XMO_MALFORMED;break; }
            }
        }
        if (status!=XMO_OK) break;
        first+=count;
    }
    if (status==XMO_OK) {
        qsort(offsets,section->relocation_count,sizeof *offsets,offset_compare);
        for (uint32_t i=1;i<section->relocation_count;++i)
            if ((uint64_t)offsets[i-1]+8>offsets[i]) { status=XMO_MALFORMED;break; }
    }
    free(offsets);return status;
}
void xmo_dwarf_free(struct xmo_dwarf *out) {
    if (out) { free(out->bytes);memset(out,0,sizeof *out); }
}
static enum xmo_status build(const struct xmo_image *image, uint64_t allowance,
    xmo_dwarf_external external, void *user, int object, struct xmo_dwarf *out) {
    if (!image || !out) return XMO_MALFORMED;
    memset(out,0,sizeof *out);
    const struct xmo_info *info=xmo_info(image);
    if ((info->filetype==XMO_MH_OBJECT)!=object) return XMO_UNSUPPORTED;
    if (info->cputype!=XMO_CPU_ARM64 && info->cputype!=XMO_CPU_X86_64) return XMO_UNSUPPORTED;
    if (!allowance || allowance>XMO_MAX_RETAINED_BYTES) allowance=XMO_MAX_RETAINED_BYTES;
    const struct xmo_section *sections[COUNT]={0};
    uint64_t offsets[COUNT]={0};uint32_t string_offsets[COUNT]={0};
    size_t count=0, string_size=11; /* NUL + .shstrtab + NUL */
    for (unsigned i=0;i<info->section_count;++i) {
        const struct xmo_section *section=xmo_section(image,i);
        for (size_t j=0;j<COUNT;++j) {
            if (strcmp(section->segment,names[j].segment) || strcmp(section->name,names[j].mach)) continue;
            if (sections[j]) return XMO_MALFORMED;
            sections[j]=section;
            if (!object && section->relocation_count) return XMO_UNSUPPORTED;
            if (!section->size) continue;
            struct xmo_range range;
            enum xmo_status status=xmo_section_range(image,section,&range);
            if (status!=XMO_OK) return status;
            ++count;string_offsets[j]=(uint32_t)string_size;
            string_size+=strlen(names[j].elf)+1;
        }
    }
    if (!count) return XMO_UNAVAILABLE;
    uint64_t string_at=64+(count+2)*64;
    uint64_t size=string_at+string_size;
    for (size_t i=0;i<COUNT;++i) {
        if (!sections[i] || !sections[i]->size) continue;
        if (size>allowance || allowance-size<7) return XMO_LIMIT;
        size=(size+7)&~UINT64_C(7);
        if (sections[i]->size>allowance-size) return XMO_LIMIT;
        offsets[i]=size;size+=sections[i]->size;
    }
    if (size>SIZE_MAX || size>allowance) return XMO_LIMIT;
    unsigned char *bytes=calloc(1,(size_t)size);
    if (!bytes) return XMO_NOMEM;
    out->bytes=bytes;out->size=(size_t)size;
    memcpy(bytes,"\177ELF\002\001\001",7);
    w16(bytes+16,2); /* ET_EXEC section container; no program headers. */
    w16(bytes+18,info->cputype==XMO_CPU_ARM64 ? 183 : 62);
    w32(bytes+20,1);w64(bytes+40,64);w16(bytes+52,64);
    w16(bytes+58,64);w16(bytes+60,(uint16_t)(count+2));w16(bytes+62,1);
    unsigned char *sh=bytes+128;
    w32(sh,1);w32(sh+4,3);w64(sh+24,string_at);w64(sh+32,string_size);w64(sh+48,1);
    memcpy(bytes+string_at+1,".shstrtab",10);
    size_t ordinal=2;
    for (size_t i=0;i<COUNT;++i) {
        const struct xmo_section *section=sections[i];
        if (!section || !section->size) continue;
        memcpy(bytes+string_at+string_offsets[i],names[i].elf,strlen(names[i].elf)+1);
        sh=bytes+64+64*ordinal++;
        w32(sh,string_offsets[i]);w32(sh+4,1);w64(sh+16,section->address);
        w64(sh+24,offsets[i]);w64(sh+32,section->size);w64(sh+48,1);
        if (!strcmp(names[i].elf,".eh_frame")) { w64(sh+8,2);out->eh_frame=1; }
        else ++out->debug_sections;
        for (uint64_t at=0;at<section->size;) {
            size_t n=section->size-at>XMO_MAX_CHUNK ? XMO_MAX_CHUNK : (size_t)(section->size-at);
            enum xmo_status status=xmo_read_section(image,section,at,bytes+offsets[i]+at,n);
            if (status!=XMO_OK) { xmo_dwarf_free(out);return status; }
            at+=n;
        }
        if (section->relocation_count) {
            uint64_t scratch=(uint64_t)section->relocation_count*sizeof(uint32_t);
            if (scratch>allowance-size) { xmo_dwarf_free(out);return XMO_LIMIT; }
            enum xmo_status status=relocate((struct xmo_image *)image,section,bytes+offsets[i],external,user);
            if (status!=XMO_OK) { xmo_dwarf_free(out);return status; }
        }
    }
    return XMO_OK;
}
enum xmo_status xmo_dwarf_build(const struct xmo_image *image, uint64_t allowance, struct xmo_dwarf *out) {
    return build(image,allowance,NULL,NULL,0,out);
}
enum xmo_status xmo_dwarf_build_object(struct xmo_image *image, uint64_t allowance,
    xmo_dwarf_external external, void *user, struct xmo_dwarf *out) {
    return build(image,allowance,external,user,1,out);
}
