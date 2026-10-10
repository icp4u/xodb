/* Synthetic value image with independent storage offsets. CHECK remains
 * active under NDEBUG. The live Go fixture is the layout/semantic oracle. */
#define _POSIX_C_SOURCE 200809L
#include "../src/language/go_value.h"
#include "check.h"
#include <string.h>
#include <time.h>
#include <unistd.h>
#define LO UINT64_C(0x10000)
static uint8_t memory[0x20000];
static struct xgv_layout l;
static uint64_t fail_address, change_address;
static size_t calls;
enum { MODULE = 0x10000, INT = 0x11000, INTER = 0x11100, POINTER = 0x11200, ZERO = 0x11300,
       NAMES = 0x11800, IFACE = 0x14000, ITAB = 0x14100, DATA = 0x14400, CHAN = 0x15000, NODES = 0x18000 };
static int read_memory(void *context, uint64_t at, void *out, size_t n) {
    (void)context; ++calls;
    if (at < LO || at - LO > sizeof memory || n > sizeof memory - (at - LO)) return -1;
    if (fail_address && at <= fail_address && fail_address - at < n) return -1;
    memcpy(out, memory + at - LO, n);
    if (change_address == at) memory[at - LO] ^= 1;
    return 0;
}
static void raw(uint64_t at, uint64_t v, unsigned n) {
    CHECK(at >= LO && at - LO + n <= sizeof memory && n <= 8);
    for (unsigned i = 0; i < n; ++i) memory[at - LO + i] = (uint8_t)(v >> (8 * i));
}
static void put(uint64_t at, unsigned f, uint64_t v) { raw(at + l.fields[f].offset, v, l.fields[f].size); }
static struct xgo_reader reader(void) { calls = 0; return (struct xgo_reader){.read = read_memory}; }
static void type(uint64_t at, uint64_t size, uint64_t pointers, unsigned kind, const char *name, unsigned slot) {
    put(at, XGV_T_SIZE, size); put(at, XGV_T_PTRBYTES, pointers); put(at, XGV_T_HASH, slot + 123);
    put(at, XGV_T_FLAGS, size == 8 && pointers == 8 ? 32 : 0);
    put(at, XGV_T_ALIGN, size ? 8 : 1); put(at, XGV_T_FIELDALIGN, size ? 8 : 1); put(at, XGV_T_KIND, kind);
    uint64_t str = NAMES + slot * 128;
    CHECK(strlen(name) < 128);
    raw(str, 0, 1); raw(str + 1, strlen(name), 1); memcpy(memory + str + 2 - LO, name, strlen(name));
    put(at, XGV_T_NAME, str - INT);
}
static void image(void) {
    memset(memory, 0, sizeof memory); memset(&l, 0, sizeof l); fail_address = change_address = 0;
#define XGV_FIELD(key, owner, path, kind, width) \
    l.fields[XGV_##key] = (struct xgo_field_info){l.sizes[XGV_T_##owner], width}; l.sizes[XGV_T_##owner] += width;
#include "../src/language/go_value_fields.inc"
#undef XGV_FIELD
#define XGV_CONSTANT(key, name, value) l.constants[XGV_C_##key] = value;
#include "../src/language/go_value_constants.inc"
#undef XGV_CONSTANT
    l.build_id_len = 1; l.build_id[0] = 1;
    put(MODULE, XGV_MD_TYPES, INT); put(MODULE, XGV_MD_ETYPES, 0x13000);
    type(INT, 8, 0, 2, "int", 0); type(INTER, 16, 16, 20, "error", 1);
    type(POINTER, 8, 8, 22, "*int", 2); type(ZERO, 0, 0, 25, "struct {}", 3);
    put(IFACE, XGV_EF_TYPE, INT); put(IFACE, XGV_EF_DATA, DATA);
    put(ITAB, XGV_IT_INTER, INTER); put(ITAB, XGV_IT_TYPE, INT); put(ITAB, XGV_IT_HASH, 123); put(ITAB, XGV_IT_FUN, 0x400000);
    put(CHAN, XGV_CH_LEN, 2); put(CHAN, XGV_CH_CAP, 5); put(CHAN, XGV_CH_BUF, DATA);
    put(CHAN, XGV_CH_ELEMSIZE, 8); put(CHAN, XGV_CH_ELEMTYPE, INT); put(CHAN, XGV_CH_SENDX, 2);
}
static struct xgv_interface iface(int nonempty) {
    struct xgo_reader r = reader(); struct xgv_interface out;
    xgv_interface_read(&l, &r, MODULE, IFACE, nonempty, &out); CHECK(r.reads == calls); return out;
}
static struct xgv_channel channel(void) {
    struct xgo_reader r = reader(); struct xgv_channel out;
    xgv_channel_read(&l, &r, MODULE, CHAN, &out); CHECK(r.reads == calls); return out;
}
static void why(const char *got, const char *want) { CHECK(got && !strcmp(got, want)); }
static void nodes(unsigned n, int select) {
    put(CHAN, XGV_CH_LEN, 0); put(CHAN, XGV_CH_CAP, 0); put(CHAN, XGV_CH_SENDX, 0);
    put(CHAN, XGV_CH_SEND_FIRST, n ? NODES : 0); put(CHAN, XGV_CH_SEND_LAST, n ? NODES + (n-1)*128 : 0);
    for (unsigned i = 0; i < n; ++i) {
        uint64_t at = NODES + i * 128;
        put(at, XGV_SD_NEXT, i+1 < n ? at+128 : 0); put(at, XGV_SD_PREV, i ? at-128 : 0);
        put(at, XGV_SD_CHAN, CHAN); put(at, XGV_SD_G, 0x28000 + i*8); put(at, XGV_SD_SELECT, select);
    }
}
static uint64_t rss(void) {
    FILE *f=fopen("/proc/self/statm","r"); unsigned long long total=0, resident=0;
    CHECK(f && fscanf(f,"%llu %llu",&total,&resident)==2); fclose(f);
    return (uint64_t)resident * (uint64_t)sysconf(_SC_PAGESIZE);
}
static uint64_t cpu(void) {
    struct timespec t; CHECK(clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t)==0);
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
void go_value_tests(void) {
    image(); struct xgv_interface v = iface(0);
    CHECK(!v.reason && !v.is_nil && !v.type.direct && v.value_address == DATA && !strcmp(v.type.name, "int"));
    put(IFACE, XGV_EF_TYPE, POINTER); put(IFACE, XGV_EF_DATA, 0); v = iface(0);
    CHECK(!v.reason && !v.is_nil && v.type.direct && !v.data && v.value_address == IFACE + l.fields[XGV_EF_DATA].offset);
    put(IFACE, XGV_EF_TYPE, 0); v = iface(0); CHECK(!v.reason && v.is_nil);
    put(IFACE, XGV_EF_DATA, 1); v = iface(0); why(v.reason, "GoInterfaceNilMismatch");
    image(); put(IFACE, XGV_IF_TAB, ITAB); v = iface(1); CHECK(!v.reason && !strcmp(v.type.name,"int"));
    put(ITAB, XGV_IT_HASH, 77); v = iface(1); why(v.reason,"GoInterfaceHashMismatch");
    put(ITAB, XGV_IT_HASH, 0); v = iface(1); why(v.reason,"GoInterfaceHashUnproved");
    put(ITAB, XGV_IT_HASH, 123); put(ITAB, XGV_IT_FUN, 0); v = iface(1); why(v.reason,"GoInterfaceItabInvalid");
    image(); put(INT, XGV_T_FLAGS, 32); v = iface(0); why(v.reason,"GoInterfaceStorageMismatch");
    image(); put(INT, XGV_T_KIND, 34); v = iface(0); why(v.reason,"GoRuntimeTypeInvalid");
    image(); put(INT, XGV_T_PTRBYTES, 16); v = iface(0); why(v.reason,"GoRuntimeTypeInvalid");
    image(); put(INT, XGV_T_FLAGS, 2); v = iface(0); why(v.reason,"GoTypeNameInvalid");
    type(INT, 8, 0, 2, "*int", 0); put(INT, XGV_T_FLAGS, 2); v = iface(0); CHECK(!v.reason && !strcmp(v.type.name,"int"));
    image(); put(INT, XGV_T_NAME, UINT32_MAX); v = iface(0); why(v.reason,"GoTypeNameUnmapped");
    image(); put(INT, XGV_T_NAME, 0x1fff); v = iface(0); why(v.reason,"GoTypeNameInvalid");
    image(); raw(NAMES+1, 255, 1); raw(NAMES+2, 2, 1); v = iface(0); why(v.reason,"GoTypeNameLimit");
    image(); put(IFACE, XGV_EF_TYPE, 0x29000); v = iface(0); why(v.reason,"GoRuntimeTypeUnmapped");
    put(MODULE, XGV_MD_NEXT, MODULE); v = iface(0); why(v.reason,"GoTypeModuleCycle");
    image(); change_address = IFACE; v = iface(0); why(v.reason,"GoValueChanged"); CHECK(!v.value_address);
    image(); struct xgv_channel c = channel(); CHECK(!c.reason && c.header_valid && c.waits_complete && c.length == 2 && c.capacity == 5);
    put(CHAN,XGV_CH_LEN,6); c = channel(); why(c.reason,"GoChannelHeaderInvalid"); CHECK(!c.header_valid);
    image(); put(CHAN,XGV_CH_SENDX,3); c=channel(); why(c.reason,"GoChannelHeaderInvalid");
    image(); put(CHAN,XGV_CH_CLOSED,2); c=channel(); why(c.reason,"GoChannelHeaderInvalid");
    image(); put(CHAN,XGV_CH_ELEMSIZE,4); c=channel(); why(c.reason,"GoChannelElementMismatch");
    image(); put(CHAN,XGV_CH_TIMER,0x29000); c=channel(); why(c.reason,"GoChannelTimerUnproved");
    image(); put(CHAN,XGV_CH_LOCK,1); c=channel(); why(c.reason,"GoChannelBusy");
    image(); put(CHAN,XGV_CH_ELEMSIZE,0); put(CHAN,XGV_CH_ELEMTYPE,ZERO); c=channel(); CHECK(!c.reason && c.element.size==0);
    image(); nodes(3,1); c=channel(); CHECK(!c.reason && c.send_entries==3 && c.select_entries==3 && c.waits_complete);
    put(NODES+128,XGV_SD_PREV,0); c=channel(); why(c.reason,"GoChannelQueueInvalid"); CHECK(!c.header_valid && !c.send_entries);
    image(); nodes(3,0); put(NODES+128,XGV_SD_NEXT,NODES); c=channel(); why(c.reason,"GoChannelQueueCycle");
    image(); nodes(3,0); put(NODES,XGV_SD_CHAN,CHAN+8); c=channel(); why(c.reason,"GoChannelQueueInvalid");
    image(); nodes(3,0); put(CHAN,XGV_CH_CLOSED,1); c=channel(); why(c.reason,"GoChannelQueueInvalid");
    image(); nodes(3,0); put(CHAN,XGV_CH_RECV_FIRST,NODES); put(CHAN,XGV_CH_RECV_LAST,NODES+256); c=channel(); why(c.reason,"GoChannelQueueCycle");
    image(); nodes(XGV_WAITERS+1,1);
    uint64_t rss_before=rss(), cpu_before=cpu(); c=channel(); uint64_t cpu_after=cpu(), rss_after=rss();
    why(c.reason,"GoChannelWaitLimit");
    printf("go-values-limit-cost: entries=%u cpu_ns=%llu rss_before=%llu rss_after=%llu\n",c.send_entries,
           (unsigned long long)(cpu_after-cpu_before),(unsigned long long)rss_before,(unsigned long long)rss_after);
    CHECK(c.header_valid && !c.waits_complete && c.send_entries==XGV_WAITERS && c.select_entries==XGV_WAITERS);
    image(); change_address=CHAN; c=channel(); why(c.reason,"GoValueChanged"); CHECK(!c.header_valid);
    image(); struct xgo_reader captured=reader();
    xgv_interface_from_bytes(&l,&captured,MODULE,memory+(IFACE-LO),16,0,&v);
    CHECK(!v.reason && v.value_address==DATA && !v.type.direct);
    put(IFACE,XGV_EF_TYPE,POINTER);put(IFACE,XGV_EF_DATA,0);captured=reader();
    xgv_interface_from_bytes(&l,&captured,MODULE,memory+(IFACE-LO),16,0,&v);
    CHECK(!v.reason && v.type.direct && !v.is_nil && !v.data && !v.value_address);
    captured=reader();xgv_interface_from_bytes(&l,&captured,MODULE,memory+(IFACE-LO),15,0,&v);
    why(v.reason,"GoInterfaceBytesInvalid");CHECK(!calls);
    image();put(IFACE,XGV_EF_TYPE,INTER);v=iface(0);why(v.reason,"GoInterfaceDynamicTypeInvalid");
    image(); struct xgo_reader r=reader(); r.bytes=XGV_BYTE_LIMIT+1; xgv_channel_read(&l,&r,MODULE,CHAN,&c);
    why(c.reason,"GoValueReadLimit"); CHECK(!calls);
    image(); r=reader(); r.reads=XGV_READ_LIMIT; xgv_interface_read(&l,&r,MODULE,IFACE,0,&v);
    why(v.reason,"GoValueReadLimit"); CHECK(!calls);
    image(); l.fields[XGV_CH_LEN].size=9; c=channel(); why(c.reason,"GoValueLayoutInvalid"); CHECK(!calls);
    image(); r=reader(); xgv_interface_read(&l,&r,MODULE,UINT64_MAX-8,0,&v); why(v.reason,"GoValueAddressInvalid"); CHECK(!calls);
    /* Any failed byte in the observed records must yield a reason. */
    image(); nodes(3,1);
    for (uint64_t at=CHAN; at<CHAN+l.sizes[XGV_T_CHAN]; ++at) {
        fail_address=at; c=channel(); why(c.reason,"GoValueUnreadable"); CHECK(!c.header_valid);
    }
    for (uint64_t at=NODES; at<NODES+l.sizes[XGV_T_SUDOG]; ++at) {
        fail_address=at; c=channel(); why(c.reason,"GoValueUnreadable"); CHECK(!c.header_valid);
    }
    image(); r=reader(); xgv_channel_read(&l,&r,MODULE,0,&c); CHECK(c.is_nil && c.header_valid && c.waits_complete && !c.reason && !calls);
    puts("go-values-component: checks active, values, corruptions, limits and stale reads pass");
}
#ifdef XGV_TEST_MAIN
int main(int argc, char **argv) {
    (void)argv; go_value_tests();
    if (argc > 1) { image(); struct xgv_channel c=channel(); CHECK(c.length == 3); }
    return 0;
}
#endif
