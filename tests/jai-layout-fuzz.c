/* Periodic lane: mutate only a synthetic self-describing image. */
#define main xjai_fixture_check_main
#include "jai-layout.c"
#undef main
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    struct xjai_region region;origin=UINT64_C(0x20000000002000);
    struct xjai_image image=fixture(size && (data[0]&1)?8:0,&region);
    for (size_t i=1;i+2<size;i+=3) {
        size_t offset=((size_t)data[i]<<8 | data[i+1])%region.size;
        arena[offset]^=data[i+2];
    }
    if (size>1 && data[1]&1) region.size=1+(region.size*data[0])/256;
    if (size>3 && (data[2]&3)==3) region.address=UINT64_MAX-region.size;
    struct xjai_layout layout;const char *why=xjai_layout_detect(&image,&layout);
    if (why) {
        const unsigned char *p=(const unsigned char *)&layout;
        for (size_t i=0;i<sizeof layout;++i) CHECK(p[i]==0);
    } else {
        CHECK(layout.profile==XJAI_PROFILE && layout.struct_size<=512 && layout.member_size<=256);
        CHECK(layout.so[XJAI_S_MEMBERS]<=layout.struct_size-16);
    }
    return 0;
}
