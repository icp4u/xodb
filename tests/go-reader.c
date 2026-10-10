/* Go reader against a synthetic runtime image: goroutine list, frame-pointer
 * walks, and planted corruptions that must become reasons, never frames. */
#include "../src/language/go.h"
#include "check.h"
#include <string.h>
#define LO UINT64_C(0x10000)
static unsigned char memory[0x10000];
static size_t reads;
static uint64_t unreadable;
static int fake_read(void *context, uint64_t at, void *out, size_t n) {
    (void)context; ++reads;
    if (at < LO || at - LO > sizeof memory || n > sizeof memory - (at - LO)) return -1;
    if (unreadable && at <= unreadable && unreadable < at + n) return -1;
    memcpy(out, memory + (at - LO), n);
    return 0;
}
static void put(uint64_t at, uint64_t value, unsigned width) {
    for (unsigned i = 0; i < width; ++i) memory[at - LO + i] = (unsigned char)(value >> (8 * i));
}
/* Synthetic layout: offsets are the fixture's own, not a runtime's. */
static struct xgo_layout l = {
    .fields = {
        [XGO_G_STACK_LO] = {0, 8}, [XGO_G_STACK_HI] = {8, 8}, [XGO_G_M] = {16, 8},
        [XGO_G_SCHED_SP] = {24, 8}, [XGO_G_SCHED_PC] = {32, 8}, [XGO_G_SCHED_BP] = {40, 8},
        [XGO_G_SYSCALL_SP] = {48, 8}, [XGO_G_SYSCALL_PC] = {56, 8}, [XGO_G_SYSCALL_BP] = {64, 8},
        [XGO_G_STATUS] = {72, 4}, [XGO_G_WAITREASON] = {76, 1}, [XGO_G_GOID] = {80, 8},
        [XGO_G_PARENT] = {88, 8}, [XGO_G_GOPC] = {96, 8}, [XGO_G_STARTPC] = {104, 8},
        [XGO_M_PROCID] = {0, 8}, [XGO_M_CURG] = {8, 8},
        [XGO_MD_PCLN] = {0, 8}, [XGO_MD_PCLN_LEN] = {8, 8}, [XGO_MD_NAMES] = {16, 8}, [XGO_MD_NAMES_LEN] = {24, 8},
        [XGO_MD_FTAB] = {32, 8}, [XGO_MD_FTAB_LEN] = {40, 8}, [XGO_MD_MINPC] = {48, 8}, [XGO_MD_MAXPC] = {56, 8},
        [XGO_MD_TEXT] = {64, 8}, [XGO_MD_TEXTSECT_LEN] = {72, 8}, [XGO_MD_NEXT] = {80, 8},
        [XGO_FT_ENTRY] = {0, 4}, [XGO_FT_FUNC] = {4, 4},
        [XGO_FN_ENTRY] = {0, 4}, [XGO_FN_NAME] = {4, 4}, [XGO_FN_ID] = {8, 1},
        [XGO_STR_PTR] = {0, 8}, [XGO_STR_LEN] = {8, 8}, [XGO_GS_PTR] = {0, 8}, [XGO_GS_LEN] = {8, 8},
    },
    .sizes = {[XGO_T_G] = 112, [XGO_T_M] = 16, [XGO_T_MODULE] = 88, [XGO_T_FTAB] = 8, [XGO_T_FUNC] = 12, [XGO_T_STRING] = 16, [XGO_T_GSLICE] = 24},
    .constants = {
#define XGO_CONSTANT(key, name, value) [XGO_C_##key] = value,
#include "../src/language/go_constants.inc"
#undef XGO_CONSTANT
    },
};
enum { MD = 0x10000, FTAB = 0x10100, PCLN = 0x10200, NAMES = 0x10300, ALLGS = 0x10400, ALLGLEN = 0x10480,
       STRINGS = 0x10500, TEXTS = 0x10600, G0 = 0x11000, M0 = 0x13000, STACK = 0x14000, TEXT = 0x400000 };
static const char *const names[] = {"main.leaf", "main.caller", "runtime.goexit", "main.(*Pool).Run.gowrap1"};
static void image(void) {
    memset(memory, 0, sizeof memory); unreadable = 0;
    put(MD + 0, PCLN, 8); put(MD + 8, 0x100, 8); put(MD + 16, NAMES, 8); put(MD + 24, 0x100, 8);
    put(MD + 32, FTAB, 8); put(MD + 40, 5, 8); put(MD + 48, TEXT, 8); put(MD + 56, TEXT + 0x1000, 8);
    put(MD + 64, TEXT, 8); put(MD + 72, 1, 8);
    uint64_t name = 0;
    for (unsigned i = 0; i < 4; ++i) {
        put(FTAB + i * 8, i * 0x100, 4); put(FTAB + i * 8 + 4, i * 16, 4);
        put(PCLN + i * 16, i * 0x100, 4); put(PCLN + i * 16 + 4, name, 4);
        put(PCLN + i * 16 + 8, i == 2 ? l.constants[XGO_C_FUNC_GOEXIT] : i == 3 ? l.constants[XGO_C_FUNC_WRAPPER] : 0, 1);
        memcpy(memory + (NAMES + name - LO), names[i], strlen(names[i]) + 1); name += strlen(names[i]) + 1;
    }
    put(FTAB + 32, 0x1000, 4);
    /* gStatusStrings and waitReasonStrings: {"waiting","running"} / {"", "select"} */
    const char *texts[] = {"idle", "runnable", "running", "syscall", "waiting", "", "dead", "select"};
    for (unsigned i = 0; i < 8; ++i) {
        memcpy(memory + (TEXTS + i * 16 - LO), texts[i], strlen(texts[i]));
        put(STRINGS + i * 16, TEXTS + i * 16, 8); put(STRINGS + i * 16 + 8, strlen(texts[i]), 8);
    }
}
static uint64_t goroutine(unsigned i, uint64_t goid, uint32_t status, uint64_t pc, uint64_t bp) {
    uint64_t g = G0 + i * 0x100, stack = STACK + i * 0x400;
    put(ALLGS + i * 8, g, 8);
    put(g + 0, stack, 8); put(g + 8, stack + 0x400, 8); put(g + 32, pc, 8); put(g + 40, bp, 8); put(g + 24, stack + 0x10, 8);
    put(g + 72, status, 4); put(g + 76, 1, 1); put(g + 80, goid, 8); put(g + 96, TEXT + 0x105, 8); put(g + 104, TEXT, 8);
    return stack;
}
static void chain(uint64_t stack) {
    /* leaf(bp=stack+0x100) -> caller(bp=+0x200) -> goexit */
    put(stack + 0x100, stack + 0x200, 8); put(stack + 0x108, TEXT + 0x110, 8);
    put(stack + 0x200, 0, 8); put(stack + 0x208, TEXT + 0x201, 8);
}
static struct xgo_snapshot snap;
static void run(unsigned count, uint64_t allglen) {
    put(ALLGS + 0x60, ALLGS, 8);
    /* allgs slice header lives at ALLGS+0x60, elements at ALLGS */
    put(ALLGS + 0x68, count, 8); put(ALLGLEN, allglen, 8);
    struct xgo_globals gl = {.allgs = ALLGS + 0x60, .allglen = ALLGLEN, .moduledata = MD, .wait_strings = STRINGS + 7 * 16 - 16, .wait_count = 2, .status_strings = STRINGS, .status_count = 7};
    struct xgo_reader r = {.read = fake_read};
    reads = 0;
    xgo_goroutines_read(&l, &r, &gl, &snap);
    CHECK(r.reads == reads);
}
void go_value_tests(void);
void go_map_tests(void);
int main(void) {
    go_value_tests();
    go_map_tests();
    image();
    uint64_t s0 = goroutine(0, 7, 4, TEXT + 0x10, STACK + 0x100); chain(s0);
    goroutine(1, 8, 4, UINT64_C(0xdead0000), STACK + 0x400 + 0x100);              /* corrupted sched.pc */
    uint64_t s2 = goroutine(2, 9, 4, TEXT + 0x10, STACK + 0x800 + 0x100); chain(s2);
    put(s2 + 0x100, UINT64_C(0x7fff0000), 8);                                     /* bp leaves the stack */
    uint64_t s3 = goroutine(3, 10, 6, TEXT, 0);                                   /* dead: skipped */
    (void)s3;
    uint64_t s4 = goroutine(4, 11, 2, 0, 0); put(G0 + 4 * 0x100 + 16, M0, 8);      /* running on thread 4242 */
    put(M0, 4242, 8); put(M0 + 8, G0 + 4 * 0x100, 8); (void)s4;
    run(5, 5);
    CHECK(snap.reason == NULL && snap.total == 5 && snap.count == 4 && snap.dead == 1 && !snap.truncated);
    struct xgo_goroutine *g = &snap.items[0];
    CHECK(g->goid == 7 && g->complete && g->reason == NULL && g->count == 3);
    CHECK(!strcmp(g->status_name, "waiting") && !strcmp(g->wait_name, "select"));
    CHECK(!strcmp(g->frames[0].func.name, "main.leaf") && g->frames[0].lookup_pc == TEXT + 0xf);
    CHECK(!strcmp(g->frames[1].func.name, "main.caller") && g->frames[1].lookup_pc == TEXT + 0x10f);
    CHECK(!strcmp(g->frames[2].func.name, "runtime.goexit") && g->frames[2].func.id == l.constants[XGO_C_FUNC_GOEXIT]);
    CHECK(!strcmp(g->creator.name, "main.caller") && !strcmp(g->start.name, "main.leaf") && !g->system);
    /* Planted negative: corrupted g.sched.pc is a partial result with a reason. */
    g = &snap.items[1];
    CHECK(g->goid == 8 && !g->complete && g->count == 1 && g->reason && !strcmp(g->reason, "GoFramePcUnmapped"));
    CHECK(g->frames[0].func.name[0] == 0 && g->frames[0].reason != NULL);
    g = &snap.items[2];
    CHECK(g->goid == 9 && !g->complete && g->count == 2 && !strcmp(g->reason, "GoFramePointerOutOfStack"));
    g = &snap.items[3];
    CHECK(g->goid == 11 && g->running && g->thread == 4242 && g->count == 0 && g->reason == NULL);
    /* A read failure inside the chain is a reason, and the frames before it stay. */
    unreadable = s0 + 0x200;
    run(1, 1);
    CHECK(snap.count == 1 && snap.items[0].count == 2 && !snap.items[0].complete && !strcmp(snap.items[0].reason, "GoStackUnreadable"));
    unreadable = 0;
    /* ftab and _func disagree on the entry: refuse, never misname. */
    put(PCLN + 0 * 16, 0x80, 4);
    run(1, 1);
    CHECK(snap.items[0].count == 1 && !strcmp(snap.items[0].frames[0].reason, "GoPclntabMismatch"));
    put(PCLN + 0 * 16, 0, 4);
    /* The runtime keeps two counts; disagreement refuses the whole list. */
    run(1, 2);
    CHECK(snap.count == 0 && !strcmp(snap.reason, "GoAllgsInconsistent"));
    /* Every read failure position terminates with a reason and no crash. */
    for (uint64_t at = LO; at < LO + 0x6000; at += 8) {
        unreadable = at; run(5, 5);
        for (size_t i = 0; i < snap.count; ++i)
            CHECK(snap.items[i].complete ? snap.items[i].reason == NULL : snap.items[i].count <= XGO_FRAMES);
    }
    unreadable = 0;
    /* Go's traceback filter. */
    CHECK(!xgo_traceback_visible(&l, "runtime.gopark", 0, 1, 0, 0));
    CHECK(xgo_traceback_visible(&l, "runtime.Gosched", 0, 1, 0, 0));
    CHECK(!xgo_traceback_visible(&l, "runtime.(*foo).Bar", 0, 1, 0, 0));
    CHECK(xgo_traceback_visible(&l, "runtime.(*Func).Name", 0, 1, 0, 0));
    CHECK(xgo_traceback_visible(&l, "runtime.gopanic", 0, 0, 1, 0) && !xgo_traceback_visible(&l, "runtime.gopanic", 0, 1, 0, 0));
    CHECK(!xgo_traceback_visible(&l, "main.(*Pool).Run.gowrap1", (uint8_t)l.constants[XGO_C_FUNC_WRAPPER], 0, 1, 0));
    CHECK(xgo_traceback_visible(&l, "main.wrapper", (uint8_t)l.constants[XGO_C_FUNC_WRAPPER], 0, 1, (uint8_t)l.constants[XGO_C_FUNC_SIGPANIC]));
    CHECK(xgo_traceback_visible(&l, "time.Sleep", 0, 0, 1, 0) && xgo_traceback_visible(&l, "internal/sync.runtime_SemacquireMutex", 0, 1, 0, 0));
    puts("go-reader: ok");
    return 0;
}
