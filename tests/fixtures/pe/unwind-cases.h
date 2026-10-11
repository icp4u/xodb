/* Crafted epilog and unwind-record shapes, shared by the host component test
 * (explicit expected values) and the Wine differential oracle (the platform's
 * own RtlVirtualUnwind). One image layout serves every case:
 *   0x100-0x180  function under test, UNWIND_INFO at 0x200, code at pc
 *   0x180-0x1c0  an ordinary callee: "sub rsp,40", UNWIND_INFO at 0x240
 *   0x1c0-0x1f0  a cold fragment: codes with no prolog, UNWIND_INFO at 0x250
 * Unless a case says otherwise the function is "push rbx; sub rsp,32". */
#ifndef XODB_TEST_UNWIND_CASES_H
#define XODB_TEST_UNWIND_CASES_H
enum uw_expect { UW_UNWIND, UW_EPILOG };
struct uw_case {
    const char *name;
    unsigned char record[12], code[12];
    unsigned record_size, code_size, pc;
    unsigned used;  /* bytes between rsp at pc and the return address */
    int saved;      /* rbx is on the stack and must be restored */
    int frame;      /* rbp frame: rbp and rbx pushed, rbp is the frame */
    enum uw_expect expect;
    /* 0: not compared with the platform; the reason is on the case. */
    int platform;
};
static const struct uw_case uw_cases[] = {
    /* Switch dispatch in the body: the frame is intact. */
    {"body-jmp-mem", {1,5,2,0, 5,0x32, 1,0x30}, {0xff,0x20}, 8, 2, 0x170, 40, 1, 0, UW_UNWIND, 1},
    {"body-jmp-table", {1,5,2,0, 5,0x32, 1,0x30}, {0xff,0x24,0xc8}, 8, 3, 0x170, 40, 1, 0, UW_UNWIND, 1},
    {"body-jmp-reg", {1,5,2,0, 5,0x32, 1,0x30}, {0xff,0xe0}, 8, 2, 0x170, 40, 1, 0, UW_UNWIND, 1},
    {"body-jmp-near", {1,5,2,0, 5,0x32, 1,0x30}, {0xeb,0x02}, 8, 2, 0x170, 40, 1, 0, UW_UNWIND, 1},
    /* Tail calls: the frame is already gone at the jmp. */
    {"tail-jmp-import", {1,5,2,0, 5,0x32, 1,0x30}, {0xff,0x25,0,0,0,0}, 8, 6, 0x170, 0, 0, 0, UW_EPILOG, 1},
    {"tail-rex-jmp-reg", {1,5,2,0, 5,0x32, 1,0x30}, {0x48,0xff,0xe0}, 8, 3, 0x170, 0, 0, 0, UW_EPILOG, 1},
    {"tail-rex-jmp-mem", {1,5,2,0, 5,0x32, 1,0x30}, {0x48,0xff,0x20}, 8, 3, 0x170, 0, 0, 0, UW_EPILOG, 1},
    {"tail-jmp-callee", {1,5,2,0, 5,0x32, 1,0x30}, {0xe9,0x0b,0,0,0}, 8, 5, 0x170, 0, 0, 0, UW_EPILOG, 1},
    {"tail-jmp-leaf", {1,5,2,0, 5,0x32, 1,0x30}, {0xe9,0x83,0,0,0}, 8, 5, 0x170, 0, 0, 0, UW_EPILOG, 1},
    /* Whole epilogs ending in a jmp. */
    {"epilog-jmp-import", {1,5,2,0, 5,0x32, 1,0x30}, {0x48,0x83,0xc4,32,0x5b,0xff,0x25,0,0,0,0}, 8, 11, 0x170, 40, 1, 0, UW_EPILOG, 1},
    {"epilog-jmp-out", {1,5,2,0, 5,0x32, 1,0x30}, {0x48,0x83,0xc4,32,0x5b,0xe9,0x7e,0,0,0}, 8, 10, 0x170, 40, 1, 0, UW_EPILOG, 1},
    /* "sub rsp,8" undone by popping a volatile register. */
    {"epilog-pop-volatile", {1,4,1,0, 4,0x02}, {0x59,0xc3}, 6, 2, 0x170, 8, 0, 0, UW_EPILOG, 1},
    /* Ordinary callees may have interior entry points: the frame is gone. */
    {"tail-jmp-interior", {1,5,2,0, 5,0x32, 1,0x30}, {0xe9,0x1b,0,0,0}, 8, 5, 0x170, 0, 0, 0, UW_EPILOG, 1},
    /* Wine 11.19 treats these unchained fragment jumps as tail calls. */
    {"fragment-jmp-hot", {1,0,2,0, 0,0x32, 0,0x30}, {0xe9,0x1b,0,0,0}, 8, 5, 0x170, 40, 1, 0, UW_UNWIND, 0},
    {"fragment-jmp-cold", {1,5,2,0, 5,0x32, 1,0x30}, {0xe9,0x4b,0,0,0}, 8, 5, 0x170, 40, 1, 0, UW_UNWIND, 0},
    {"fragment-jmp-chain", {1,5,2,0, 5,0x32, 1,0x30}, {0xe9,0x0b,1,0,0}, 8, 5, 0x170, 40, 1, 0, UW_UNWIND, 1},
    /* Wine 11.19 does not recognize BND-prefixed final transfers. */
    {"bnd-tail-ret", {1,5,2,0, 5,0x32, 1,0x30}, {0xf2,0xc3}, 8, 2, 0x170, 0, 0, 0, UW_EPILOG, 0},
    {"bnd-pop-ret", {1,5,2,0, 5,0x32, 1,0x30}, {0x5b,0xf2,0xc3}, 8, 3, 0x170, 8, 1, 0, UW_EPILOG, 0},
    {"bnd-tail-jmp", {1,5,2,0, 5,0x32, 1,0x30}, {0xf2,0xe9,0x0a,0,0,0}, 8, 6, 0x170, 0, 0, 0, UW_EPILOG, 0},
    {"bnd-tail-rex-jmp", {1,5,2,0, 5,0x32, 1,0x30}, {0xf2,0x48,0xff,0xe0}, 8, 4, 0x170, 0, 0, 0, UW_EPILOG, 0},
    {"bnd-body-jmp", {1,5,2,0, 5,0x32, 1,0x30}, {0xf2,0xff,0xe0}, 8, 3, 0x170, 40, 1, 0, UW_UNWIND, 1},
    /* Records a GCC-style toolchain emits: every code at offset 0 with no
     * prolog (a cold half), here stopped on its first instruction; and the
     * frame pointer set between pushes, "push rbp; mov rbp,rsp; push rbx". */
    {"record-cold-half", {1,0,2,0, 0,0x32, 0,0x30}, {0x90}, 8, 1, 0x100, 40, 1, 0, UW_UNWIND, 1},
    {"record-frame-between-pushes", {1,9,4,0x05, 9,0x32, 5,0x30, 4,0x03, 1,0x50}, {0x90}, 12, 1, 0x170, 48, 1, 1, UW_UNWIND, 1},
};
static const unsigned char uw_callee_record[] = {1,4,1,0, 4,0x42};
static const unsigned char uw_cold_record[] = {1,0,2,0, 0,0x32, 0,0x30};
static const unsigned char uw_chain_record[] = {0x21,0,0,0, 0,1,0,0, 0x80,1,0,0, 0,2,0,0};
static const unsigned uw_rows[4][3] = {{0x100,0x180,0x200},{0x180,0x1c0,0x240},{0x1c0,0x1f0,0x250},{0x280,0x290,0x260}};
#endif
