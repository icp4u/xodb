/* Fast lane (<5 s): synthetic stopped memory, no runtime SDK or target calls. */
#include "../src/language/elisp.h"
#include "check.h"
#include <string.h>
#include <stddef.h>

enum { BASE = 0x10000, THREAD = BASE + 0x1000, SPEC = BASE + 0x2000,
       HANDLER = BASE + 0x4000, SENTINEL = BASE + 0x5000,
       SYMBOL = BASE + 0x6000, STRING = BASE + 0x7000, DATA = BASE + 0x8000 };
static unsigned char memory[1024 * 1024];
static struct xel_layout layout;
static struct xel_context context;
static struct xel_reader reader;
static struct xel_stack stack;
static size_t callbacks, top_reads;
static uint64_t unreadable;
static int mutate, mutate_current, mutate_bc;
static size_t current_reads, bc_reads;
static void put(uint64_t at, uint64_t v, size_t n) {
    CHECK(at >= BASE && at - BASE <= sizeof memory && n <= sizeof memory - (at - BASE));
    for (size_t i = 0; i < n; ++i) memory[at - BASE + i] = (unsigned char)(v >> (i * 8));
}
static void set(uint64_t at, unsigned f, uint64_t value) {
    put(at + layout.fields[f].offset, value, layout.fields[f].size);
}
static int read_memory(void *unused, uint64_t at, void *out, size_t n) {
    (void)unused; ++callbacks;
    if (at == BASE + 0x100 && ++current_reads == 2 && mutate_current) put(at, THREAD + 8, 8);
    if (at == THREAD + layout.fields[XEL_THREAD_BC_FP].offset && ++bc_reads == 2 && mutate_bc) put(at, BASE + 0xc008, 8);
    if (at == THREAD + layout.fields[XEL_THREAD_TOP].offset && ++top_reads == 2 && mutate)
        set(THREAD, XEL_THREAD_TOP, SPEC);
    if (at < BASE || at - BASE > sizeof memory || n > sizeof memory - (at - BASE) ||
        (unreadable >= at && unreadable - at < n)) return -1;
    memcpy(out, memory + at - BASE, n); return 0;
}
static void frame(size_t n, uint64_t fun, int64_t nargs) {
    uint64_t at = SPEC + n * layout.sizes[XEL_T_SPEC];
    set(at, XEL_SPEC_KIND, 7); set(at, XEL_SPEC_FUNCTION, fun);
    set(at, XEL_SPEC_ARGS, BASE + 0x9000); set(at, XEL_SPEC_NARGS, (uint64_t)nargs);
}
static void reset(void) {
    memset(memory, 0, sizeof memory); memset(&layout, 0, sizeof layout);
    layout.build_id_len = 1; layout.build_id[0] = 1;
    layout.sizes[XEL_T_THREAD] = 64; layout.sizes[XEL_T_SPEC] = 32;
    layout.sizes[XEL_T_HANDLER] = 24; layout.sizes[XEL_T_SYMBOL] = 32; layout.sizes[XEL_T_STRING] = 24;
    const unsigned offsets[XEL_FIELD_COUNT] = {0, 8, 16, 24, 32, 0, 8, 16, 24, 0, 8, 16, 0, 0, 8, 16, 0};
    for (size_t i = 0; i < XEL_FIELD_COUNT; ++i) layout.fields[i] = (struct xel_field_info){offsets[i], 8};
    layout.fields[XEL_SPEC_KIND].size = 1; layout.fields[XEL_HANDLER_KIND].size = 4;
    layout.sizes[XEL_T_MAIN] = 64; layout.fields[XEL_MAIN_STATE].size = 64;
    layout.sizes[XEL_T_BC] = 32; layout.sizes[XEL_T_VECTOR] = 8;
    layout.fields[XEL_THREAD_BC_FP] = (struct xel_field_info){40,8};
    layout.fields[XEL_THREAD_BC_START] = (struct xel_field_info){48,8};
    layout.fields[XEL_THREAD_BC_END] = (struct xel_field_info){56,8};
    layout.fields[XEL_BC_PREVIOUS] = (struct xel_field_info){0,8};
    layout.fields[XEL_BC_TOP] = (struct xel_field_info){8,8};
    layout.fields[XEL_BC_FUNCTION] = (struct xel_field_info){24,8};
    layout.fields[XEL_BC_STACK] = (struct xel_field_info){32,0};
    layout.fields[XEL_VECTOR_HEADER] = (struct xel_field_info){0,8};
    layout.fields[XEL_VECTOR_CONTENTS] = (struct xel_field_info){8,0};
    layout.sizes[XEL_T_CONS] = 16; layout.sizes[XEL_T_FLOAT] = 8;
    layout.sizes[XEL_T_HASH] = 32; layout.sizes[XEL_T_BUFFER] = 56;
    layout.sizes[XEL_T_MARKER] = 24; layout.sizes[XEL_T_WINDOW] = 16;
    const struct xel_field_info more[] = {{0,8},{8,8},{0,8},{0,8},{8,8},{16,4},{20,4},
        {0,8},{8,8},{16,8},{24,8},{32,8},{40,8},{0,8},{8,8},{16,8},{0,8},{8,8}};
    for (size_t i = 0; i < sizeof more / sizeof *more; ++i) layout.fields[XEL_CONS_CAR+i] = more[i];
    layout.fields[XEL_SPEC_SYMBOL] = (struct xel_field_info){8,8};
    layout.fields[XEL_SPEC_OLD_VALUE] = (struct xel_field_info){16,8};
    layout.fields[XEL_SYMBOL_REDIRECT] = (struct xel_field_info){16,1};
    layout.fields[XEL_SYMBOL_VALUE] = (struct xel_field_info){8,8};
    layout.sizes[XEL_T_FWD] = 16;
    layout.fields[XEL_FWD_KIND] = (struct xel_field_info){0,1};
    layout.fields[XEL_FWD_OBJECT] = (struct xel_field_info){8,8};
    context.lispsym = SYMBOL;
    for (size_t i = 0; i < XEL_GLOBAL_COUNT; ++i) context.globals[i] = BASE + i * 8;
#define XEL_GLOBAL(name, width, value) put(context.globals[XEL_G_##name], value, width);
#include "../src/language/elisp_globals.inc"
#undef XEL_GLOBAL
    set(THREAD, XEL_THREAD_FIRST, SPEC); set(THREAD, XEL_THREAD_TOP, SPEC + 4 * 32);
    set(THREAD, XEL_THREAD_END, SPEC + 8 * 32); set(THREAD, XEL_THREAD_HANDLERS, HANDLER);
    set(THREAD, XEL_THREAD_SENTINEL, SENTINEL);
    frame(0, 8, 2); frame(1, UINT64_MAX - 7, -1); frame(3, 3, 0);
    set(SPEC + 2 * 32, XEL_SPEC_KIND, 0); /* C cleanup, not necessarily Lisp unwind-protect. */
    set(HANDLER, XEL_HANDLER_KIND, 1); set(HANDLER, XEL_HANDLER_NEXT, SENTINEL);
    set(HANDLER, XEL_HANDLER_DEPTH, 2 * 32);
    set(SYMBOL + 8, XEL_SYMBOL_NAME, STRING | 4); set(SYMBOL - 8, XEL_SYMBOL_NAME, STRING | 4);
    set(STRING, XEL_STRING_CHARS, 4); set(STRING, XEL_STRING_BYTES, UINT64_MAX);
    set(STRING, XEL_STRING_DATA, DATA); memcpy(memory + DATA - BASE, "demo", 4);
    reader = (struct xel_reader){.read = read_memory};
    callbacks = top_reads = 0; unreadable = 0; mutate = mutate_current = mutate_bc = 0; current_reads = bc_reads = 0;
}
static void run(const char *why) {
    xel_stack_read(&layout, &reader, &context, THREAD, &stack);
    CHECK(why ? stack.reason && !strcmp(stack.reason, why) : !stack.reason);
    CHECK(reader.reads == callbacks && reader.reads <= XEL_READ_LIMIT && reader.bytes <= XEL_BYTE_LIMIT);
}
enum { FUNCTION = BASE + 0xa000, FUNCTION2 = BASE + 0xa080, CONS_BODY = BASE + 0xb000,
       BC_START = BASE + 0xc000, BC_OUTER = BC_START + 128, BC_INNER = BC_START + 256 };
static void closure(uint64_t at, uint64_t code) {
    set(at, XEL_VECTOR_HEADER, UINT64_C(0x400000001f000003));
    put(at + layout.fields[XEL_VECTOR_CONTENTS].offset + 8, code, 8);
}
static void kind_fixture(void) {
    reset();
    closure(FUNCTION, CONS_BODY | 3);
    set(THREAD, XEL_THREAD_BC_FP, BC_START);
    set(THREAD, XEL_THREAD_BC_START, BC_START);
    set(THREAD, XEL_THREAD_BC_END, BC_START + 4096);
}
static void bytecode_fixture(void) {
    kind_fixture(); closure(FUNCTION, STRING | 4); closure(FUNCTION2, STRING | 4);
    set(THREAD, XEL_THREAD_BC_FP, BC_INNER);
    set(BC_INNER, XEL_BC_PREVIOUS, BC_OUTER); set(BC_INNER, XEL_BC_TOP, BC_START + 64);
    set(BC_INNER, XEL_BC_FUNCTION, FUNCTION2 | 5);
    set(BC_OUTER, XEL_BC_PREVIOUS, BC_START); set(BC_OUTER, XEL_BC_FUNCTION, FUNCTION | 5);
    put(BC_START + 64, 8, 8); set(SPEC, XEL_SPEC_ARGS, BC_START + 72);
}
static void kinds(const struct xel_activation *native, size_t count, const char *why) {
    run(NULL);
    xel_stack_kinds(&layout, &reader, &context, native, count, &stack);
    CHECK(why ? stack.classification_reason && !strcmp(stack.classification_reason, why) : !stack.classification_reason);
    CHECK(!stack.reason && stack.count == 3);
    CHECK(reader.reads == callbacks && reader.reads <= XEL_READ_LIMIT && reader.bytes <= XEL_BYTE_LIMIT);
}
static void test_kinds(int wrong) {
    struct xel_activation native = {.function=FUNCTION | 5, .args=BASE + 0x9000, .nargs=2, .native_frame=9, .execution_kind=XEL_INTERPRETED};
    kind_fixture(); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == (unsigned)(wrong ? XEL_BYTECODE : XEL_INTERPRETED));
    CHECK(stack.frames[2].native_frame == 9 && stack.frames[2].active_function == (FUNCTION | 5));
    CHECK(stack.frames[2].kind_reason == NULL && stack.frames[2].kind_basis);
    kind_fixture(); closure(FUNCTION, STRING | 4); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN && !strcmp(stack.frames[2].kind_reason, "ElispActivationKindMismatch"));
    native.execution_kind = XEL_BYTECODE;
    kind_fixture(); closure(FUNCTION, STRING | 4); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_BYTECODE);
    kind_fixture(); closure(FUNCTION, STRING | 4); set(STRING, XEL_STRING_BYTES, UINT64_MAX - 2); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_BYTECODE); /* pinned bytecode, not malformed */
    native.execution_kind = XEL_INTERPRETED;
    kind_fixture(); set(FUNCTION, XEL_VECTOR_HEADER, 3); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN);
    kind_fixture(); struct xel_activation duplicate[2] = {native,native}; kinds(duplicate, 2, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN && !strcmp(stack.frames[2].kind_reason,"ElispActivationAmbiguous"));
    kind_fixture(); set(SPEC + 3 * 32, XEL_SPEC_NARGS, 2); kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN && !strcmp(stack.frames[2].kind_reason, "ElispActivationAmbiguous"));
    kind_fixture(); mutate_bc = 1; kinds(&native, 1, "ElispStateChanged");
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN);
    kind_fixture(); native.nargs = 3; kinds(&native, 1, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN); native.nargs = 2;
    kind_fixture(); kinds(NULL, 65, "ElispNativeActivationLimit");
    bytecode_fixture(); kinds(NULL, 0, NULL);
    CHECK(stack.frames[2].execution_kind == XEL_BYTECODE && stack.frames[2].native_frame == SIZE_MAX);
    CHECK(stack.frames[2].active_function == (FUNCTION2 | 5));
    bytecode_fixture(); put(BC_START + 64, 16, 8); kinds(NULL, 0, "ElispBytecodeFunctionMismatch");
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN);
    bytecode_fixture(); set(BC_INNER, XEL_BC_PREVIOUS, BC_INNER); kinds(NULL, 0, "ElispBytecodeChainInvalid");
    bytecode_fixture(); set(SPEC, XEL_SPEC_NARGS, 100); kinds(NULL, 0, "ElispBytecodeArgumentsInvalid");
    bytecode_fixture(); set(BC_INNER, XEL_BC_TOP, BC_START + 8); kinds(NULL, 0, "ElispBytecodeArgumentsInvalid");
    bytecode_fixture(); set(BC_START, XEL_BC_FUNCTION, 8); kinds(NULL, 0, "ElispBytecodeSentinelInvalid");
    kind_fixture(); set(THREAD, XEL_THREAD_BC_FP, BC_START + 8); kinds(&native, 1, "ElispBytecodeSentinelInvalid");
    CHECK(stack.frames[2].execution_kind == XEL_UNKNOWN); /* withdraw earlier native proof */
}
static struct xel_value value;
static void preview(uint64_t tagged, const char *type, const char *text, const char *why) {
    reader = (struct xel_reader){.read=read_memory}; callbacks = 0;
    xel_value_read(&layout,&reader,&context,tagged,&value);
    CHECK(!strcmp(value.type,type));
    if (text) CHECK(!strcmp(value.display,text));
    if ((why && (!value.reason || strcmp(value.reason,why))) || (!why && value.reason)) fprintf(stderr,"value %s: expected %s, got %s\n",type,why ? why : "none",value.reason ? value.reason : "none");
    CHECK(why ? value.reason && !strcmp(value.reason,why) : !value.reason);
    CHECK(reader.reads == callbacks && reader.reads <= XEL_READ_LIMIT && reader.bytes <= XEL_BYTE_LIMIT);
}
static void test_values(int wrong) {
    reset(); preview(((uint64_t)-17 << 2) | 2, "fixnum", wrong ? "-18" : "-17", NULL);
    preview((UINT64_C(1) << 63) | 2,"fixnum","-2305843009213693952",NULL);
    preview((UINT64_C(1) << 63)-2,"fixnum","2305843009213693951",NULL);
    preview(STRING | 4,"string","\"demo\"",NULL);
    preview(8,"symbol","demo",NULL);
    set(STRING,XEL_STRING_BYTES,UINT64_MAX-2); preview(STRING | 4,"string","\"demo\"",NULL);
    set(STRING,XEL_STRING_BYTES,4); set(STRING,XEL_STRING_CHARS,3);
    memcpy(memory+DATA-BASE,"a\xc3\xa9z",4); preview(STRING | 4,"string","\"a\xc3\xa9z\"",NULL);
    set(STRING,XEL_STRING_CHARS,4); preview(STRING | 4,"string",NULL,"ElispStringLengthMismatch");
    set(STRING,XEL_STRING_BYTES,UINT64_MAX-3); preview(STRING | 4,"string",NULL,"ElispStringHeaderInvalid");
    reset(); set(CONS_BODY,XEL_CONS_CAR,42); set(CONS_BODY,XEL_CONS_CDR,0);
    preview(CONS_BODY | 3,"list","(10)",NULL);
    set(CONS_BODY,XEL_CONS_CDR,46); preview(CONS_BODY | 3,"list","(10 . 11)",NULL);
    set(CONS_BODY,XEL_CONS_CDR,CONS_BODY | 3); preview(CONS_BODY | 3,"list",NULL,"ElispValueCycle");
    set(CONS_BODY,XEL_CONS_CDR,0); set(CONS_BODY,XEL_CONS_CAR,CONS_BODY | 3); preview(CONS_BODY | 3,"list",NULL,"ElispValueCycle");
    reset(); set(FUNCTION,XEL_VECTOR_HEADER,2);
    put(FUNCTION+8,42,8); put(FUNCTION+16,46,8); preview(FUNCTION | 5,"vector","[10 11]",NULL);
    put(FUNCTION+8,FUNCTION | 5,8); preview(FUNCTION | 5,"vector",NULL,"ElispValueCycle");
    set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x4000000022000002)); put(FUNCTION+8,8,8);
    preview(FUNCTION | 5,"record","#s(demo 11)",NULL);
    set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x4000000022001002)); preview(FUNCTION | 5,"record",NULL,"ElispVectorHeaderInvalid");
    set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x4000000000000000)); preview(FUNCTION | 5,"unknown",NULL,"ElispPseudovectorHeaderInvalid");
    reset(); double f=1.5; uint64_t bits; memcpy(&bits,&f,8); set(FUNCTION,XEL_FLOAT_DATA,bits);
    preview(FUNCTION | 7,"float","1.5",NULL); preview(7,"unknown",NULL,"ElispAddressInvalid");
    reset(); set(FUNCTION,XEL_HASH_HEADER,UINT64_C(0x400000000e003000));
    set(FUNCTION,XEL_HASH_PAIRS,CONS_BODY); set(FUNCTION,XEL_HASH_CAPACITY,2); set(FUNCTION,XEL_HASH_COUNT,1);
    put(CONS_BODY,8,8); put(CONS_BODY+8,42,8); put(CONS_BODY+16,7,8);
    preview(FUNCTION | 5,"hash-table","#<hash-table 1 entries>",NULL);
    CHECK(value.item_count==1 && !strcmp(value.items[0].key,"demo") && !strcmp(value.items[0].display,"10"));
    set(FUNCTION,XEL_HASH_COUNT,0); preview(FUNCTION | 5,"hash-table",NULL,"ElispHashCountMismatch");
    set(FUNCTION,XEL_HASH_COUNT,3); preview(FUNCTION | 5,"hash-table",NULL,"ElispHashHeaderInvalid");
    reset(); set(FUNCTION,XEL_VECTOR_HEADER,1000000); for (unsigned i=0;i<24;++i) put(FUNCTION+8+i*8,42,8);
    preview(FUNCTION | 5,"vector",NULL,"ElispPreviewLimit"); CHECK(value.truncated && value.item_count==24 && reader.bytes<1024);
    reset(); for (unsigned i=0;i<8;++i) {set(FUNCTION+i*16,XEL_VECTOR_HEADER,1);put(FUNCTION+i*16+8,(FUNCTION+(i+1)*16)|5,8);}
    preview(FUNCTION | 5,"vector",NULL,"ElispValueDepthLimit");
    reset(); set(STRING,XEL_STRING_CHARS,1); set(STRING,XEL_STRING_BYTES,2);
    memcpy(memory+DATA-BASE,"\xc2x",2); preview(STRING|4,"string",NULL,"ElispStringEncodingInvalid");
    memcpy(memory+DATA-BASE,"\xc0\x80",2); preview(STRING|4,"string","\"\\200\"",NULL);
    set(STRING,XEL_STRING_BYTES,5); memcpy(memory+DATA-BASE,"\xf8\x88\x80\x80\x80",5);
    preview(STRING|4,"string","\"\\U00200000\"",NULL);
    reset(); set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x400000000d006000));
    set(FUNCTION,XEL_BUFFER_NAME,STRING|4); set(FUNCTION,XEL_BUFFER_POINT,3);
    set(FUNCTION,XEL_BUFFER_BEG,1); set(FUNCTION,XEL_BUFFER_END,12);
    set(SYMBOL,XEL_SYMBOL_NAME,STRING|4);
    preview(FUNCTION|5,"buffer",NULL,NULL);
    set(FUNCTION,XEL_BUFFER_POINT,13); preview(FUNCTION|5,"buffer",NULL,"ElispBufferBoundsInvalid");
    set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x4000000003002000)); set(FUNCTION,XEL_MARKER_BUFFER,0);
    preview(FUNCTION|5,"marker","#<marker in no buffer>",NULL);
    set(FUNCTION,XEL_VECTOR_HEADER,UINT64_C(0x4000000003001000)); preview(FUNCTION|5,"marker",NULL,"ElispPseudovectorSizeInvalid");
    reset(); set(FUNCTION,XEL_VECTOR_HEADER,24);
    for (unsigned i=0;i<24;++i) put(FUNCTION+8+i*8,(CONS_BODY+512)|5,8);
    set(CONS_BODY+512,XEL_VECTOR_HEADER,24);
    for (unsigned i=0;i<24;++i) put(CONS_BODY+512+8+i*8,42,8);
    preview(FUNCTION|5,"vector",NULL,"ElispValueNodeLimit");
    CHECK(value.truncated);
    reset(); set(FUNCTION,XEL_VECTOR_HEADER,1); unreadable=FUNCTION+8;
    preview(FUNCTION | 5,"vector",NULL,"ElispMemoryUnavailable"); CHECK(value.item_count==0);
}
static struct xel_bindings bindings;
static uint64_t fixnum(int n) { return ((uint64_t)n << 2) | 2; }
static void binding(size_t index, uint64_t symbol, uint64_t old) {
    uint64_t at = SPEC + index * 32;
    set(at, XEL_SPEC_KIND, 11); set(at, XEL_SPEC_SYMBOL, symbol); set(at, XEL_SPEC_OLD_VALUE, old);
}
static void bindings_fixture(void) {
    reset();
    set(THREAD, XEL_THREAD_HANDLERS, SENTINEL);
    frame(0, 8, 0); binding(1, 128, fixnum(0)); frame(2, 8, 0); binding(3, 128, fixnum(11));
    set(SYMBOL+128, XEL_SYMBOL_NAME, STRING|4);
    set(SYMBOL+128, XEL_SYMBOL_VALUE, fixnum(22));
    run(NULL); CHECK(stack.count == 2);
}
static void test_bindings(int wrong) {
    bindings_fixture();
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && bindings.rows[0].has_value);
    CHECK(bindings.rows[0].value==fixnum(wrong ? 22 : 11));
    CHECK(bindings.rows[0].slot==SPEC+3*32+16 && bindings.rows[0].scope==XEL_DYNAMIC);
    xel_bindings_read(&layout,&reader,&context,&stack,0,0,&bindings);
    CHECK(!bindings.reason && bindings.rows[0].value==fixnum(22));
    CHECK(bindings.rows[0].slot==SYMBOL+128+8);
    bindings_fixture(); set(SYMBOL+128,XEL_SYMBOL_REDIRECT,2); /* alias: do not guess */
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && !bindings.rows[0].has_value);
    CHECK(!strcmp(bindings.rows[0].reason,"ElispBindingStorageUnproved"));
    bindings_fixture(); set(SPEC+3*32,XEL_SPEC_KIND,12); /* buffer-local inner rebind */
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(!bindings.rows[0].has_value);
    bindings_fixture(); top_reads=0; mutate=1;
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispStateChanged"));
    bindings_fixture(); unreadable=SPEC+3*32+16;
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispMemoryUnavailable"));
    bindings_fixture();
    const uint64_t envword=BASE+0x180, fwd=BASE+0xe000, current=BASE+0xe100;
    const uint64_t env=BASE+0xd000, pair=BASE+0xd100;
    put(envword,256,8); set(SYMBOL+256,XEL_SYMBOL_NAME,STRING|4);
    set(SYMBOL+256,XEL_SYMBOL_REDIRECT,6); set(SYMBOL+256,XEL_SYMBOL_VALUE,fwd);
    set(fwd,XEL_FWD_KIND,2); set(fwd,XEL_FWD_OBJECT,current); put(current,0,8);
    binding(1,256,0); binding(3,256,env|3);
    set(env,XEL_CONS_CAR,pair|3); set(env,XEL_CONS_CDR,0);
    set(pair,XEL_CONS_CAR,128); set(pair,XEL_CONS_CDR,fixnum(37));
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && bindings.rows[0].scope==XEL_LEXICAL);
    CHECK(bindings.rows[0].symbol==128 && bindings.rows[0].value==fixnum(37));
    CHECK(bindings.rows[0].slot==pair+8 && bindings.rows[0].environment==(env|3));
    /* The enclosing environment is shared, not introduced again by this let. */
    const uint64_t outer=env+32, outer_pair=pair+32;
    set(env,XEL_CONS_CDR,outer|3); set(outer,XEL_CONS_CAR,outer_pair|3); set(outer,XEL_CONS_CDR,0);
    set(outer_pair,XEL_CONS_CAR,8); set(outer_pair,XEL_CONS_CDR,fixnum(99));
    binding(1,256,outer|3);
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && bindings.rows[0].value==fixnum(37));
    binding(1,256,env|3);
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(!bindings.reason && bindings.count==0); /* unchanged environment */
    binding(1,256,0);
    set(env,XEL_CONS_CDR,env|3);
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(!strcmp(bindings.reason,"ElispLexicalEnvironmentCycle"));
    set(env,XEL_CONS_CDR,0); set(env,XEL_CONS_CAR,fixnum(3));
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispLexicalBindingInvalid"));
    put(envword,3,8);
    xel_bindings_read(&layout,&reader,&context,&stack,1,envword,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispEnvironmentSymbolInvalid"));
    bindings_fixture(); reader.reads=XEL_READ_LIMIT;
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispReadLimit"));
    bindings_fixture();
    for (size_t i=1;i<=XEL_BINDING_LIMIT+1;++i) binding(i,128,fixnum(11));
    set(THREAD,XEL_THREAD_TOP,SPEC+(XEL_BINDING_LIMIT+2)*32);
    set(THREAD,XEL_THREAD_END,SPEC+(XEL_BINDING_LIMIT+3)*32);
    run(NULL); CHECK(stack.count==1);
    xel_bindings_read(&layout,&reader,&context,&stack,0,0,&bindings);
    CHECK(bindings.count==XEL_BINDING_LIMIT && bindings.truncated && !strcmp(bindings.reason,"ElispBindingLimit"));
    bindings_fixture();
    for (size_t i=0;i<XEL_BINDING_HISTORY+1;++i) {
        uint64_t object=BASE+0x30000+i*64;
        binding(3+i,object-context.lispsym,fixnum(1));
        set(object,XEL_SYMBOL_NAME,STRING|4); set(object,XEL_SYMBOL_VALUE,fixnum(2));
    }
    set(THREAD,XEL_THREAD_TOP,SPEC+(XEL_BINDING_HISTORY+4)*32);
    set(THREAD,XEL_THREAD_END,SPEC+(XEL_BINDING_HISTORY+5)*32);
    run(NULL); CHECK(stack.count==2);
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && bindings.truncated && !strcmp(bindings.reason,"ElispBindingHistoryLimit"));
    bindings_fixture(); set(SPEC,XEL_SPEC_FUNCTION,128);
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispStateChanged"));
    bindings_fixture(); layout.fields[XEL_SYMBOL_REDIRECT].size=8;
    xel_bindings_read(&layout,&reader,&context,&stack,1,0,&bindings);
    CHECK(bindings.count==0 && !strcmp(bindings.reason,"ElispLayoutInvalid"));
}
static void test_partial_bindings(void) {
    bindings_fixture();
    set(THREAD,XEL_THREAD_HANDLERS,HANDLER);
    for (size_t i=0;i<=XEL_STACK_FRAMES;++i) frame(i,8,0);
    binding(XEL_STACK_FRAMES+1,128,fixnum(0));
    set(THREAD,XEL_THREAD_TOP,SPEC+(XEL_STACK_FRAMES+2)*32);
    set(THREAD,XEL_THREAD_END,SPEC+(XEL_STACK_FRAMES+2)*32);
    reader=(struct xel_reader){.read=read_memory};
    xel_stack_read(&layout,&reader,&context,THREAD,&stack);
    CHECK(stack.count==XEL_STACK_FRAMES && !strcmp(stack.reason,"ElispFrameLimit"));
    CHECK(stack.control_count==1 && stack.controls[0].kind==XEL_HANDLER);
    reader=(struct xel_reader){.read=read_memory};
    xel_bindings_read(&layout,&reader,&context,&stack,0,0,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && bindings.rows[0].value==fixnum(22));
    reader=(struct xel_reader){.read=read_memory};
    xel_bindings_read(&layout,&reader,&context,&stack,XEL_STACK_FRAMES-1,0,&bindings);
    CHECK(!bindings.reason && bindings.count==0);
    /* Unwind storage cannot prevent reading a still-in-budget older frame. */
    bindings_fixture(); frame(0,8,0); set(THREAD,XEL_THREAD_HANDLERS,HANDLER);
    for (size_t i=1;i<=XEL_CONTROL_LIMIT+1;++i) set(SPEC+i*32,XEL_SPEC_KIND,XEL_C_SPECPDL_UNWIND);
    binding(XEL_CONTROL_LIMIT+2,128,fixnum(0));
    set(THREAD,XEL_THREAD_TOP,SPEC+(XEL_CONTROL_LIMIT+3)*32);
    set(THREAD,XEL_THREAD_END,SPEC+(XEL_CONTROL_LIMIT+3)*32);
    reader=(struct xel_reader){.read=read_memory};
    xel_stack_read(&layout,&reader,&context,THREAD,&stack);
    CHECK(stack.count==1 && !strcmp(stack.reason,"ElispControlLimit"));
    CHECK(stack.control_count==XEL_CONTROL_LIMIT+1 && stack.controls[XEL_CONTROL_LIMIT].kind==XEL_HANDLER);
    reader=(struct xel_reader){.read=read_memory};
    xel_bindings_read(&layout,&reader,&context,&stack,0,0,&bindings);
    CHECK(!bindings.reason && bindings.count==1 && bindings.rows[0].value==fixnum(22));
    /* Capped handlers preserve frames, while changed roots still withdraw all. */
    bindings_fixture(); const uint64_t handlers=BASE+0x20000;
    set(THREAD,XEL_THREAD_HANDLERS,handlers);
    for (size_t i=0;i<=XEL_CONTROL_LIMIT;++i) {
        uint64_t at=handlers+i*24;
        set(at,XEL_HANDLER_KIND,XEL_C_CONDITION_CASE);
        set(at,XEL_HANDLER_DEPTH,32);
        set(at,XEL_HANDLER_NEXT,i==XEL_CONTROL_LIMIT?SENTINEL:at+24);
    }
    reader=(struct xel_reader){.read=read_memory};
    xel_stack_read(&layout,&reader,&context,THREAD,&stack);
    CHECK(stack.count==2 && !strcmp(stack.reason,"ElispHandlerLimit"));
    reader=(struct xel_reader){.read=read_memory};
    xel_bindings_read(&layout,&reader,&context,&stack,0,0,&bindings);
    CHECK(!bindings.reason && bindings.rows[0].value==fixnum(22));
    reader=(struct xel_reader){.read=read_memory};top_reads=0;mutate=1;
    xel_stack_read(&layout,&reader,&context,THREAD,&stack);
    CHECK(!strcmp(stack.reason,"ElispStateChanged") && !stack.count && !stack.control_count);
    struct xel_value shown;
    reader=(struct xel_reader){.read=read_memory,.reads=XEL_READ_LIMIT};
    xel_value_read(&layout,&reader,&context,fixnum(1),&shown);
    CHECK(!strcmp(shown.type,"unavailable") && !strcmp(shown.display,"#<ElispReadLimit>"));
}
int main(int argc, char **argv) {
    test_partial_bindings();
    test_bindings(argc > 1 && !strcmp(argv[1], "--wrong-binding-oracle"));
    test_values(argc > 1 && !strcmp(argv[1], "--wrong-value-oracle"));
    test_kinds(argc > 1 && !strcmp(argv[1], "--wrong-kind-oracle"));
    reset(); put(BASE + 0x100, THREAD, 8);
    xel_stack_main(&layout, &reader, &context, BASE + 0x100, THREAD, 100, 100, &stack);
    CHECK(!stack.reason && stack.count == 3);
    reset();
    xel_stack_main(&layout, &reader, &context, BASE + 0x100, THREAD, 100, 101, &stack);
    CHECK(stack.reason && !strcmp(stack.reason, "ElispThreadAssociationUnproved") && callbacks == 0);
    reset(); put(BASE + 0x100, THREAD + 8, 8);
    xel_stack_main(&layout, &reader, &context, BASE + 0x100, THREAD, 100, 100, &stack);
    CHECK(stack.reason && !strcmp(stack.reason, "ElispThreadAssociationUnproved") && stack.count == 0);
    reset(); put(BASE + 0x100, THREAD, 8); mutate_current = 1;
    xel_stack_main(&layout, &reader, &context, BASE + 0x100, THREAD, 100, 100, &stack);
    CHECK(stack.reason && !strcmp(stack.reason, "ElispStateChanged") && stack.count == 0 && stack.control_count == 0);
    reset(); run(NULL);
    CHECK(stack.count == 3 && stack.control_count == 2);
    CHECK(!strcmp(stack.frames[1].name, argc > 1 && !strcmp(argv[1], "--wrong-oracle") ? "wrong" : "demo"));
    CHECK(stack.frames[1].function == UINT64_MAX - 7 && stack.frames[1].nargs == -1);
    CHECK(stack.frames[2].function == 8 && stack.frames[2].nargs == 2);
    CHECK(stack.frames[0].name_reason && !strcmp(stack.frames[0].name_reason, "ElispFunctionNotSymbol"));
    CHECK(!strcmp(stack.frames[0].kind_reason, "ElispFrameKindUnproved"));
    CHECK(stack.controls[0].frame == 1 && stack.controls[1].frame == 1);
    reset(); set(HANDLER, XEL_HANDLER_KIND, 4); set(HANDLER, XEL_HANDLER_DEPTH, UINT64_MAX);
    unreadable = HANDLER + layout.fields[XEL_HANDLER_DEPTH].offset; run(NULL);
    CHECK(stack.controls[1].frame == SIZE_MAX && stack.controls[1].reason);
    reset(); set(HANDLER, XEL_HANDLER_NEXT, HANDLER); run("ElispHandlerCycle");
    reset(); set(HANDLER, XEL_HANDLER_NEXT, 0); run("ElispHandlerAddressInvalid");
    reset(); set(THREAD, XEL_THREAD_SENTINEL, 0); run("ElispHandlerSentinelInvalid");
    reset(); set(HANDLER, XEL_HANDLER_KIND, 6); run("ElispHandlerKindInvalid");
    reset(); set(HANDLER, XEL_HANDLER_DEPTH, 1); run("ElispHandlerDepthInvalid");
    reset(); set(HANDLER, XEL_HANDLER_DEPTH, 9 * 32); run("ElispHandlerDepthInvalid");
    reset(); set(SPEC + 3 * 32, XEL_SPEC_KIND, 255); run("ElispSpecpdlKindInvalid");
    reset(); set(THREAD, XEL_THREAD_TOP, SPEC - 32); run("ElispSpecpdlInvalid");
    reset(); set(THREAD, XEL_THREAD_TOP, SPEC + 1); run("ElispSpecpdlInvalid");
    reset(); set(THREAD, XEL_THREAD_END, SPEC); run("ElispSpecpdlInvalid");
    reset(); set(THREAD, XEL_THREAD_TOP, SPEC + (XEL_SPEC_LIMIT + 1) * 32);
    set(THREAD, XEL_THREAD_END, SPEC + (XEL_SPEC_LIMIT + 1) * 32); run("ElispSpecpdlLimit");
    reset(); frame(3, 3, -2); run("ElispArgumentsInvalid");
    reset(); frame(3, 3, 1048577); run("ElispArgumentsInvalid");
    reset(); set(SPEC + 3 * 32, XEL_SPEC_ARGS, UINT64_MAX - 7);
    set(SPEC + 3 * 32, XEL_SPEC_NARGS, 2); run("ElispArgumentsInvalid");
    reset(); frame(3, 3, 1); set(SPEC + 3 * 32, XEL_SPEC_ARGS, 0); run("ElispArgumentsInvalid");
    reset(); set(STRING, XEL_STRING_BYTES, UINT64_MAX - 1); run(NULL);
    CHECK(stack.frames[1].name_reason == NULL && !strcmp(stack.frames[1].name, "demo"));
    reset(); set(STRING, XEL_STRING_BYTES, UINT64_MAX - 2); run(NULL);
    CHECK(stack.frames[1].name_reason == NULL && !strcmp(stack.frames[1].name, "demo"));
    reset(); set(STRING, XEL_STRING_BYTES, UINT64_MAX - 3); run(NULL);
    CHECK(!strcmp(stack.frames[1].name_reason, "ElispStringHeaderInvalid"));
    reset(); set(STRING, XEL_STRING_BYTES, 3); run(NULL);
    CHECK(!strcmp(stack.frames[1].name_reason, "ElispStringHeaderInvalid"));
    reset(); set(STRING, XEL_STRING_CHARS, UINT64_MAX); run(NULL);
    CHECK(!strcmp(stack.frames[1].name_reason, "ElispStringHeaderInvalid"));
    reset(); set(SYMBOL - 8, XEL_SYMBOL_NAME, 0); run(NULL);
    CHECK(!strcmp(stack.frames[1].name_reason, "ElispSymbolNameInvalid"));
    reset(); set(STRING, XEL_STRING_CHARS, 500); memset(memory + DATA - BASE, 'a', 500); run(NULL);
    CHECK(strlen(stack.frames[1].name) == 191 && !strcmp(stack.frames[1].name_reason, "ElispNameTruncated"));
    reset(); memcpy(memory + DATA - BASE, "\0\\\xc3\xa9", 4); set(STRING, XEL_STRING_BYTES, 4);
    set(STRING, XEL_STRING_CHARS, 3); run(NULL);
    CHECK(!strcmp(stack.frames[1].name, "\\x00\\x5c\\xc3\\xa9"));
    CHECK(!strcmp(stack.frames[1].name_reason, "ElispNameEscapedBytes"));
    reset(); set(STRING, XEL_STRING_CHARS, 0); set(STRING, XEL_STRING_DATA, 0); run(NULL);
    CHECK(stack.frames[1].name[0] == 0);
    reset(); put(BASE, 0, 4); run("ElispTagConstantsMismatch");
    reset(); unreadable = BASE; run("ElispMemoryUnavailable");
    reset(); unreadable = DATA; run("ElispMemoryUnavailable"); CHECK(stack.count == 1);
    reset(); layout.fields[XEL_SPEC_KIND].size = 8; run("ElispLayoutInvalid"); CHECK(callbacks == 0);
    reset(); layout.fields[XEL_SYMBOL_NAME].offset = UINT32_MAX; run("ElispLayoutInvalid");
    reset(); layout.sizes[XEL_T_SPEC] = 0; run("ElispLayoutInvalid");
    reset(); layout.build_id_len = 0; run("ElispLayoutInvalid");
    reset(); reader.reads = XEL_READ_LIMIT;
    xel_stack_read(&layout, &reader, &context, THREAD, &stack);
    CHECK(!strcmp(stack.reason, "ElispReadLimit") && callbacks == 0);
    reset(); reader.bytes = XEL_BYTE_LIMIT;
    xel_stack_read(&layout, &reader, &context, THREAD, &stack);
    CHECK(!strcmp(stack.reason, "ElispReadLimit") && callbacks == 0);
    reset(); reader.error = "PriorFailure"; run("PriorFailure"); CHECK(callbacks == 0);
    reset(); context.lispsym = 8; run("ElispSymbolsUnavailable");
    reset(); mutate = 1; run("ElispStateChanged"); CHECK(stack.count == 0 && stack.control_count == 0);
    reset(); set(THREAD, XEL_THREAD_TOP, SPEC + 129 * 32); set(THREAD, XEL_THREAD_END, SPEC + 129 * 32);
    for (size_t i = 0; i < 129; ++i) frame(i, 3, 0);
    run("ElispFrameLimit"); CHECK(stack.count == 128);
    reset(); set(THREAD, XEL_THREAD_TOP, SPEC + 129 * 32); set(THREAD, XEL_THREAD_END, SPEC + 129 * 32);
    for (size_t i = 0; i < 129; ++i) set(SPEC + i * 32, XEL_SPEC_KIND, 0);
    run("ElispControlLimit"); CHECK(stack.control_count == XEL_CONTROL_LIMIT+1);
    for (size_t i=0;i<XEL_CONTROL_LIMIT;++i) CHECK(stack.controls[i].kind==XEL_UNWIND);
    CHECK(stack.controls[XEL_CONTROL_LIMIT].kind==XEL_HANDLER);
    puts("elisp reader: bounded stack and values, cycles, corrupt memory, changed roots and negative oracles PASS");
    return 0;
}
