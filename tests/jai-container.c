/* Fast lane: synthetic RTTI plus independently compiled sizeof/offsetof/value truth. */
#define JAI_VALUE_NO_MAIN
#include "jai-value.c"
#include <time.h>
struct bucket_value { int64_t count;unsigned char occupied[4];uint32_t padding;struct typed_child data[4]; };
struct dynamic_value { int64_t count;uint64_t data;int64_t allocated;uint64_t allocator[2]; };
static uint64_t bucket_type,bucket_members,dynamic_type,occupancy_type,storage_type,offset_type,table_type;
struct offset_value {int64_t score;uint64_t rtti;};
static struct xjai_image container_fixture(struct xjai_region *region)
{
    struct xjai_image im=value_fixture(region);
    uint64_t boolean=type(2,1,16),s64=type(0,8,24);put(s64+16,1,1);
    occupancy_type=type(8,4,40);put(occupancy_type+16,boolean,8);put(occupancy_type+24,0,2);put(occupancy_type+32,4,8);
    storage_type=type(8,sizeof(((struct bucket_value *)0)->data),40);put(storage_type+16,typed_child_type,8);put(storage_type+24,0,2);put(storage_type+32,4,8);
    bucket_type=make_struct("Bucket",sizeof(struct bucket_value),3,&bucket_members);
    field(bucket_members,0,"data",storage_type,offsetof(struct bucket_value,data),0);
    field(bucket_members,1,"count",s64,offsetof(struct bucket_value,count),0);
    field(bucket_members,2,"occupied",occupancy_type,offsetof(struct bucket_value,occupied),0);
    dynamic_type=type(8,sizeof(struct dynamic_value),40);put(dynamic_type+16,s64,8);put(dynamic_type+24,2,2);put(dynamic_type+32,UINT64_MAX,8);
    uint64_t fields,root=make_struct("FixtureContainerRoot",sizeof(struct dynamic_value),1,&fields);(void)root;
    field(fields,0,"items",dynamic_type,0,0);
    uint64_t meta=type(13,8,16);offset_type=make_struct("FixtureOffsetSelf",sizeof(struct offset_value),2,&fields);
    field(fields,0,"score",s64,offsetof(struct offset_value,score),0);
    field(fields,1,"entity_type",meta,offsetof(struct offset_value,rtti),0);
    table_type=make_struct("Table",8,1,&fields);field(fields,0,"count",s64,0,0);
    region->size=used;return im;
}
static void reason(const char *got,const char *want) {if (!got || strcmp(got,want)) fprintf(stderr,"expected %s, got %s\n",want,got?got:"success");CHECK(got && !strcmp(got,want));}
int xjai_container_fixture_main(int argc,char **argv)
{
    struct xjai_region region;struct xjai_image im=container_fixture(&region);struct xjai_graph *g;build_graph(&im,&g);
    struct bucket_value bucket={.count=2,.occupied={0,1,0,1}};
    bucket.data[1]=(struct typed_child){{typed_child_type},22};bucket.data[3]=(struct typed_child){{typed_child_type},44};
    pid_t pid=getpid();struct xjai_live_reader reader={.context=&pid,.read=memory};
    uint32_t ti=xjai_type_at(g,bucket_type);CHECK(ti!=XJAI_NONE && !g->types[ti].reason);
    struct xjai_container_row rows[4];struct xjai_container_page page;
    unsigned long rss_before=current_rss();struct timespec begin,end;CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&begin));
    CHECK(!xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,4,&reader,&page));
    CHECK(page.total_count==2 && page.capacity==4 && page.count==2 && !page.truncated);
    CHECK(rows[0].address==(uintptr_t)&bucket.data[1] && rows[0].slot==1 && rows[1].address==(uintptr_t)&bucket.data[3] && rows[1].slot==3);
    struct xjai_values *values;CHECK(!xjai_value_read(g,rows[0].type,rows[0].address,NULL,&reader,&values));
    CHECK(!values->partial && values->rows[3].bits==(uint64_t)(argc>1 && !strcmp(argv[1],"--wrong-oracle")?23:22));xjai_values_free(values);
    CHECK(!xjai_container_read(g,ti,(uintptr_t)&bucket,1,rows,1,&reader,&page) && page.count==1 && page.truncated && rows[0].slot==3);
    CHECK(!xjai_container_read(g,ti,(uintptr_t)&bucket,2,rows,1,&reader,&page) && !page.count);
    reason(xjai_container_read(g,ti,(uintptr_t)&bucket,3,rows,1,&reader,&page),"JaiValuePageOutOfRange");CHECK(!page.count && !page.total_count);
    /* Corrupt a flag outside the requested page: validate before any result. */
    bucket.occupied[3]=2;reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketOccupancyInvalid");CHECK(!page.count);
    bucket.occupied[3]=1;bucket.count=3;reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketCountMismatch");CHECK(!page.total_count);
    bucket.count=-1;reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketCountMismatch");bucket.count=2;
    reader.reads=512;reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiValueReadBudget");reader.reads=reader.bytes=0;
    reason(xjai_container_read(g,ti,1,0,rows,1,&reader,&page),"JaiValueUnreadable");CHECK(!page.count);
    reason(xjai_container_read(g,ti,UINT64_MAX-8,0,rows,1,&reader,&page),"JaiValueAddressInvalid");
    struct xjai_member *members=&g->members[g->types[ti].first_member];uint64_t off=members[0].offset;
    members[0].offset=members[2].offset;reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketLayoutUnproved");members[0].offset=off;
    uint32_t old_name=members[1].name;members[1].name=members[0].name;
    reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketLayoutUnproved");members[1].name=old_name;
    struct xjai_type *occupancy=&g->types[xjai_type_at(g,occupancy_type)],*storage=&g->types[xjai_type_at(g,storage_type)];
    uint64_t bucket_size=g->types[ti].size,storage_size=storage->size;
    g->types[ti].size=UINT64_C(1000000);occupancy->array_count=occupancy->size=XJAI_BUCKET_SLOTS+1;
    storage->array_count=XJAI_BUCKET_SLOTS+1;storage->size=storage->array_count*sizeof(struct typed_child);
    members[0].offset=XJAI_BUCKET_SLOTS+32;
    reason(xjai_container_read(g,ti,(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiBucketSlotLimit");
    g->types[ti].size=bucket_size;occupancy->array_count=occupancy->size=4;storage->array_count=4;storage->size=storage_size;members[0].offset=off;
    reason(xjai_container_read(g,xjai_type_at(g,table_type),(uintptr_t)&bucket,0,rows,1,&reader,&page),"JaiTableOccupancyUnproved");
    uint64_t bits[]={10,20,30,40,50,60};struct dynamic_value dynamic={3,(uintptr_t)bits,6,{UINT64_MAX,UINT64_MAX}};
    uint32_t di=xjai_type_at(g,dynamic_type);CHECK(di!=XJAI_NONE);reader.reads=reader.bytes=0;
    CHECK(!xjai_container_read(g,di,(uintptr_t)&dynamic,1,rows,1,&reader,&page));
    CHECK(page.total_count==3 && page.capacity==6 && page.count==1 && page.truncated && rows[0].address==(uintptr_t)&bits[1]);
    CHECK(!xjai_value_read(g,di,(uintptr_t)&dynamic,NULL,&reader,&values));CHECK(!values->partial && values->count==4 && values->rows[3].bits==30);xjai_values_free(values);
    dynamic.allocated=2;reason(xjai_container_read(g,di,(uintptr_t)&dynamic,0,rows,1,&reader,&page),"JaiArrayHeaderInvalid");CHECK(!page.count);
    dynamic.allocated=-1;reason(xjai_container_read(g,di,(uintptr_t)&dynamic,0,rows,1,&reader,&page),"JaiArrayHeaderInvalid");
    dynamic.allocated=6;dynamic.data=UINT64_MAX-8;reason(xjai_container_read(g,di,(uintptr_t)&dynamic,0,rows,1,&reader,&page),"JaiArrayHeaderInvalid");
    dynamic.count=dynamic.allocated=0;dynamic.data=0;CHECK(!xjai_container_read(g,di,(uintptr_t)&dynamic,0,rows,1,&reader,&page) && !page.count && !page.total_count);
    uint64_t old_size=g->types[di].size;g->types[di].size=48;
    reason(xjai_container_read(g,di,(uintptr_t)&dynamic,0,rows,1,&reader,&page),"JaiArrayHeaderUnproved");g->types[di].size=old_size;
    uint32_t bt=xjai_type_at(g,typed_base_type),actual;uint64_t at;
    CHECK(!xjai_instance_candidate(g,bt,g->types[bt].first_member,(uintptr_t)&bucket.data[3].base.rtti,&reader,&at,&actual));
    CHECK(at==(uintptr_t)&bucket.data[3] && actual==xjai_type_at(g,typed_child_type));
    bucket.data[3].base.rtti=base_type;
    reason(xjai_instance_candidate(g,bt,g->types[bt].first_member,(uintptr_t)&bucket.data[3].base.rtti,&reader,&at,&actual),"JaiDynamicTypeIncompatible");CHECK(!at && actual==XJAI_NONE);
    bucket.data[3].base.rtti=UINT64_MAX;
    reason(xjai_instance_candidate(g,bt,g->types[bt].first_member,(uintptr_t)&bucket.data[3].base.rtti,&reader,&at,&actual),"JaiTypePointerUnknown");
    reason(xjai_instance_candidate(g,bt,g->types[bt].first_member,0,&reader,&at,&actual),"JaiCandidateAddressInvalid");
    struct offset_value offset={17,offset_type};uint32_t ot=xjai_type_at(g,offset_type);
    CHECK(!xjai_instance_candidate(g,ot,g->types[ot].first_member+1,(uintptr_t)&offset.rtti,&reader,&at,&actual));
    CHECK(at==(uintptr_t)&offset && actual==ot);
    reason(xjai_instance_candidate(g,ot,g->types[ot].first_member+1,4,&reader,&at,&actual),"JaiCandidateAddressInvalid");
    CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end));
    printf("{\"cpu_ns\":%llu,\"rss_before\":%lu,\"rss_after\":%lu,\"bucket_slots\":4,\"occupied\":2,\"heap_bytes\":0}\n",(unsigned long long)((end.tv_sec-begin.tv_sec)*1000000000LL+end.tv_nsec-begin.tv_nsec),rss_before,current_rss());
    /* Count inspected members too, not just recursive type visits. */
    struct xjai_type wide_types[3]={{.address=0x100,.tag=7,.size=8,.first_member=0,.member_count=1},
        {.address=0x200,.tag=7,.size=8,.first_member=0,.member_count=4096},{.address=0x300,.tag=13,.size=8}};
    struct xjai_member *wide_members=calloc(4096,sizeof *wide_members);CHECK(wide_members);
    for (unsigned i=0;i<4096;++i) wide_members[i].type=2;
    struct xjai_graph wide={.layout=g->layout,.types=wide_types,.members=wide_members,.type_count=3,.member_count=4096};
    uint64_t wide_pointer=0x200;reader.reads=reader.bytes=0;
    reason(xjai_self_type(&wide,0,(uintptr_t)&wide_pointer,0,&reader,&actual),"JaiDynamicTypeTraversalLimit");CHECK(actual==XJAI_NONE);
    wide_types[1].member_count=4095;
    reason(xjai_self_type(&wide,0,(uintptr_t)&wide_pointer,0,&reader,&actual),"JaiDynamicTypeIncompatible");free(wide_members);
    xjai_graph_free(g);puts("Jai containers: RTTI offsets, occupied slots/count, array capacity/pages and candidate checks PASS");return 0;
}

#ifndef JAI_CONTAINER_NO_MAIN
int main(int argc,char **argv) {return xjai_container_fixture_main(argc,argv);}
#endif
