#ifndef XODB_CACHE_IO_H
#define XODB_CACHE_IO_H
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <nmmintrin.h>
#include <cpuid.h>
#endif
static inline void xc_put(unsigned char *p,uint64_t v,unsigned n) {for(unsigned i=0;i<n;i++){p[i]=(unsigned char)v;v>>=8;}}
static inline uint64_t xc_get(const unsigned char *p,unsigned n) {uint64_t v=0;for(unsigned i=0;i<n;i++)v|=(uint64_t)p[i]<<(8*i);return v;}
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
/* Query CPUID directly: compiler CPU-dispatch builtins can require a GCC
 * runtime global which is absent when these objects are linked by Zig. */
static inline int xc_has_sse42(void) {
    static unsigned cached;
    unsigned value=__atomic_load_n(&cached,__ATOMIC_RELAXED);
    if(!value) {
        unsigned a,b,c,d;
        value=__get_cpuid(1,&a,&b,&c,&d)&&(c&(1u<<20))?2:1;
        __atomic_store_n(&cached,value,__ATOMIC_RELAXED);
    }
    return value==2;
}
__attribute__((target("sse4.2")))
static inline uint32_t xc_crc_hardware(const unsigned char *p,size_t size) {
    uint64_t crc=UINT32_MAX;
    while(size>=8){uint64_t word;memcpy(&word,p,8);crc=_mm_crc32_u64(crc,word);p+=8;size-=8;}
    while(size--){crc=_mm_crc32_u8((uint32_t)crc,*p++);}
    return ~(uint32_t)crc;
}
#endif
static inline uint32_t xc_checksum(const unsigned char *p,size_t size) {
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
    if(xc_has_sse42())return xc_crc_hardware(p,size);
#endif
    /* Reflected CRC-32C. The cache is private; this detects incomplete writes
     * and corruption, not a malicious writer with the owner's permissions. */
    uint32_t crc=UINT32_MAX;
    for(size_t i=0;i<size;i++) {
        crc^=p[i];for(unsigned j=0;j<8;j++)crc=(crc>>1)^(UINT32_C(0x82f63b78)&(0-(crc&1)));
    }return ~crc;
}
static inline int xc_io(int fd,void *data,size_t n,uint64_t offset,int write_) {
    unsigned char *p=data;
    while(n) {
        ssize_t rc=write_?pwrite(fd,p,n,(off_t)offset):pread(fd,p,n,(off_t)offset);
        if(rc<0&&errno==EINTR)continue;
        if(rc<=0)return -1;
        p+=(size_t)rc;n-=(size_t)rc;offset+=(size_t)rc;
    }return 0;
}
#endif
