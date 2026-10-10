/* Fast lane: synthetic types and sizeof/offsetof truth, with planted negatives. */
#define JAI_FIXTURE_BYTES (1024*1024)
#define main xjai_layout_fixture_main
#include "jai-layout.c"
#undef main
struct base_value { int64_t score; };
struct object_value { struct base_value base;double energy;uint64_t next;int32_t fixed[3]; };
static uint64_t object_type,base_type,object_fields,base_fields,enum_type,array_kind_values;
static uint64_t make_struct(const char *label,size_t bytes_size,unsigned count,uint64_t *fields_out)
{
    uint64_t t=type(7,(unsigned)bytes_size,160);name(t+16,label);put(t+108,bytes_size%8==0?8:bytes_size%4==0?4:1,4);*fields_out=alloc(count*member_stride);span(t+64,count,*fields_out);return t;
}
static struct xjai_image graph_fixture(struct xjai_region *region)
{
    struct xjai_image im=fixture(0,region);
    put(self+108,UINT32_MAX,4);put(member+108,UINT32_MAX,4);put(header+108,UINT32_MAX,4);
    uint64_t u32=type(0,2,24),s32=type(0,4,24),s64=type(0,8,24),f64=type(1,8,16);put(s32+16,1,1);put(s64+16,1,1);
    static const char *const kinds[]={"FIXED","VIEW","RESIZABLE"};uint64_t kind_values[]={0,1,2};
    uint64_t array_enum_type=enumeration("Array_Type",kinds,kind_values,3,u32,&array_kind_values);put(array_enum_type+8,2,8);
    base_type=make_struct("FixtureBase",sizeof(struct base_value),1,&base_fields);
    field(base_fields,0,"score",s64,offsetof(struct base_value,score),0);
    object_type=make_struct("FixtureObject",sizeof(struct object_value),4,&object_fields);
    uint64_t pointer=type(4,8,24);put(pointer+16,object_type,8);
    uint64_t fixed=type(8,12,40);put(fixed+16,s32,8);put(fixed+24,0,4);put(fixed+32,3,8);
    field(object_fields,0,"base",base_type,offsetof(struct object_value,base),20);
    field(object_fields,1,"energy",f64,offsetof(struct object_value,energy),0);
    field(object_fields,2,"next",pointer,offsetof(struct object_value,next),0);
    field(object_fields,3,"items",fixed,offsetof(struct object_value,fixed),0);
    const char *const es[]={"NEGATIVE","READY"};uint64_t ev[]={UINT64_MAX-2,7},ignored;enum_type=enumeration("FixtureState",es,ev,2,s32,&ignored);
    uint64_t poly_fields,poly=make_struct("FixtureBox(s32)",4,1,&poly_fields);field(poly_fields,0,"item",s32,0,0);put(poly+112,base_type,8);
    uint64_t constant=alloc(8),parameters=alloc(member_stride);put(constant,123,8);span(poly+128,8,constant);
    field(parameters,0,"Capacity",s64,UINT64_MAX,1);put(parameters+56,0,8);span(poly+48,1,parameters);
    /* Reach view/resizable metadata through ordinary fields. */
    uint64_t views,container=make_struct("FixtureViews",56,2,&views),view=type(8,16,40),resizable=type(8,40,40);
    put(view+16,s32,8);put(view+24,1,4);put(view+32,UINT64_MAX,8);
    put(resizable+16,s32,8);put(resizable+24,2,4);put(resizable+32,UINT64_MAX,8);
    field(views,0,"view",view,0,0);field(views,1,"dynamic",resizable,16,0);(void)container;
    /* A pooled-name row can resemble a struct header and members span.
     * Its bogus member flags must prevent it becoming a recognized root. */
    uint64_t decoy=type(7,40,160),fake_members=alloc(member_stride);name(decoy+16,"FixtureDecoy");
    put(decoy+108,8,4);span(decoy+64,1,fake_members);field(fake_members,0,"noise",s32,0,0xdeadbeef);
    region->size=used;return im;
}
static uint32_t find(const struct xjai_graph *g,const char *name)
{
    for (uint32_t i=0;i<g->type_count;++i) if (!strcmp(g->text+g->types[i].name,name)) return i;
    return XJAI_NONE;
}
static void build_graph(struct xjai_image *im,struct xjai_graph **g)
{
    const char *why=xjai_graph_build(im,NULL,g);if (why) fprintf(stderr,"graph: %s\n",why);CHECK(!why && *g);
}
int xjai_reader_fixture_main(int argc,char **argv)
{
    struct xjai_region region;struct xjai_image im=graph_fixture(&region);struct xjai_graph *g;build_graph(&im,&g);
    CHECK(find(g,"FixtureDecoy")==XJAI_NONE && g->rejected_candidates>0);
    uint32_t object=xjai_type_at(g,object_type),base=xjai_type_at(g,base_type),en=xjai_type_at(g,enum_type);CHECK(object!=XJAI_NONE && base!=XJAI_NONE && en!=XJAI_NONE);
    const struct xjai_type *o=&g->types[object];CHECK(!o->reason && o->size==sizeof(struct object_value) && o->member_count==4);
    const struct xjai_member *m=&g->members[o->first_member];CHECK(m[0].type==base && m[1].offset==offsetof(struct object_value,energy));
    const struct xjai_type *pointer=&g->types[m[2].type],*ar=&g->types[m[3].type];CHECK(!pointer->reason && pointer->element==object);
    CHECK(!ar->reason && ar->array_kind==0 && ar->array_count==3 && ar->size==sizeof(((struct object_value *)0)->fixed));
    CHECK(g->types[ar->element].is_signed && g->types[ar->element].size==4);
    struct xjai_flat_field flat[8];size_t count=0;CHECK(!xjai_fields_flatten(g,object,flat,8,&count));
    CHECK(count==(argc>1 && !strcmp(argv[1],"--wrong-oracle")?5u:4u));
    CHECK(flat[0].offset==offsetof(struct object_value,base)+offsetof(struct base_value,score) && flat[0].depth==2);
    CHECK(flat[1].offset==offsetof(struct object_value,energy));CHECK(!strcmp(g->text+g->members[flat[0].member].name,"score"));
    CHECK(!strcmp(xjai_fields_flatten(g,object,flat,1,&count),"JaiFieldLimit") && count==1);
    const struct xjai_type *e=&g->types[en];CHECK(!e->reason && e->is_signed && e->enum_count==2);
    CHECK(g->enums[e->first_enum].bits==UINT64_MAX-2 && g->enums[e->first_enum+1].bits==7);
    uint32_t poly=find(g,"FixtureBox(s32)");CHECK(poly!=XJAI_NONE && !g->types[poly].reason && g->types[poly].parameter_count==1);
    const struct xjai_member *parameter=&g->members[g->types[poly].first_parameter];CHECK(!parameter->reason && parameter->constant_address && parameter->offset==UINT64_MAX);
    uint32_t container=find(g,"FixtureViews");CHECK(container!=XJAI_NONE);m=&g->members[g->types[container].first_member];
    CHECK(!g->types[m[0].type].reason && g->types[m[0].type].array_kind==1 && !g->types[m[1].type].reason && g->types[m[1].type].array_kind==2);
    printf("{\"types\":%u,\"members\":%u,\"enums\":%u,\"retained_bytes\":%llu,\"object_size\":%zu,\"energy_offset\":%zu,\"partial\":%d}\n",g->type_count,g->member_count,g->enum_count,(unsigned long long)g->allocated_bytes,sizeof(struct object_value),offsetof(struct object_value,energy),g->partial);
    xjai_graph_free(g);
    im=graph_fixture(&region);put(object_fields+member_stride+24,UINT64_MAX,8);build_graph(&im,&g);object=xjai_type_at(g,object_type);o=&g->types[object];
    CHECK(g->partial && !strcmp(g->members[o->first_member+1].reason,"JaiMemberOutsideStruct"));CHECK(!g->members[o->first_member].reason);xjai_graph_free(g);
    im=graph_fixture(&region);put(base_fields+16,base_type,8);put(base_fields+32,4,4);build_graph(&im,&g);base=xjai_type_at(g,base_type);
    CHECK(!strcmp(xjai_fields_flatten(g,base,flat,8,&count),"JaiUsingCycle"));xjai_graph_free(g);
    im=graph_fixture(&region);put(array_kind_values+8,9,8);build_graph(&im,&g);object=xjai_type_at(g,object_type);ar=&g->types[g->members[g->types[object].first_member+3].type];
    CHECK(!strcmp(ar->reason,"JaiArrayKindUnproved"));xjai_graph_free(g);
    im=graph_fixture(&region);struct xjai_limits lim={4,10,4,128};CHECK(!xjai_graph_build(&im,&lim,&g) && g->partial && g->type_count<=4 && g->member_count<=10 && g->enum_count<=4 && g->text_bytes<=128);xjai_graph_free(g);
    im=graph_fixture(&region);put(object_fields+16,UINT64_MAX-7,8);build_graph(&im,&g);object=xjai_type_at(g,object_type);CHECK(g->members[g->types[object].first_member].reason);xjai_graph_free(g);
    im=graph_fixture(&region);uint64_t addresses[300];
    for (unsigned i=0;i<300;++i) {
        uint64_t fields_at;addresses[i]=make_struct("FixtureRepeatedName",8,1,&fields_at);
        field(fields_at,0,"nested",base_type,0,0);
    }
    region.size=used;build_graph(&im,&g);
    for (unsigned i=0;i<300;++i) {
        uint32_t index=xjai_type_at(g,addresses[i]);CHECK(index!=XJAI_NONE);
        CHECK(!g->types[index].reason && g->types[index].member_count==1 && g->members[g->types[index].first_member].type==xjai_type_at(g,base_type));
    }
    CHECK(g->type_capacity>=300 && g->member_capacity>=300 && g->text_capacity>=4096);xjai_graph_free(g);
    puts("Jai graph: recursive pointers, types, enums, arrays, using, constants, partial corruption and caps PASS");return 0;
}

#ifndef JAI_READER_NO_MAIN
int main(int argc,char **argv) {return xjai_reader_fixture_main(argc,argv);}
#endif
