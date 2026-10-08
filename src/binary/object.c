#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "object.h"
#include <elf.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CHUNK 65536u
#define SECTIONS 65536u
#define SEGMENTS 4096u
#define NAMES (1024u * 1024u)
#define NOTES (1024u * 1024u)
struct xbo_object {
    struct xbo_source source;
    struct xbo_identity identity;
    int identified, ready, invalid, stage;
    enum xbo_status failure;
    unsigned wide, little, machine;
    unsigned char header[64], zero[64], record[64], build_id[64];
    size_t done, id_size;
    uint64_t phoff, shoff, note_bytes, memory, bytes_charged, read_calls;
    uint32_t phnum, shnum, names_index, index;
    struct xbo_section *sections;
    struct xbo_segment *segments;
    char *names;
    unsigned char *note;
    size_t names_size, note_size, note_at;
    uint64_t note_offset;
};
uint64_t xbo_now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return UINT64_MAX;
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
static enum xbo_status tick(struct xbo_budget *b) {
    if (!b) return XBO_LIMIT;
    if (b->cancelled && b->cancelled(b->context)) return XBO_CANCELLED;
    if (b->deadline_ns && xbo_now_ns() >= b->deadline_ns) return XBO_AGAIN;
    return XBO_OK;
}
static int same(const struct xbo_identity *a, const struct xbo_identity *b) {
    return a->device == b->device && a->inode == b->inode && a->size == b->size &&
        a->mtime_sec == b->mtime_sec && a->mtime_nsec == b->mtime_nsec &&
        a->ctime_sec == b->ctime_sec && a->ctime_nsec == b->ctime_nsec;
}
static enum xbo_status identity(struct xbo_object *o) {
    if (o->invalid) return XBO_CHANGED;
    if (o->failure) return o->failure;
    struct xbo_identity i = {0};
    enum xbo_status s = o->source.identity(o->source.context, &i);
    if (s != XBO_OK) { if (s == XBO_CHANGED) o->invalid = 1; return s; }
    if (i.size > INT64_MAX || i.mtime_nsec >= 1000000000 || i.ctime_nsec >= 1000000000) return XBO_MALFORMED;
    if (!o->identified) { o->identity = i; o->identified = 1; }
    else if (!same(&o->identity, &i)) { o->invalid = 1; return XBO_CHANGED; }
    return XBO_OK;
}
#define TRY(expr) do { enum xbo_status s_ = (expr); if (s_ != XBO_OK) return s_; } while (0)
static int range(const struct xbo_object *o, uint64_t at, uint64_t size) {
    return at <= o->identity.size && size <= o->identity.size - at;
}
enum xbo_status xbo_create(const struct xbo_source *s, struct xbo_object **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!s || !s->identity || !s->read) return XBO_MALFORMED;
    struct xbo_object *o = calloc(1, sizeof *o);
    if (!o) return XBO_NOMEM;
    o->source = *s; o->memory = sizeof *o; *out = o; return XBO_OK;
}
void xbo_destroy(struct xbo_object *o) {
    if (!o) return;
    free(o->sections); free(o->segments); free(o->names); free(o->note); free(o);
}
enum xbo_status xbo_validate(struct xbo_object *o, struct xbo_budget *b) {
    if (!o) return XBO_MALFORMED;
    TRY(tick(b)); return identity(o);
}
enum xbo_status xbo_read(struct xbo_object *o, uint64_t at, void *data, size_t n,
                         size_t *done, struct xbo_budget *b) {
    if (!o || !done || *done > n || (n && !data)) return XBO_MALFORMED;
    TRY(xbo_validate(o, b));
    if (!range(o, at, n)) return XBO_MALFORMED;
    while (*done < n) {
        TRY(tick(b));
        if (!b->reads_left || !b->bytes_left) return XBO_AGAIN;
        size_t part = n - *done;
        if (part > CHUNK) part = CHUNK;
        if (part > b->bytes_left) part = (size_t)b->bytes_left;
        TRY(identity(o));
        /* A failed callback still consumes its reserved budget. It may have
         * performed I/O before failing; only successful bytes advance done. */
        b->reads_left--; b->bytes_left -= part; b->reads++; b->bytes_read += part;
        o->bytes_charged += part; o->read_calls++;
        enum xbo_status s = o->source.read(o->source.context, at + *done, (unsigned char *)data + *done, part);
        TRY(identity(o));
        if (s == XBO_CHANGED) o->invalid = 1;
        if (s != XBO_OK) return s;
        *done += part;
    }
    return XBO_OK;
}
static uint64_t number(const struct xbo_object *o, const unsigned char *p, unsigned n) {
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i) v = v << 8 | p[o->little ? n - i - 1 : i];
    return v;
}
static uint64_t word(const struct xbo_object *o, const unsigned char *p, unsigned a, unsigned b) {
    return number(o, p + (o->wide ? a : b), o->wide ? 8 : 4);
}
static enum xbo_status header(struct xbo_object *o, struct xbo_budget *b) {
    if (o->stage == 0) {
        TRY(xbo_read(o, 0, o->header, 16, &o->done, b));
        if (memcmp(o->header, ELFMAG, SELFMAG)) return XBO_NOT_ELF;
        if ((o->header[EI_CLASS] != ELFCLASS32 && o->header[EI_CLASS] != ELFCLASS64) ||
            (o->header[EI_DATA] != ELFDATA2LSB && o->header[EI_DATA] != ELFDATA2MSB) ||
            o->header[EI_VERSION] != EV_CURRENT) return XBO_MALFORMED;
        o->wide = o->header[EI_CLASS] == ELFCLASS64; o->little = o->header[EI_DATA] == ELFDATA2LSB;
        o->stage = 1;
    }
    if (o->stage == 1) {
        TRY(xbo_read(o, 0, o->header, o->wide ? 64 : 52, &o->done, b));
        uint64_t type = number(o, o->header + 16, 2);
        if ((type != ET_EXEC && type != ET_DYN && type != ET_REL) || number(o, o->header + 20, 4) != EV_CURRENT ||
            number(o, o->header + (o->wide ? 52 : 40), 2) != (o->wide ? 64 : 52)) return XBO_MALFORMED;
        o->machine = (unsigned)number(o, o->header + 18, 2);
        o->phoff = word(o, o->header, 32, 28); o->shoff = word(o, o->header, 40, 32);
        o->phnum = (uint32_t)number(o, o->header + (o->wide ? 56 : 44), 2);
        o->shnum = (uint32_t)number(o, o->header + (o->wide ? 60 : 48), 2);
        o->names_index = (uint32_t)number(o, o->header + (o->wide ? 62 : 50), 2);
        o->done = 0; o->stage = 2;
    }
    if (o->shoff) {
        if (number(o, o->header + (o->wide ? 58 : 46), 2) != (o->wide ? 64 : 40)) return XBO_MALFORMED;
        TRY(xbo_read(o, o->shoff, o->zero, o->wide ? 64 : 40, &o->done, b));
        if (number(o, o->zero + 4, 4) != SHT_NULL) return XBO_MALFORMED;
        uint64_t count = o->shnum ? o->shnum : word(o, o->zero, 32, 20);
        if (count > SECTIONS) return XBO_LIMIT;
        o->shnum = (uint32_t)count;
        if (o->phnum == PN_XNUM) o->phnum = (uint32_t)number(o, o->zero + (o->wide ? 44 : 28), 4);
        if (o->names_index == SHN_XINDEX) o->names_index = (uint32_t)number(o, o->zero + (o->wide ? 40 : 24), 4);
        if (!o->shnum) return XBO_MALFORMED;
    } else if (o->shnum || o->names_index || o->phnum == PN_XNUM) return XBO_MALFORMED;
    if (o->phnum > SEGMENTS || o->shnum > SECTIONS) return XBO_LIMIT;
    if ((o->names_index && o->names_index >= o->shnum) ||
        (o->phnum && number(o, o->header + (o->wide ? 54 : 42), 2) != (o->wide ? 56 : 32)) ||
        !range(o, o->phoff, (uint64_t)o->phnum * (o->wide ? 56 : 32)) ||
        !range(o, o->shoff, (uint64_t)o->shnum * (o->wide ? 64 : 40))) return XBO_MALFORMED;
    o->segments = calloc(o->phnum ? o->phnum : 1, sizeof *o->segments);
    o->sections = calloc(o->shnum ? o->shnum : 1, sizeof *o->sections);
    if (!o->segments || !o->sections) return XBO_NOMEM;
    o->memory += (uint64_t)o->phnum * sizeof *o->segments + (uint64_t)o->shnum * sizeof *o->sections;
    o->index = 0; o->done = 0; o->stage = 3; return XBO_OK;
}
static enum xbo_status tables(struct xbo_object *o, struct xbo_budget *b) {
    while (o->stage == 3 && o->index < o->phnum) {
        unsigned n = o->wide ? 56 : 32;
        TRY(xbo_read(o, o->phoff + (uint64_t)o->index * n, o->record, n, &o->done, b));
        const unsigned char *p = o->record;
        struct xbo_segment *s = &o->segments[o->index];
        *s = (struct xbo_segment){.type=(uint32_t)number(o,p,4), .flags=(uint32_t)number(o,p+(o->wide?4:24),4),
            .offset=word(o,p,8,4), .address=word(o,p,16,8), .file_size=word(o,p,32,16),
            .memory_size=word(o,p,40,20), .alignment=word(o,p,48,28)};
        if (!range(o, s->offset, s->file_size) || s->memory_size > UINT64_MAX - s->address ||
            (s->type == PT_LOAD && s->file_size > s->memory_size) ||
            (s->alignment && (s->alignment & (s->alignment-1)))) return XBO_MALFORMED;
        o->index++; o->done = 0;
    }
    if (o->stage == 3) { o->stage = 4; o->index = 0; }
    while (o->index < o->shnum) {
        unsigned n = o->wide ? 64 : 40;
        TRY(xbo_read(o, o->shoff + (uint64_t)o->index * n, o->record, n, &o->done, b));
        const unsigned char *p = o->record;
        struct xbo_section *s = &o->sections[o->index];
        *s = (struct xbo_section){.name=(uint32_t)number(o,p,4), .type=(uint32_t)number(o,p+4,4),
            .flags=word(o,p,8,8), .address=word(o,p,16,12), .offset=word(o,p,24,16), .size=word(o,p,32,20),
            .link=(uint32_t)number(o,p+(o->wide?40:24),4), .info=(uint32_t)number(o,p+(o->wide?44:28),4),
            .alignment=word(o,p,48,32), .entry_size=word(o,p,56,36)};
        if (o->index && ((s->type != SHT_NOBITS && !range(o,s->offset,s->size)) ||
            s->size > UINT64_MAX-s->address || (s->alignment && (s->alignment & (s->alignment-1))))) return XBO_MALFORMED;
        o->index++; o->done = 0;
    }
    if (o->names_index) {
        const struct xbo_section *s = &o->sections[o->names_index];
        if (s->type != SHT_STRTAB || !s->size) return XBO_MALFORMED;
        if (s->size > NAMES) return XBO_LIMIT;
        o->names_size = (size_t)s->size; o->names = malloc(o->names_size);
        if (!o->names) return XBO_NOMEM;
        o->memory += o->names_size;
    }
    o->stage = 5; o->done = 0; return XBO_OK;
}
static enum xbo_status names(struct xbo_object *o, struct xbo_budget *b) {
    if (o->stage == 5) {
        if (o->names_index) {
            TRY(xbo_read(o, o->sections[o->names_index].offset, o->names, o->names_size, &o->done, b));
            if (o->names[0] || o->names[o->names_size-1]) return XBO_MALFORMED;
        }
        o->stage = 6; o->index = 0;
    }
    while (o->index < o->shnum) {
        TRY(tick(b));
        uint32_t at = o->sections[o->index].name;
        if (at && (at >= o->names_size || !memchr(o->names+at,0,o->names_size-at))) return XBO_MALFORMED;
        o->index++;
    }
    o->stage = 7; o->index = 0; o->done = 0; return XBO_OK;
}
static enum xbo_status notes(struct xbo_object *o, struct xbo_budget *b) {
    /* Both tables are checked: conflicting build IDs are never first-wins. */
    while (o->index < o->phnum + o->shnum) {
        TRY(tick(b));
        uint64_t at, n;
        if (o->index < o->phnum) {
            const struct xbo_segment *s=&o->segments[o->index];
            if (s->type != PT_NOTE) { o->index++; continue; }
            at=s->offset; n=s->file_size;
        } else {
            const struct xbo_section *s=&o->sections[o->index-o->phnum];
            if (s->type != SHT_NOTE) { o->index++; continue; }
            at=s->offset; n=s->size;
        }
        if (!o->note) {
            if (n > NOTES - o->note_bytes) return XBO_LIMIT;
            if (!n) { o->index++; continue; }
            o->note = malloc((size_t)n);
            if (!o->note) return XBO_NOMEM;
            o->note_size=(size_t)n; o->note_offset=at; o->note_bytes+=n;
            o->memory+=n; o->note_at=0;
        }
        TRY(xbo_read(o,o->note_offset,o->note,o->note_size,&o->done,b));
        while (o->note_at < o->note_size) {
            TRY(tick(b));
            size_t pos=o->note_at;
            if (o->note_size-pos < 12) return XBO_MALFORMED;
            uint64_t name=number(o,o->note+pos,4), desc=number(o,o->note+pos+4,4), type=number(o,o->note+pos+8,4);
            uint64_t names=(name+3)&~UINT64_C(3), descs=(desc+3)&~UINT64_C(3);
            if (names+descs > o->note_size-pos-12) return XBO_MALFORMED;
            if (type==NT_GNU_BUILD_ID && name==4 && !memcmp(o->note+pos+12,"GNU",4)) {
                if (!desc || desc>sizeof o->build_id) return XBO_MALFORMED;
                const unsigned char *id=o->note+pos+12+names;
                if (o->id_size && (o->id_size!=desc || memcmp(o->build_id,id,(size_t)desc))) return XBO_MALFORMED;
                memcpy(o->build_id,id,(size_t)desc);o->id_size=(size_t)desc;
            }
            o->note_at += (size_t)(12+names+descs);
        }
        free(o->note);o->note=NULL;o->memory-=o->note_size;o->note_size=0;o->done=0;o->index++;
    }
    TRY(xbo_validate(o,b));o->stage=8;o->ready=1;return XBO_OK;
}
static enum xbo_status prepare(struct xbo_object *o, struct xbo_budget *b) {
    if (!o) return XBO_MALFORMED;
    TRY(xbo_validate(o,b));
    if (o->ready) return XBO_OK;
    if (o->stage<=2) TRY(header(o,b));
    if (o->stage<=4) TRY(tables(o,b));
    if (o->stage<=6) TRY(names(o,b));
    return notes(o,b);
}
enum xbo_status xbo_prepare(struct xbo_object *o, struct xbo_budget *b) {
    enum xbo_status s = prepare(o, b);
    if (o && s != XBO_OK && s != XBO_AGAIN && s != XBO_CANCELLED) o->failure = s;
    return s;
}
#define READY(o) ((o) && (o)->ready && !(o)->invalid && !(o)->failure)
const struct xbo_identity *xbo_identity(const struct xbo_object *o) {return READY(o)?&o->identity:NULL;}
uint32_t xbo_section_count(const struct xbo_object *o) {return READY(o)?o->shnum:0;}
uint32_t xbo_segment_count(const struct xbo_object *o) {return READY(o)?o->phnum:0;}
const struct xbo_section *xbo_section(const struct xbo_object *o,uint32_t i) {return READY(o)&&i<o->shnum?o->sections+i:NULL;}
const struct xbo_segment *xbo_segment(const struct xbo_object *o,uint32_t i) {return READY(o)&&i<o->phnum?o->segments+i:NULL;}
const char *xbo_section_name(const struct xbo_object *o,uint32_t i) {
    const struct xbo_section *s=xbo_section(o,i);return s?(s->name?o->names+s->name:""):NULL;
}
enum xbo_status xbo_find_section(const struct xbo_object *o,const char *name,uint32_t *out) {
    if (!READY(o)||!name||!out) return XBO_MALFORMED;
    int found=0;
    for (uint32_t i=1;i<o->shnum;i++) if (!strcmp(xbo_section_name(o,i),name)) {
        if (found) return XBO_MALFORMED;
        found=1;*out=i;
    }
    return found?XBO_OK:XBO_NOT_FOUND;
}
const unsigned char *xbo_build_id(const struct xbo_object *o,size_t *n) {
    if (n) *n=READY(o)?o->id_size:0;
    return READY(o)&&o->id_size?o->build_id:NULL;
}
unsigned xbo_address_size(const struct xbo_object *o) {return READY(o)?(o->wide?8:4):0;}
unsigned xbo_little_endian(const struct xbo_object *o) {return READY(o)?o->little:0;}
unsigned xbo_machine(const struct xbo_object *o) {return READY(o)?o->machine:0;}
uint64_t xbo_memory_bytes(const struct xbo_object *o) {return o?o->memory:0;}
void xbo_progress(const struct xbo_object *o, struct xbo_progress *p) {
    if (!p) return;
    memset(p,0,sizeof *p);
    if (!o) return;
    *p=(struct xbo_progress){.source_size=o->identified?o->identity.size:0,
        .bytes_charged=o->bytes_charged,.read_calls=o->read_calls,.memory_bytes=o->memory,
        .phase=(unsigned)o->stage,.cursor=o->index,.sections=o->shnum,.segments=o->phnum,
        .ready=READY(o),.changed=o->invalid};
}
const char *xbo_status_name(enum xbo_status s) {
    static const char *const names[]={"ok","pending","cancelled","changed","io","not-elf","malformed","limit","out-of-memory","not-found"};
    return (unsigned)s<sizeof names/sizeof *names?names[s]:"unknown";
}
static enum xbo_status local_identity(void *ctx,struct xbo_identity *out) {
    struct stat st;
    if (fstat(((struct xbo_local *)ctx)->fd,&st)) return XBO_IO;
    if (!S_ISREG(st.st_mode)||st.st_size<0) return XBO_IO;
    *out=(struct xbo_identity){.device=(uint64_t)st.st_dev,.inode=(uint64_t)st.st_ino,.size=(uint64_t)st.st_size,
        .mtime_sec=st.st_mtim.tv_sec,.mtime_nsec=(uint32_t)st.st_mtim.tv_nsec,
        .ctime_sec=st.st_ctim.tv_sec,.ctime_nsec=(uint32_t)st.st_ctim.tv_nsec};return XBO_OK;
}
static enum xbo_status local_read(void *ctx,uint64_t at,void *out,size_t n) {
    ssize_t got;
    do {got=pread(((struct xbo_local *)ctx)->fd,out,n,(off_t)at);} while(got<0&&errno==EINTR);
    return got==(ssize_t)n?XBO_OK:XBO_IO;
}
struct xbo_source xbo_local_source(struct xbo_local *local) {
    return (struct xbo_source){.context=local,.identity=local_identity,.read=local_read};
}
