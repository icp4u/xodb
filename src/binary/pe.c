#include "pe.h"
#include <stdlib.h>
#include <string.h>

struct directory { uint32_t rva, size; };
struct xpe_image {
    struct xpe_source source;
    struct xpe_info info;
    struct xpe_section sections[XPE_MAX_SECTIONS];
    struct directory directories[16];
    struct xpe_export *exports;
    struct xpe_export_name *names;
    struct label { uint32_t rva, name; } *labels; /* address order */
    unsigned label_count;
    struct xpe_import *imports;
    struct xpe_function *functions;
    struct xpe_codeview codeviews[16];
    char *dll_names[1024];
    unsigned dll_count;
};
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | (unsigned)p[1] << 8); }
static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p+4) << 32; }
static int span(uint64_t at, uint64_t size, uint64_t limit) { return at <= limit && size <= limit-at; }
static int overlap(uint64_t a, uint64_t an, uint64_t b, uint64_t bn) {
    return an && bn && a < b+bn && b < a+an;
}
static enum xpe_status read_at(struct xpe_image *p, uint64_t at, void *out, size_t size) {
    if (!span(at, size, p->source.size)) return XPE_MALFORMED;
    unsigned char *bytes = out;
    while (size) {
        size_t chunk = size > 4096 ? 4096 : size;
        if (p->info.source_bytes > XPE_MAX_READ_BYTES-chunk || p->info.source_reads >= XPE_MAX_READS) return XPE_LIMIT;
        enum xpe_status status = p->source.read(p->source.context, at, bytes, chunk);
        if (status != XPE_OK) return status;
        p->info.source_bytes += chunk; ++p->info.source_reads;
        at += chunk; bytes += chunk; size -= chunk;
    }
    return XPE_OK;
}
/* A metadata range must belong to exactly one declared section or headers.
 * Crossing into a zero-fill tail is not a file read, and never reads whatever
 * unrelated file bytes happen to follow the section. */
static enum xpe_status locate(const struct xpe_image *p, uint32_t rva, uint64_t *offset, uint64_t *available) {
    if (rva >= p->info.image_size) return XPE_MALFORMED;
    if (rva < p->info.headers_size) {
        *offset = rva; *available = p->info.headers_size-rva;
    } else {
        const struct xpe_section *found = NULL;
        for (unsigned i=0; i<p->info.section_count; ++i) {
            const struct xpe_section *s = &p->sections[i];
            uint32_t extent = s->virtual_size > s->raw_size ? s->virtual_size : s->raw_size;
            if (rva < s->rva || (uint64_t)rva-s->rva >= extent) continue;
            if (found) return XPE_MALFORMED;
            found = s;
        }
        if (!found) return XPE_MALFORMED;
        uint64_t delta = (uint64_t)rva-found->rva;
        if (p->source.layout == XPE_FILE) {
            if (delta >= found->raw_size) return XPE_MALFORMED;
            *offset = (uint64_t)found->raw_offset+delta;
            *available = found->raw_size-delta;
        } else {
            uint32_t extent = found->virtual_size > found->raw_size ? found->virtual_size : found->raw_size;
            *offset = rva; *available = extent-delta;
        }
    }
    if (!span(*offset, *available, p->source.size)) return XPE_MALFORMED;
    return XPE_OK;
}
static const struct xpe_section *virtual_range(const struct xpe_image *p, uint32_t rva, uint64_t size) {
    for(unsigned i=0;i<p->info.section_count;++i) {
        const struct xpe_section *s=&p->sections[i];
        uint32_t extent=s->virtual_size>s->raw_size?s->virtual_size:s->raw_size;
        if(rva>=s->rva && span((uint64_t)rva-s->rva,size,extent))return s;
    }
    return NULL;
}
enum xpe_status xpe_read_rva(struct xpe_image *p, uint32_t rva, void *out, size_t size) {
    if (!p || (!out && size)) return XPE_MALFORMED;
    uint64_t offset, available;
    enum xpe_status status = locate(p, rva, &offset, &available);
    if (status != XPE_OK) return status;
    if (size > available) return XPE_MALFORMED;
    return read_at(p, offset, out, size);
}
enum xpe_status xpe_read_range(const struct xpe_image *p, uint32_t rva, void *out, size_t size) {
    if (!p || (!out && size)) return XPE_MALFORMED;
    if (size>4096) return XPE_LIMIT;
    uint64_t offset, available;
    enum xpe_status status=locate(p,rva,&offset,&available);
    if (status!=XPE_OK) return status;
    if (size>available) return XPE_MALFORMED;
    return p->source.read(p->source.context,offset,out,size);
}
static void *retain(struct xpe_image *p, size_t size) {
    if (!size || size > XPE_MAX_RETAINED_BYTES-p->info.retained_bytes) return NULL;
    void *result = calloc(1, size);
    if (result) p->info.retained_bytes += size;
    return result;
}
static enum xpe_status string_at(struct xpe_image *p, uint32_t rva, uint64_t bound, char **out) {
    uint64_t offset, available;
    enum xpe_status status = locate(p, rva, &offset, &available);
    if (status != XPE_OK) return status;
    if (bound < available) available = bound;
    char bytes[4096]; size_t done=0;
    while (done < sizeof bytes && done < available) {
        size_t count = sizeof bytes-done;
        if (count > 64) count = 64;
        if (count > available-done) count = (size_t)(available-done);
        status = read_at(p, offset+done, bytes+done, count);
        if (status != XPE_OK) return status;
        char *end = memchr(bytes+done, 0, count);
        if (end) {
            size_t length = (size_t)(end-bytes)+1;
            if (length > XPE_MAX_RETAINED_BYTES-p->info.retained_bytes) return XPE_LIMIT;
            char *text = retain(p, length);
            if (!text) return XPE_NOMEM;
            memcpy(text, bytes, length); *out=text; return XPE_OK;
        }
        done += count;
    }
    return available >= sizeof bytes ? XPE_LIMIT : XPE_MALFORMED;
}
static enum xpe_status headers(struct xpe_image *p) {
    unsigned char dos[64], coff[24], optional[240], raw[40];
    if (p->source.size < 2) return XPE_NOT_PE;
    enum xpe_status status = read_at(p, 0, dos, 2);
    if (status != XPE_OK) return status;
    if (dos[0]!='M' || dos[1]!='Z') return XPE_NOT_PE;
    status = read_at(p, 0, dos, sizeof dos); if (status != XPE_OK) return status;
    uint32_t pe = u32(dos+60);
    if (pe < sizeof dos) return XPE_MALFORMED;
    status = read_at(p, pe, coff, sizeof coff); if (status != XPE_OK) return status;
    if (memcmp(coff,"PE\0\0",4)) return XPE_MALFORMED;
    p->info.machine=u16(coff+4); p->info.section_count=u16(coff+6);
    p->info.timestamp=u32(coff+8); p->info.characteristics=u16(coff+22);
    if (p->info.machine != 0x8664) return XPE_UNSUPPORTED;
    if (!p->info.section_count) return XPE_MALFORMED;
    if (p->info.section_count > XPE_MAX_SECTIONS) return XPE_LIMIT;
    uint16_t optional_size=u16(coff+20);
    if (optional_size < 112) return XPE_MALFORMED;
    size_t want=optional_size < sizeof optional ? optional_size : sizeof optional;
    status=read_at(p,(uint64_t)pe+24,optional,want); if(status!=XPE_OK)return status;
    if (u16(optional)!=0x20b) return XPE_UNSUPPORTED;
    uint32_t dirs=u32(optional+108);
    if (dirs > (optional_size-112u)/8u) return XPE_MALFORMED;
    if (dirs > 16) dirs=16;
    p->info.preferred_base=u64(optional+24);p->info.entry_rva=u32(optional+16);
    p->info.section_alignment=u32(optional+32);p->info.file_alignment=u32(optional+36);
    p->info.image_size=u32(optional+56);p->info.headers_size=u32(optional+60);
    uint32_t sa=p->info.section_alignment,fa=p->info.file_alignment;
    if (!sa || !fa || (sa&(sa-1)) || (fa&(fa-1)) || sa<fa) return XPE_MALFORMED;
    uint64_t table=(uint64_t)pe+24+optional_size;
    if (!p->info.image_size || p->info.headers_size>p->info.image_size ||
        !span(table,(uint64_t)p->info.section_count*40,p->info.headers_size) ||
        p->info.headers_size>p->source.size || p->info.entry_rva>=p->info.image_size ||
        p->info.preferred_base>UINT64_MAX-p->info.image_size) return XPE_MALFORMED;
    if (p->source.layout==XPE_MEMORY && p->source.size<p->info.image_size) return XPE_MALFORMED;
    for (unsigned i=0;i<dirs;++i) {
        struct directory *d=&p->directories[i];d->rva=u32(optional+112+i*8);d->size=u32(optional+116+i*8);
        /* Certificates use file offsets, including in an image header. */
        if (i!=4 && d->size && !span(d->rva,d->size,p->info.image_size)) return XPE_MALFORMED;
    }
    for(unsigned i=0;i<p->info.section_count;++i) {
        status=read_at(p,table+i*40,raw,sizeof raw);if(status!=XPE_OK)return status;
        struct xpe_section *s=&p->sections[i];memcpy(s->name,raw,8);
        s->virtual_size=u32(raw+8);s->rva=u32(raw+12);s->raw_size=u32(raw+16);s->raw_offset=u32(raw+20);s->characteristics=u32(raw+36);
        uint32_t extent=s->virtual_size>s->raw_size?s->virtual_size:s->raw_size;
        if (extent && (s->rva<p->info.headers_size || !span(s->rva,extent,p->info.image_size)))return XPE_MALFORMED;
        if (s->raw_size && (s->raw_offset<p->info.headers_size ||
            (p->source.layout==XPE_FILE && !span(s->raw_offset,s->raw_size,p->source.size))))return XPE_MALFORMED;
        for(unsigned j=0;j<i;++j) {
            const struct xpe_section *old=&p->sections[j];uint32_t old_extent=old->virtual_size>old->raw_size?old->virtual_size:old->raw_size;
            if(overlap(s->rva,extent,old->rva,old_extent) || overlap(s->raw_offset,s->raw_size,old->raw_offset,old->raw_size))return XPE_MALFORMED;
        }
    }
    return XPE_OK;
}
enum xpe_status xpe_validate_loaded_headers(const struct xpe_image *file, const struct xpe_source *source) {
    if (!file || !source || !source->read || source->layout != XPE_MEMORY) return XPE_MALFORMED;
    struct xpe_image *loaded=calloc(1,sizeof *loaded);
    if (!loaded) return XPE_NOMEM;
    loaded->source=*source;
    enum xpe_status status=headers(loaded);
    if (status==XPE_OK) {
        const struct xpe_info *a=&file->info,*b=&loaded->info;
        if (a->image_size!=b->image_size || a->headers_size!=b->headers_size ||
            a->entry_rva!=b->entry_rva || a->timestamp!=b->timestamp ||
            a->section_alignment!=b->section_alignment || a->file_alignment!=b->file_alignment ||
            a->machine!=b->machine || a->characteristics!=b->characteristics ||
            a->section_count!=b->section_count ||
            memcmp(file->directories,loaded->directories,sizeof file->directories) ||
            memcmp(file->sections,loaded->sections,a->section_count*sizeof *file->sections)) status=XPE_CHANGED;
    }
    free(loaded);
    return status;
}
static enum xpe_status array(struct xpe_image *p, uint32_t rva, unsigned count, size_t width, unsigned char **out) {
    *out=NULL;
    if (!count) return XPE_OK;
    size_t size=(size_t)count*width;
    if (count && size/width!=count) return XPE_LIMIT;
    if (size>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes) return XPE_LIMIT;
    unsigned char *bytes=malloc(size);if(!bytes)return XPE_NOMEM;
    enum xpe_status status=xpe_read_rva(p,rva,bytes,size);
    if(status!=XPE_OK){free(bytes);return status;}
    *out=bytes;return XPE_OK;
}
static int label_order(const void *a, const void *b) {
    const struct label *x=a,*y=b;
    if(x->rva!=y->rva)return x->rva<y->rva?-1:1;
    return x->name<y->name?-1:x->name>y->name;
}
static enum xpe_status exports(struct xpe_image *p) {
    struct directory d=p->directories[0];if(!d.rva && !d.size)return XPE_OK;
    if(!d.rva || d.size<40)return XPE_MALFORMED;
    unsigned char header[40],*eat=NULL,*names=NULL,*ordinals=NULL;
    enum xpe_status status=xpe_read_rva(p,d.rva,header,sizeof header);if(status!=XPE_OK)return status;
    uint32_t count=u32(header+20),named=u32(header+24),base=u32(header+16);
    if(count>XPE_MAX_EXPORTS || named>XPE_MAX_EXPORTS)return XPE_LIMIT;
    if((uint64_t)base+count>UINT64_C(0x100000000))return XPE_MALFORMED;
    char *module=NULL;status=string_at(p,u32(header+12),UINT64_MAX,&module);if(status!=XPE_OK)return status;
    p->info.module_name=module;p->info.export_count=count;p->info.export_name_count=named;
    if(count){size_t bytes=(size_t)count*sizeof *p->exports;if(bytes>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes)return XPE_LIMIT;p->exports=retain(p,bytes);if(!p->exports)return XPE_NOMEM;}
    if(named){size_t bytes=(size_t)named*sizeof *p->names;if(bytes>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes)return XPE_LIMIT;p->names=retain(p,bytes);if(!p->names)return XPE_NOMEM;}
    status=array(p,u32(header+28),count,4,&eat);if(status!=XPE_OK)goto done;
    status=array(p,u32(header+32),named,4,&names);if(status!=XPE_OK)goto done;
    status=array(p,u32(header+36),named,2,&ordinals);if(status!=XPE_OK)goto done;
    for(unsigned i=0;i<count;++i) {
        struct xpe_export *entry=&p->exports[i];entry->ordinal=base+i;entry->rva=u32(eat+i*4);
        if(!entry->rva)continue; /* Explicit holes do not resolve to the image base. */
        if(entry->rva>=d.rva && (uint64_t)entry->rva< (uint64_t)d.rva+d.size) {
            char *forwarder=NULL;status=string_at(p,entry->rva,(uint64_t)d.rva+d.size-entry->rva,&forwarder);
            if(status!=XPE_OK)goto done;
            entry->forwarder=forwarder;
            if(!strchr(forwarder,'.')){status=XPE_MALFORMED;goto done;}
        } else {
            if(entry->rva>=p->info.headers_size && !virtual_range(p,entry->rva,1)){status=XPE_MALFORMED;goto done;}
        }
    }
    for(unsigned i=0;i<named;++i) {
        unsigned index=u16(ordinals+i*2);if(index>=count){status=XPE_MALFORMED;goto done;}
        char *name=NULL;status=string_at(p,u32(names+i*4),UINT64_MAX,&name);if(status!=XPE_OK)goto done;
        p->names[i]=(struct xpe_export_name){name,index};
        if(!*name || (i && strcmp(p->names[i-1].name,name)>=0)){status=XPE_MALFORMED;goto done;}
        if(p->exports[index].rva && !p->exports[index].forwarder)++p->label_count;
    }
    if(p->label_count) {
        size_t bytes=(size_t)p->label_count*sizeof *p->labels;
        if(bytes>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes){status=XPE_LIMIT;goto done;}
        p->labels=retain(p,bytes);if(!p->labels){status=XPE_NOMEM;goto done;}
        for(unsigned i=0,n=0;i<named;++i) {
            const struct xpe_export *e=&p->exports[p->names[i].export_index];
            if(e->rva && !e->forwarder)p->labels[n++]=(struct label){e->rva,i};
        }
        qsort(p->labels,p->label_count,sizeof *p->labels,label_order);
    }
done:
    free(eat);free(names);free(ordinals);return status;
}
static enum xpe_status import_slot(struct xpe_image *p, struct xpe_import **out) {
    if(p->info.import_count>=XPE_MAX_IMPORTS)return XPE_LIMIT;
    /* Keep the bound a cap: grow only with actual imports. */
    unsigned count=p->info.import_count;
    if(!count || !(count&(count-1))) {
        unsigned capacity=count?count*2:1;
        size_t growth=(size_t)(capacity-count)*sizeof *p->imports;
        if(growth>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes)return XPE_LIMIT;
        struct xpe_import *next=realloc(p->imports,(size_t)capacity*sizeof *next);
        if(!next)return XPE_NOMEM;
        p->imports=next;p->info.retained_bytes+=growth;
    }
    *out=&p->imports[p->info.import_count++];**out=(struct xpe_import){0};return XPE_OK;
}
static enum xpe_status imports(struct xpe_image *p) {
    struct directory d=p->directories[1];if(!d.rva && !d.size)return XPE_OK;
    if(!d.rva || d.size<20)return XPE_MALFORMED;
    for(unsigned index=0;index<1024;++index) {
        uint64_t at=(uint64_t)index*20;
        if(!span(at,20,d.size) || (uint64_t)d.rva+at>UINT32_MAX)return XPE_MALFORMED;
        unsigned char desc[20];enum xpe_status status=xpe_read_rva(p,d.rva+(uint32_t)at,desc,sizeof desc);if(status!=XPE_OK)return status;
        unsigned nonzero=0;for(unsigned i=0;i<20;++i)nonzero|=desc[i];if(!nonzero)return XPE_OK;
        char *dll=NULL;status=string_at(p,u32(desc+12),UINT64_MAX,&dll);if(status!=XPE_OK)return status;
        p->dll_names[p->dll_count++]=dll;if(!*dll)return XPE_MALFORMED;
        uint32_t lookup=u32(desc),iat=u32(desc+16);
        if(!iat || !span(iat,8,p->info.image_size) ||
           (iat>=p->info.headers_size && !virtual_range(p,iat,8)))return XPE_MALFORMED;
        if(!lookup && (p->source.layout==XPE_MEMORY || u32(desc+4))) {
            struct xpe_import *entry;status=import_slot(p,&entry);if(status!=XPE_OK)return status;
            *entry=(struct xpe_import){.dll=dll,.iat_rva=iat,.lookup_unavailable=1};continue;
        }
        if(!lookup)lookup=iat;
        for(unsigned i=0;;++i) {
            if(i>=XPE_MAX_IMPORTS)return XPE_LIMIT;
            uint64_t table=(uint64_t)lookup+(uint64_t)i*8,slot=(uint64_t)iat+(uint64_t)i*8;
            if(table>UINT32_MAX || slot>UINT32_MAX || !span(slot,8,p->info.image_size) ||
               (slot>=p->info.headers_size && !virtual_range(p,(uint32_t)slot,8)))return XPE_MALFORMED;
            unsigned char raw[8];status=xpe_read_rva(p,(uint32_t)table,raw,sizeof raw);if(status!=XPE_OK)return status;
            uint64_t value=u64(raw);if(!value)break;
            struct xpe_import *entry;status=import_slot(p,&entry);if(status!=XPE_OK)return status;
            entry->dll=dll;entry->iat_rva=(uint32_t)slot;
            if(value>>63) {
                if(value&UINT64_C(0x7fffffffffff0000))return XPE_MALFORMED;
                entry->by_ordinal=1;entry->ordinal=(uint16_t)value;
            } else {
                if(value>0x7fffffff)return XPE_MALFORMED;
                unsigned char hint[2];status=xpe_read_rva(p,(uint32_t)value,hint,sizeof hint);if(status!=XPE_OK)return status;
                entry->hint=u16(hint);char *name=NULL;
                status=string_at(p,(uint32_t)value+2,UINT64_MAX,&name);if(status!=XPE_OK)return status;
                entry->name=name;if(!*name)return XPE_MALFORMED;
            }
        }
    }
    return XPE_LIMIT;
}
static enum xpe_status functions(struct xpe_image *p) {
    struct directory d=p->directories[3];if(!d.rva && !d.size)return XPE_OK;
    if(!d.rva || !d.size || d.size%12)return XPE_MALFORMED;
    unsigned count=d.size/12;if(count>XPE_MAX_FUNCTIONS)return XPE_LIMIT;
    unsigned char *rows=NULL;enum xpe_status status=array(p,d.rva,count,12,&rows);if(status!=XPE_OK)return status;
    /* Linkers leave empty rows behind for discarded functions. They cover
     * no address, so they are counted and left out, not fatal. */
    unsigned kept=0;
    for(unsigned i=0;i<count;++i)if(u32(rows+i*12)<u32(rows+i*12+4))++kept;
    p->info.function_skipped=count-kept;
    size_t retained=(size_t)kept*sizeof *p->functions;
    if(retained>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes){free(rows);return XPE_LIMIT;}
    if(kept){p->functions=retain(p,retained);if(!p->functions){free(rows);return XPE_NOMEM;}}
    for(unsigned i=0,n=0;i<count;++i) {
        unsigned char *r=rows+i*12;
        struct xpe_function f={u32(r),u32(r+4),u32(r+8),d.rva+i*12};
        if(f.begin>=f.end)continue;
        /* Unwind records are located and checked when they are read. */
        if(f.end>p->info.image_size || !f.unwind || f.unwind>=p->info.image_size ||
           (n && f.begin<p->functions[n-1].end)){status=XPE_MALFORMED;break;}
        const struct xpe_section *section=virtual_range(p,f.begin,(uint64_t)f.end-f.begin);
        if(!section || !(section->characteristics&0x20000000u)){status=XPE_MALFORMED;break;}
        p->functions[n++]=f;p->info.function_count=n;
    }
    free(rows);return status;
}
static enum xpe_status codeview(struct xpe_image *p) {
    struct directory d=p->directories[6];if(!d.rva && !d.size)return XPE_OK;
    if(!d.rva || !d.size || d.size%28)return XPE_MALFORMED;
    unsigned count=d.size/28;if(count>128)return XPE_LIMIT;
    for(unsigned i=0;i<count;++i) {
        unsigned char raw[28];enum xpe_status status=xpe_read_rva(p,d.rva+i*28,raw,sizeof raw);if(status!=XPE_OK)return status;
        if(u32(raw+12)!=2)continue;
        uint32_t length=u32(raw+16),rva=u32(raw+20),file=u32(raw+24);
        if(length<4)return XPE_MALFORMED;
        uint64_t offset,available;
        if(p->source.layout==XPE_FILE){offset=file;available=length;if(!span(offset,available,p->source.size))return XPE_MALFORMED;}
        else {status=locate(p,rva,&offset,&available);if(status!=XPE_OK)return status;if(length>available)return XPE_MALFORMED;}
        unsigned char id[24];status=read_at(p,offset,id,4);if(status!=XPE_OK)return status;
        if(memcmp(id,"RSDS",4)){p->info.unsupported_codeview=1;continue;}
        if(length<25)return XPE_MALFORMED;
        if(p->info.codeview_count>=16)return XPE_LIMIT;
        status=read_at(p,offset,id,sizeof id);if(status!=XPE_OK)return status;
        char path[4096];size_t n=length-24;if(n>sizeof path)n=sizeof path;
        status=read_at(p,offset+24,path,n);if(status!=XPE_OK)return status;
        char *end=memchr(path,0,n);if(!end)return length-24>sizeof path?XPE_LIMIT:XPE_MALFORMED;
        size_t bytes=(size_t)(end-path)+1;if(bytes>XPE_MAX_RETAINED_BYTES-p->info.retained_bytes)return XPE_LIMIT;
        char *saved=retain(p,bytes);if(!saved)return XPE_NOMEM;memcpy(saved,path,bytes);
        struct xpe_codeview *cv=&p->codeviews[p->info.codeview_count++];memcpy(cv->guid,id+4,16);cv->age=u32(id+20);cv->path=saved;
    }
    return XPE_OK;
}
enum xpe_status xpe_load(const struct xpe_source *source, struct xpe_image **out) {
    if(!out)return XPE_MALFORMED;
    *out=NULL;
    if(!source || !source->read || (source->layout!=XPE_FILE && source->layout!=XPE_MEMORY))return XPE_MALFORMED;
    struct xpe_image *p=calloc(1,sizeof *p);if(!p)return XPE_NOMEM;
    p->source=*source;p->info.retained_bytes=sizeof *p;
    enum xpe_status status=headers(p);
    if(status==XPE_OK)status=exports(p);
    if(status==XPE_OK)status=imports(p);
    if(status==XPE_OK)status=functions(p);
    if(status==XPE_OK)status=codeview(p);
    if(status!=XPE_OK){xpe_destroy(p);return status;}
    *out=p;return XPE_OK;
}
void xpe_destroy(struct xpe_image *p) {
    if(!p)return;
    if(p->exports)for(unsigned i=0;i<p->info.export_count;++i)free((char *)p->exports[i].forwarder);
    if(p->names)for(unsigned i=0;i<p->info.export_name_count;++i)free((char *)p->names[i].name);
    if(p->imports)for(unsigned i=0;i<p->info.import_count;++i)free((char *)p->imports[i].name);
    for(unsigned i=0;i<p->dll_count;++i)free(p->dll_names[i]);
    for(unsigned i=0;i<p->info.codeview_count;++i)free((char *)p->codeviews[i].path);
    free((char *)p->info.module_name);free(p->exports);free(p->names);free(p->labels);free(p->imports);free(p->functions);free(p);
}
const struct xpe_info *xpe_info(const struct xpe_image *p){return p?&p->info:NULL;}
const struct xpe_section *xpe_section(const struct xpe_image *p,unsigned i){return p && i<p->info.section_count?&p->sections[i]:NULL;}
const struct xpe_export *xpe_export(const struct xpe_image *p,unsigned i){return p && i<p->info.export_count?&p->exports[i]:NULL;}
const struct xpe_export_name *xpe_export_name(const struct xpe_image *p,unsigned i){return p && i<p->info.export_name_count?&p->names[i]:NULL;}
const struct xpe_import *xpe_import(const struct xpe_image *p,unsigned i){return p && i<p->info.import_count?&p->imports[i]:NULL;}
const struct xpe_function *xpe_function(const struct xpe_image *p,unsigned i){return p && i<p->info.function_count?&p->functions[i]:NULL;}
const struct xpe_codeview *xpe_codeview(const struct xpe_image *p,unsigned i){return p && i<p->info.codeview_count?&p->codeviews[i]:NULL;}
const struct xpe_export *xpe_find_export(const struct xpe_image *p,const char *name) {
    if(!p || !name)return NULL;
    unsigned lo=0,hi=p->info.export_name_count;
    while(lo<hi){unsigned mid=lo+(hi-lo)/2;int order=strcmp(p->names[mid].name,name);if(order<0)lo=mid+1;else hi=mid;}
    if(lo==p->info.export_name_count || strcmp(p->names[lo].name,name))return NULL;
    const struct xpe_export *result=&p->exports[p->names[lo].export_index];return result->rva?result:NULL;
}
const struct xpe_function *xpe_function_at(const struct xpe_image *p,uint32_t rva) {
    if(!p)return NULL;
    unsigned lo=0,hi=p->info.function_count;
    while(lo<hi){unsigned mid=lo+(hi-lo)/2;if(p->functions[mid].begin<=rva)lo=mid+1;else hi=mid;}
    return lo && rva<p->functions[lo-1].end?&p->functions[lo-1]:NULL;
}
const char *xpe_export_name_at(const struct xpe_image *p,uint32_t rva) {
    if(!p)return NULL;
    unsigned lo=0,hi=p->label_count;
    while(lo<hi){unsigned mid=lo+(hi-lo)/2;if(p->labels[mid].rva<rva)lo=mid+1;else hi=mid;}
    return lo<p->label_count && p->labels[lo].rva==rva?p->names[p->labels[lo].name].name:NULL;
}
