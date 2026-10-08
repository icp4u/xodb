#define _GNU_SOURCE 1
#include "../src/debug/dwarf_cursor.h"
#include <assert.h>
#include <dwarf.h>
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct oracle {
    Dwarf *dwarf;
    Dwarf_Die die,parents[128];
    unsigned depth;
    Dwarf_Off unit,next;
    int available,selected;
};
static void next_unit(struct oracle *o) {
    if(o->selected&&o->available){o->available=0;return;}
    size_t header=0;int rc=dwarf_nextcu(o->dwarf,o->next,&o->next,&header,NULL,NULL,NULL);
    assert(rc>=0);o->available=!rc;o->depth=0;
    if(!rc)assert(dwarf_offdie(o->dwarf,o->unit+header,&o->die));
    o->unit=o->next;
}
static void advance(struct oracle *o,int descend) {
    Dwarf_Die next;int rc=descend?dwarf_child(&o->die,&next):1;assert(rc>=0);
    if(!rc){assert(o->depth<128);o->parents[o->depth++]=o->die;o->die=next;return;}
    for(;;) {
        if(!o->depth){next_unit(o);return;}
        rc=dwarf_siblingof(&o->die,&next);assert(rc>=0);
        if(!rc){o->die=next;return;}
        o->die=o->parents[--o->depth];
    }
}
struct test {struct xdw_cursor *cursor;struct xbo_budget *budget;struct oracle oracle;uint64_t count;int skip,raw;};
static enum xbo_status visit(void *context,const struct xdw_die *d,enum xdw_action *action) {
    struct test *t=context;
    if(t->raw){t->count++;*action=XDW_DESCEND;return XBO_OK;}
    assert(t->oracle.available);Dwarf_Die *expected=&t->oracle.die;
    assert(d->offset==dwarf_dieoffset(expected));assert(d->tag==(unsigned)dwarf_tag(expected));assert(d->depth==t->oracle.depth);
    Dwarf_Attribute name_attr;
    const char *want=dwarf_attr(expected,DW_AT_name,&name_attr)?dwarf_formstring(&name_attr):NULL;char name[65536];
    enum xbo_status s=xdw_name(t->cursor,d,name,sizeof name,t->budget);
    if(s==XBO_AGAIN||s==XBO_CANCELLED)return s;
    if(!(want?(s==XBO_OK&&!strcmp(want,name)):(s==XBO_NOT_FOUND))) {fprintf(stderr,"name at %llx tag %x: want=[%s] actual=[%s] status=%s why=%s attr=%p\n",(unsigned long long)d->offset,d->tag,want?want:"NULL",s==XBO_OK?name:"NULL",xbo_status_name(s),xdw_error(t->cursor),(void*)xdw_attribute(d,DW_AT_name));abort();}
    const unsigned attrs[]={DW_AT_const_value,DW_AT_byte_size,DW_AT_data_member_location};
    for(unsigned i=0;i<sizeof attrs/sizeof *attrs;i++) {
        const struct xdw_attribute *a=xdw_attribute(d,attrs[i]);Dwarf_Attribute ref;Dwarf_Word val;
        if(a&&dwarf_attr(expected,attrs[i],&ref)&&!dwarf_formudata(&ref,&val))assert(a->value==val);
    }
    t->count++;*action=t->skip && d->children && d->depth && t->count%5==0?XDW_SKIP_CHILDREN:
        t->count%11==0?XDW_STOP:XDW_DESCEND;
    advance(&t->oracle,*action!=XDW_SKIP_CHILDREN);return XBO_OK;
}
int main(int argc,char **argv) {
    assert(argc==2||argc==3);int fd=open(argv[1],O_RDONLY|O_CLOEXEC|O_NONBLOCK);assert(fd>=0);
    struct xbo_local local={fd};struct xbo_source source=xbo_local_source(&local);struct xbo_object *object;
    assert(xbo_create(&source,&object)==XBO_OK);
    struct xbo_budget budget={.bytes_left=1048576,.reads_left=65536};assert(xbo_prepare(object,&budget)==XBO_OK);
    struct xdw_cursor *cursor;assert(xdw_create(object,&cursor)==XBO_OK);
    struct test t={.skip=argc==3&&!strcmp(argv[2],"skip"),.raw=argc==3&&!strcmp(argv[2],"raw"),.cursor=cursor};
    if(!t.raw){
        t.oracle.dwarf=dwarf_begin(fd,DWARF_C_READ);assert(t.oracle.dwarf);
        if(argc==3&&!strcmp(argv[2],"unit")) {
            Dwarf_Off second;size_t header;
            assert(!dwarf_nextcu(t.oracle.dwarf,0,&second,&header,NULL,NULL,NULL));
            assert(xdw_select_unit(cursor,second)==XBO_OK);
            t.oracle.unit=second;t.oracle.next=second;t.oracle.selected=1;
        }
        next_unit(&t.oracle);
    }
    uint64_t slices=0,bytes=0;
    for(;;) {
        budget=(struct xbo_budget){.bytes_left=97,.reads_left=5,.deadline_ns=xbo_now_ns()+UINT64_C(100000000)};t.budget=&budget;
        enum xbo_status s=xdw_walk(cursor,&budget,7,visit,&t);bytes+=budget.bytes_read;slices++;
        if(s!=XBO_OK&&s!=XBO_AGAIN){fprintf(stderr,"refused %s: %s\n",xbo_status_name(s),xdw_error(cursor));xdw_destroy(cursor);xbo_destroy(object);close(fd);return 2;}
        struct xdw_progress p;xdw_progress(cursor,&p);
        assert(slices<1000000);if(p.complete){assert(t.raw||!t.oracle.available);printf("pass: %"PRIu64" units, %"PRIu64" exact DIE/name/attribute positions, %"PRIu64" slices, %"PRIu64" bytes, %"PRIu64" memory\n",p.units,t.count,slices,bytes,p.memory_bytes);break;}
    }
    if(t.oracle.dwarf)dwarf_end(t.oracle.dwarf);
    xdw_destroy(cursor);xbo_destroy(object);close(fd);return 0;
}
