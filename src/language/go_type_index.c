#include "go_type_index.h"
#include "go_dwarf.h"
#include <dwarf.h>
#include <stdlib.h>
#include <string.h>
/* cmd/internal/dwarf defines these attributes; DW_CLS_GO_TYPEREF uses
 * AddSectionOffset/R_ADDROFF in Go 1.27.1's compiler/linker. */
enum { GO_KIND=0x2900, GO_KEY=0x2901, GO_ELEM=0x2902, GO_RUNTIME=0x2904 };
const char *xgo_type_metadata(Dwarf_Die *die, struct xgo_type_metadata *out) {
    memset(out,0,sizeof *out);
    Dwarf_Attribute a;Dwarf_Word n;Dwarf_Addr address;
    if(dwarf_attr(die,GO_KIND,&a)) {
        if(dwarf_formudata(&a,&n) || n>255)return "GoDwarfTypeMetadataInvalid";
        out->kind=(unsigned)n;if(n)out->present|=XGO_META_KIND;
    }
    if(dwarf_attr(die,GO_RUNTIME,&a)) {
        if(dwarf_formaddr(&a,&address))return "GoDwarfTypeMetadataInvalid";
        /* The linker emits zero for unreachable/no-runtime types. */
        if(address) {out->runtime_offset=address;out->present|=XGO_META_RUNTIME;}
    }
    if(dwarf_attr(die,GO_KEY,&a)) {
        if(!dwarf_formref_die(&a,&out->key))return "GoDwarfTypeMetadataInvalid";
        out->present|=XGO_META_KEY;
    }
    if(dwarf_attr(die,GO_ELEM,&a)) {
        if(!dwarf_formref_die(&a,&out->element))return "GoDwarfTypeMetadataInvalid";
        out->present|=XGO_META_ELEM;
    }
    if(out->kind==20) {
        /* cmd/link represents every interface as a typedef of runtime.eface
         * or runtime.iface. Record that proved representation for callers;
         * an unfamiliar chain stays explicitly unproved. */
        Dwarf_Die representation=*die;
        for(unsigned i=0;i<16;++i) {
            if(dwarf_tag(&representation)!=DW_TAG_typedef)break;
            if(!dwarf_attr(&representation,DW_AT_type,&a) || !dwarf_formref_die(&a,&representation))break;
        }
        const char *name=dwarf_diename(&representation);
        if(dwarf_tag(&representation)==DW_TAG_structure_type && name &&
           (!strcmp(name,"runtime.eface") || !strcmp(name,"runtime.iface"))) {
            out->interface_nonempty=!strcmp(name,"runtime.iface");out->present|=XGO_META_IFACE;
        }
    }
    return NULL;
}
struct entry {uint64_t offset;Dwarf_Off die,canonical;};
struct xgo_type_index {Dwarf *dwarf;struct entry *entries;size_t count,capacity;};
static const char *canonical(Dwarf_Die die,Dwarf_Off *out) {
    for(unsigned i=0;i<16;++i) {
        if(dwarf_tag(&die)!=DW_TAG_typedef) {*out=dwarf_dieoffset(&die);return NULL;}
        Dwarf_Attribute a;
        if(!dwarf_attr(&die,DW_AT_type,&a) || !dwarf_formref_die(&a,&die))return "GoDwarfTypeMetadataInvalid";
    }
    return "GoDwarfTypeDepthLimit";
}
static int compare(const void *a,const void *b) {
    const struct entry *x=a,*y=b;
    if(x->offset!=y->offset)return x->offset<y->offset ? -1:1;
    return x->die<y->die ? -1 : x->die!=y->die;
}
static const char *build(Dwarf *dw,struct xgo_type_index *out) {
    uint64_t length;if(!xgo_dwarf_info_size(dw,&length))return "GoDwarfMalformed";
    Dwarf_Off off=0,next;size_t header;unsigned work=0;
    for(unsigned cu=0;off<length;off=next,++cu) {
        uint8_t width;
        if(cu>=16384)return "GoDwarfUnitLimit";
        if(dwarf_nextcu(dw,off,&next,&header,NULL,&width,NULL) || width!=8 || next<=off || next>length || header>=next-off)return "GoDwarfMalformed";
        Dwarf_Die unit,die;if(!dwarf_offdie(dw,off+header,&unit))return "GoDwarfMalformed";
        if(dwarf_srclang(&unit)!=DW_LANG_Go)continue;
        int rc=dwarf_child(&unit,&die);if(rc<0)return "GoDwarfMalformed";if(rc>0)continue;
        do {
            if(++work>8000000)return "GoDwarfWorkLimit";
            struct xgo_type_metadata meta;const char *why=xgo_type_metadata(&die,&meta);if(why)return why;
            if(!(meta.present&XGO_META_RUNTIME))continue;
            Dwarf_Off resolved;if((why=canonical(die,&resolved)))return why;
            if(out->count==65536)return "GoDwarfRuntimeTypeLimit";
            if(out->count==out->capacity) {
                size_t cap=out->capacity ? out->capacity*2:128;
                struct entry *p=realloc(out->entries,cap*sizeof *p);if(!p)return "GoDwarfOutOfMemory";
                out->entries=p;out->capacity=cap;
            }
            out->entries[out->count++]=(struct entry){meta.runtime_offset,dwarf_dieoffset(&die),resolved};
        }while((rc=dwarf_siblingof(&die,&die))==0);
        if(rc<0)return "GoDwarfMalformed";
    }
    if(!out->count)return "GoRuntimeTypeMetadataUnavailable";
    qsort(out->entries,out->count,sizeof *out->entries,compare);
    return NULL;
}
const char *xgo_type_index_create(Dwarf *dw,struct xgo_type_index **out) {
    *out=NULL;if(!dw)return "GoDwarfUnavailable";
    struct xgo_type_index *p=calloc(1,sizeof *p);if(!p)return "GoDwarfOutOfMemory";
    p->dwarf=dw;const char *why=build(dw,p);
    if(why) {xgo_type_index_free(p);return why;}
    *out=p;return NULL;
}
void xgo_type_index_free(struct xgo_type_index *p) {if(p){free(p->entries);free(p);}}
size_t xgo_type_index_count(const struct xgo_type_index *p) {return p ? p->count:0;}
const char *xgo_type_index_find(const struct xgo_type_index *p,uint64_t offset,Dwarf_Die *out) {
    memset(out,0,sizeof *out);if(!p || !offset)return "GoRuntimeTypeMetadataUnavailable";
    size_t lo=0,hi=p->count;
    while(lo<hi){size_t mid=lo+(hi-lo)/2;if(p->entries[mid].offset<offset)lo=mid+1;else hi=mid;}
    if(lo==p->count || p->entries[lo].offset!=offset)return "GoRuntimeTypeMetadataUnavailable";
    const struct entry *first=&p->entries[lo];
    for(size_t i=lo+1;i<p->count && p->entries[i].offset==offset;++i)
        if(p->entries[i].canonical!=first->canonical)return "GoRuntimeTypeMetadataAmbiguous";
    return dwarf_offdie(p->dwarf,first->die,out) ? NULL:"GoDwarfMalformed";
}
