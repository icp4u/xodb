#include "../src/language/javascript.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define BASE UINT64_C(0x100000)
static unsigned char memory[65536];
static size_t used = 4096, attempts, fail_at;
static struct xjs_layout layout;
static uint64_t meta;
static int read_fake(void *ctx, uint64_t at, void *out, size_t n) {
    (void)ctx;
    if (++attempts == fail_at || at < BASE || at - BASE > used || n > used - (at - BASE)) return -1;
    memcpy(out, memory + (at - BASE), n); return 0;
}
static void put(uint64_t at, uint64_t bits, size_t n) {
    assert(at >= BASE && at + n <= BASE + sizeof memory);
    for (size_t i = 0; i < n; ++i) memory[at - BASE + i] = (unsigned char)(bits >> (8 * i));
}
static uint64_t alloc(size_t n) {
    uint64_t result = BASE + used; used += (n + 7) & ~(size_t)7;
    assert(used < sizeof memory); return result;
}
static uint64_t object(unsigned type, size_t n) {
    uint64_t map = alloc(80), out = alloc(n + 8);
    put(map, meta + 1, 8); put(map + 12, type, 2); put(out, map + 1, 8);
    /* A following synthetic header for sequential-string extent checks. */
    put(out + ((n + 7) & ~(size_t)7), meta + 1, 8); return out + 1;
}
static uint64_t str(const char *text) {
    size_t n = strlen(text); uint64_t out = object(40, 16 + n);
    put(out - 1 + 12, n, 4); memcpy(memory + (out - 1 + 16 - BASE), text, n); return out;
}
static struct xjs_value decode(uint64_t tagged) {
    struct xjs_reader r = {.read = read_fake}; struct xjs_value v;
    xjs_value_read(&layout, &r, tagged, &v);
    assert(r.reads <= XJS_READ_LIMIT && r.bytes <= XJS_BYTE_LIMIT); return v;
}
static uint64_t tagged_int(int n) { return (uint64_t)(uint32_t)n << 32; }
static uint64_t context_fixture(const char **names, const uint64_t *values, size_t n, uint64_t previous, uint64_t *scope_out) {
    uint64_t scope = object(layout.fields[XJS_TYPE_SCOPE], 48 + n * 16);
    put(scope + 7, 4u | (1u << 31), 4); put(scope + 15, tagged_int(1), 8);
    put(scope + 23, tagged_int((int)n), 8);
    uint64_t context = object(layout.fields[XJS_FIRST_CONTEXT], 32 + n * 8);
    put(context + 7, tagged_int((int)n + 2), 8); put(context + 15, scope, 8); put(context + 23, previous, 8);
    for (size_t i = 0; i < n; ++i) {
        put(scope + 47 + i * 8, str(names[i]), 8);
        put(scope + 47 + (n + i) * 8, tagged_int(65535 << 6), 8);
        put(context + 31 + i * 8, values[i], 8);
    }
    *scope_out = scope; return context;
}
static struct xjs_context_bindings context_decode(const struct xjs_frame *f, size_t start, size_t limit) {
    struct xjs_reader r = {.read = read_fake}; struct xjs_context_bindings out;
    xjs_context_read(&layout, &r, f, start, limit, &out);
    assert(r.reads <= XJS_READ_LIMIT && r.bytes <= XJS_BYTE_LIMIT); return out;
}
static struct xjs_watch_result watch_decode(const struct xjs_frame *f, size_t row,
                                             const struct xjs_watch_result *saved) {
    struct xjs_reader r = {.read = read_fake}; struct xjs_watch_result out;
    xjs_watch_read(&layout, &r, f, row, saved ? &saved->key : NULL, saved ? saved->name : NULL, &out);
    assert(r.reads <= XJS_READ_LIMIT && r.bytes <= XJS_BYTE_LIMIT); return out;
}
static void watch_cases(struct xjs_frame f) {
    put(f.shared + 63, 1234567, 4);
    const char *names[] = {"x"}; uint64_t values[] = {tagged_int(7)}, scope;
    f.context = context_fixture(names, values, 1, 0, &scope);
    put(scope + 31, tagged_int(20), 8); put(scope + 39, tagged_int(80), 8);
    put(f.fp - 8, f.context, 8);
    attempts = 0; struct xjs_watch_result saved = watch_decode(&f, 0, NULL); size_t reads = attempts;
    assert(!saved.reason && saved.key_valid && saved.key.shared_id == 1234567 && !strcmp(saved.name, "x"));
    assert(saved.kind == XJS_WATCH_NUMBER && saved.size == 8 && saved.bytes[6] == 0x1c && saved.bytes[7] == 0x40);
    for (size_t i = 1; i <= reads; ++i) {
        attempts = 0; fail_at = i; struct xjs_watch_result bad = watch_decode(&f, 0, NULL);
        assert(attempts >= i && bad.reason);
    }
    fail_at = 0;
    uint64_t heap_number = object(layout.fields[XJS_TYPE_NUMBER], 16);
    put(heap_number + 7, UINT64_C(0x401c000000000000), 8); put(f.context + 31, heap_number, 8);
    struct xjs_watch_result out = watch_decode(&f, 4095, &saved);
    assert(!out.reason && out.kind == saved.kind && out.size == saved.size && !memcmp(out.bytes, saved.bytes, out.size));
    put(heap_number + 7, UINT64_C(0x8000000000000000), 8); out = watch_decode(&f, 0, &saved);
    assert(!out.reason && out.bytes[7] == 0x80); /* minus zero stays distinct */
    uint64_t cell = object(layout.fields[XJS_TYPE_CONTEXT_CELL], 40);
    put(cell + 23, 2, 4); put(cell + 31, 7, 4); put(f.context + 31, cell, 8);
    out = watch_decode(&f, 0, &saved); assert(!out.reason && !memcmp(out.bytes, saved.bytes, 8));
    put(cell + 23, 3, 4); put(cell + 31, UINT64_C(0x401c000000000000), 8);
    out = watch_decode(&f, 0, &saved); assert(!out.reason && !memcmp(out.bytes, saved.bytes, 8));
    put(cell + 23, 1, 4); put(cell + 7, tagged_int(7), 8);
    out = watch_decode(&f, 0, &saved); assert(!out.reason && !memcmp(out.bytes, saved.bytes, 8));
    /* Full strings, not matching truncated displays, determine equality. */
    uint64_t one = object(40, 16 + 2049), two = object(32, 16 + 4096);
    put(one + 11, 2048, 4); put(two + 11, 2048, 4);
    memset(memory + (one + 15 - BASE), 'q', 2049);
    for (size_t i = 0; i < 2048; ++i) put(two + 15 + i * 2, 'q', 2);
    put(f.context + 31, one, 8); struct xjs_watch_result string_saved = watch_decode(&f, 0, &saved);
    assert(!string_saved.reason && string_saved.kind == XJS_WATCH_STRING && string_saved.size == 4096);
    put(f.context + 31, two, 8); out = watch_decode(&f, 0, &saved);
    assert(!out.reason && !memcmp(out.bytes, string_saved.bytes, 4096));
    put(two + 15 + 2047 * 2, 'z', 2); out = watch_decode(&f, 0, &saved);
    assert(!out.reason && !strcmp(out.display, string_saved.display) && memcmp(out.bytes, string_saved.bytes, 4096));
    put(two + 15, 0, 2); put(two + 17, 0xdc00, 2); out = watch_decode(&f, 0, &saved);
    assert(!out.reason && out.bytes[0] == 0 && out.bytes[1] == 0 && out.bytes[2] == 0 && out.bytes[3] == 0xdc);
    put(one + 11, 2049, 4); put(f.context + 31, one, 8); out = watch_decode(&f, 0, &saved);
    assert(out.reason && !strcmp(out.reason, "JavaScriptWatchStringLimit"));
    /* Empty strings and primitive kinds have complete zero-length samples. */
    put(f.context + 31, str(""), 8); out = watch_decode(&f, 0, &saved);
    assert(!out.reason && out.kind == XJS_WATCH_STRING && out.size == 0);
    const enum xjs_field odd[] = {XJS_FALSE, XJS_TRUE, XJS_NULL, XJS_UNDEFINED};
    for (size_t i = 0; i < sizeof odd / sizeof *odd; ++i) {
        uint64_t value = object(layout.fields[XJS_TYPE_ODDBALL], 48);
        put(value + 39, tagged_int(layout.fields[odd[i]]), 8); put(f.context + 31, value, 8);
        out = watch_decode(&f, 0, &saved); assert(!out.reason && out.kind == XJS_WATCH_FALSE + i && !out.size);
    }
    /* Newly entered inner scope changes flattened ordinals but not the key. */
    uint64_t outer = f.context, inner_scope;
    f.context = context_fixture(names, values, 1, outer, &inner_scope);
    put(inner_scope + 31, tagged_int(30), 8); put(inner_scope + 39, tagged_int(60), 8);
    put(f.fp - 8, f.context, 8); put(outer + 31, tagged_int(9), 8);
    out = watch_decode(&f, 0, &saved); assert(!out.reason && !strcmp(out.display, "smi 9"));
    /* Ambiguous scope coordinates refuse on creation and observation. */
    put(inner_scope + 31, tagged_int(20), 8); put(inner_scope + 39, tagged_int(80), 8);
    out = watch_decode(&f, 0, &saved); assert(out.reason && !strcmp(out.reason, "JavaScriptWatchScopeAmbiguous"));
    out = watch_decode(&f, 0, NULL); assert(out.reason && !strcmp(out.reason, "JavaScriptWatchScopeAmbiguous"));
    out = watch_decode(&f, 1, NULL); assert(out.reason && !strcmp(out.reason, "JavaScriptWatchScopeAmbiguous"));
    f.context = outer; put(f.fp - 8, outer, 8);
    /* Relocate both context and SFI. No old tagged pointer is in the key. */
    uint64_t moved_context = alloc(40), moved_shared = alloc(80);
    memcpy(memory + (moved_context - BASE), memory + (outer - 1 - BASE), 40);
    memcpy(memory + (moved_shared - BASE), memory + (f.shared - 1 - BASE), 80);
    f.context = moved_context + 1; f.shared = moved_shared + 1;
    put(f.fp - 8, f.context, 8); put(f.function + 31, f.shared, 8);
    out = watch_decode(&f, 0, &saved); assert(!out.reason && !strcmp(out.display, "smi 9"));
    put(f.shared + 63, 7654321, 4); out = watch_decode(&f, 0, &saved);
    assert(out.gone && !strcmp(out.reason, "JavaScriptWatchFrameChanged")); put(f.shared + 63, 1234567, 4);
    put(scope + 47, str("renamed"), 8); out = watch_decode(&f, 0, &saved);
    assert(out.gone && !strcmp(out.reason, "JavaScriptWatchBindingChanged")); put(scope + 47, str("x"), 8);
    put(scope + 31, tagged_int(-1), 8); out = watch_decode(&f, 0, &saved);
    assert(out.reason && !out.gone && !strcmp(out.reason, "JavaScriptWatchScopeIdentityUnavailable"));
    put(scope + 31, tagged_int(21), 8); out = watch_decode(&f, 0, &saved);
    assert(out.gone && !strcmp(out.reason, "JavaScriptWatchBindingGone"));
    puts("JavaScript watches: full scalar samples, UTF-16, representation equality, tail changes, scope identity, relocation and read failures passed");
}
static void context_cases(struct xjs_frame f) {
    uint64_t cells[5];
    for (unsigned i = 0; i < 5; ++i) {
        cells[i] = object(layout.fields[XJS_TYPE_CONTEXT_CELL], 40);
        put(cells[i] + 23, i, 4); put(cells[i] + 7, tagged_int(100 + (int)i), 8);
    }
    put(cells[2] + 31, (uint32_t)-104, 4);
    double number = 3.5; uint64_t bits; memcpy(&bits, &number, 8); put(cells[3] + 31, bits, 8);
    const char *outer_names[] = {"constant", "smi_cell", "int_cell", "double_cell", "detached"};
    uint64_t outer_scope, outer = context_fixture(outer_names, cells, 5, 0, &outer_scope);
    const char *names[] = {"p", "captured", "other"};
    uint64_t values[] = {tagged_int(7), tagged_int(41), tagged_int(9)}, scope;
    f.context = context_fixture(names, values, 3, outer, &scope);
    put(scope + 47 + 3 * 8, tagged_int(20), 8); /* context parameter #0 */
    put(f.fp - 8, f.context, 8);
    attempts = 0; struct xjs_context_bindings out = context_decode(&f, 0, 32); size_t reads = attempts;
    assert(!out.reason && out.total == 8 && out.count == 8 && !out.truncated);
    assert(out.items[0].parameter && !strcmp(out.items[0].name, "p") && !strcmp(out.items[0].value.display, "smi 7"));
    assert(!out.items[1].parameter && !strcmp(out.items[1].name, "captured") && !strcmp(out.items[1].value.display, "smi 41"));
    assert(out.items[1].depth == 0 && out.items[1].context == f.context);
    assert(out.items[3].depth == 1 && out.items[3].context == outer);
    assert(!strcmp(out.items[3].value.display, "smi 100") && !strcmp(out.items[4].value.display, "smi 101"));
    assert(!strcmp(out.items[5].value.display, "number -104") && out.items[5].immediate);
    assert(!strcmp(out.items[6].value.display, "number 3.5") && out.items[6].immediate);
    assert(out.items[7].reason && !strcmp(out.items[7].reason, "JavaScriptContextCellStateUnsupported"));
    struct xjs_read_cache cache = {0};
    struct xjs_reader cached_reader = {.read=read_fake, .cache=&cache};
    struct xjs_context_bindings cached;
    xjs_context_read(&layout, &cached_reader, &f, 0, 32, &cached);
    assert(!memcmp(&cached, &out, sizeof out));
    assert(cached_reader.reads < reads && cached_reader.bytes <= XJS_BYTE_LIMIT);
    out = context_decode(&f, 2, 2); assert(out.total == 8 && out.count == 2 && out.truncated);
    assert(out.items[0].ordinal == 2 && out.items[1].ordinal == 3 && !strcmp(out.items[1].name, "constant"));
    out = context_decode(&f, 8, 32); assert(!out.reason && out.total == 8 && !out.count && !out.truncated);
    out = context_decode(&f, 0, 33); assert(out.reason && !out.count);
    for (size_t i = 1; i <= reads; ++i) {
        attempts = 0; fail_at = i; out = context_decode(&f, 0, 32);
        int refused = out.reason != NULL;
        for (size_t j = 0; j < out.count; ++j) if (j != 7) refused |= out.items[j].reason != NULL || out.items[j].name_reason != NULL;
        /* Read failures in the deliberately detached final cell remain visible
         * there too; the callback attempt count proves the injection occurred. */
        if (i > attempts) { fprintf(stderr, "unreached failure %zu/%zu\n", i, attempts); assert(0); }
        if (!refused) assert(out.count == 8 && out.items[7].reason && strcmp(out.items[7].reason, "JavaScriptContextCellStateUnsupported"));
    }
    fail_at = 0;
    put(outer + 23, f.context, 8); out = context_decode(&f, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptContextCycle")); put(outer + 23, 0, 8);
    put(scope + 23, tagged_int(4000), 8); out = context_decode(&f, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptContextSlotLimit")); put(scope + 23, tagged_int(3), 8);
    put(scope + 7, 8, 4); out = context_decode(&f, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptDynamicContextUnsupported")); put(scope + 7, 4u | (1u << 31), 4);
    put(scope + 47 + 3 * 8, tagged_int(1 << 6), 8); out = context_decode(&f, 0, 32);
    assert(out.items[0].reason && !strcmp(out.items[0].reason, "JavaScriptContextParameterInvalid")); put(scope + 47 + 3 * 8, tagged_int(20), 8);
    put(outer_scope + 7, 4, 4); out = context_decode(&f, 0, 32);
    assert(out.items[3].reason && !strcmp(out.items[3].reason, "JavaScriptUnexpectedContextCell")); put(outer_scope + 7, 4u | (1u << 31), 4);
    put(scope + 23, tagged_int(75), 8); put(f.context + 7, tagged_int(77), 8);
    out = context_decode(&f, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptContextNameTableUnsupported"));
    put(scope + 23, tagged_int(3), 8); put(f.context + 7, tagged_int(5), 8);
    put(scope + 47 + 3 * 8, tagged_int(-1), 8); out = context_decode(&f, 0, 32);
    assert(out.items[0].reason && !strcmp(out.items[0].reason, "JavaScriptContextPropertiesInvalid"));
    assert(!out.items[1].reason && !strcmp(out.items[1].value.display, "smi 41"));
    put(scope + 47 + 3 * 8, tagged_int(20), 8);
    uint64_t saved_name; memcpy(&saved_name, memory + (scope + 47 - BASE), 8);
    put(scope + 47, 0, 8); out = context_decode(&f, 0, 32);
    assert(out.items[0].name_reason && !out.items[1].reason);
    put(scope + 47, saved_name, 8);
    /* Deterministic bounded corruption, preserving the original valid stop
     * between cases. The reader must never escape its callback/read budgets. */
    uint32_t seed = 0x174531;
    for (size_t i = 0; i < 2048; ++i) {
        seed = (uint32_t)((uint64_t)seed * 1664525u + 1013904223u);
        size_t at = seed % (used - 8); unsigned char saved[8];
        memcpy(saved, memory + at, 8);
        seed = (uint32_t)((uint64_t)seed * 1664525u + 1013904223u);
        put(BASE + at, ((uint64_t)seed << 32) | ~seed, 8);
        out = context_decode(&f, i % 40, 1 + i % XJS_CONTEXT_PAGE);
        assert(out.count <= XJS_CONTEXT_PAGE && out.total <= XJS_CONTEXT_BINDINGS);
        memcpy(memory + at, saved, 8);
    }
    struct xjs_frame wrong = f; wrong.function += 8; out = context_decode(&wrong, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptStaleContextFrame"));
    wrong = f; strcpy(wrong.kind, "maglev"); out = context_decode(&wrong, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptContextFrameUnproved"));
    layout.present[XJS_TYPE_CONTEXT_CELL] = 0; out = context_decode(&f, 0, 32);
    assert(out.reason && !strcmp(out.reason, "JavaScriptContextCellMetadataUnavailable")); layout.present[XJS_TYPE_CONTEXT_CELL] = 1;
    struct xjs_reader budget = {.read=read_fake, .bytes=XJS_BYTE_LIMIT}; xjs_context_read(&layout, &budget, &f, 0, 32, &out);
    assert(out.reason && !strcmp(out.reason, "JavaScriptReadBudget"));
    puts("JavaScript context storage: parameters, names, cells, pages, identity, cycles, bounds and every-read refusal passed");
}
static void cache_cases(void) {
    struct xjs_read_cache cache = {0};
    struct xjs_reader r = {.read=read_fake, .cache=&cache};
    uint64_t address = BASE + 128, first = 0, second = 0;
    put(address, 123, 8); attempts=0; fail_at=0;
    assert(xjs_read_memory(&r,address,&first,8) && first==123 && attempts==1);
    assert(xjs_read_memory(&r,address,&second,8) && second==123 && attempts==1);
    assert(r.reads==1 && r.bytes==XJS_CACHE_BLOCK);
    /* Cache lifetime is one inspection. A new read after target changes uses
     * a newly zeroed cache and must see the new data. */
    put(address,456,8); memset(&cache,0,sizeof cache);
    r=(struct xjs_reader){.read=read_fake,.cache=&cache};
    assert(xjs_read_memory(&r,address,&first,8) && first==456);
    /* Failed speculation must not create a false unreadable result or expose
     * partially filled cache data; the mandatory exact read still succeeds. */
    memset(&cache,0,sizeof cache); attempts=0; fail_at=1;
    r=(struct xjs_reader){.read=read_fake,.cache=&cache};
    assert(xjs_read_memory(&r,address,&first,8) && first==456 && attempts==2);
    assert(r.reads==2 && r.bytes==XJS_CACHE_BLOCK+8);
    fail_at=0; memset(&cache,0,sizeof cache);
    r=(struct xjs_reader){.read=read_fake,.cache=&cache};
    assert(!xjs_read_memory(&r,BASE+used+512,&first,8));
    assert(!strcmp(r.error,"JavaScriptMemoryUnavailable") && r.reads==2);
    memset(&cache,0,sizeof cache); attempts=0;
    r=(struct xjs_reader){.read=read_fake,.cache=&cache,.reads=XJS_READ_LIMIT-1,.bytes=XJS_BYTE_LIMIT-8};
    assert(xjs_read_memory(&r,address,&first,8) && attempts==1 && first==456);
    assert(r.reads==XJS_READ_LIMIT && r.bytes==XJS_BYTE_LIMIT);
    assert(!xjs_read_memory(&r,address,&second,8) && !strcmp(r.error,"JavaScriptReadBudget"));
    put(address,0,8);
    puts("JavaScript read batching: cache equivalence, operation lifetime, exact fallback, unreadable data and charged budgets passed");
}
static void stack_cases(uint64_t function, uint64_t shared) {
    const uint8_t stock_id[] = {0x93,0xf8,0x2a,0xf1,0xea,0xc2,0x4f,0xf5,0x12,0x35,
        0x95,0xe6,0x66,0x95,0x72,0xc9,0x34,0x21,0xc4,0x36};
    layout.build_id_len = sizeof stock_id; memcpy(layout.build_id, stock_id, sizeof stock_id);
    uint64_t script = object(layout.fields[XJS_TYPE_SCRIPT], 80);
    put(script + 7, str("function named() {\n  probe();\n}\n"), 8);
    put(script + 15, str("synthetic.js"), 8); put(shared + 39, script, 8);
    uint64_t bytecode = object(layout.fields[XJS_TYPE_BYTECODE], 164);
    put(bytecode + 7, UINT64_C(100) << 32, 8); put(shared + 7, bytecode, 8);
    uint64_t table = object(layout.fields[XJS_TYPE_TRUSTED_BYTES], 24);
    put(table + 7, UINT64_C(2) << 32, 8); put(table + 15, 4, 1); put(table + 16, 88, 1);
    put(bytecode + 23, table, 8);
    uint64_t code = object(layout.fields[XJS_TYPE_CODE], 96);
    put(code + 39, 0x800000, 8); put(code + 51, 3, 4); put(code + 55, 100, 4); put(code + 89, 83, 2);
    uint64_t dispatch = (alloc(48) + 15) & ~UINT64_C(15), root = alloc(800) + 128;
    put(root - 128 + 616, dispatch, 8); put(function + 23, 256, 4);
    put(dispatch + 24, ((code - 1) << 16), 8);
    uint64_t stack = alloc(320), api_fp = stack + 64, js_fp = stack + 160, entry_fp = stack + 240;
    put(api_fp - 8, (uint64_t)layout.fields[XJS_FRAME_API_EXIT] * 2, 8);
    put(api_fp, js_fp, 8); put(api_fp + 8, 0x800014, 8);
    put(js_fp - 8, object(layout.fields[XJS_FIRST_CONTEXT], 24), 8);
    put(js_fp - 16, function, 8); put(js_fp - 32, bytecode, 8); put(js_fp - 40, UINT64_C(64) << 32, 8);
    put(js_fp, entry_fp, 8); put(js_fp + 8, 0x800015, 8);
    put(entry_fp - 8, (uint64_t)layout.fields[XJS_FRAME_ENTRY] * 2, 8);
    struct xjs_reader r = {.read = read_fake}; struct xjs_stack out;
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    if (out.count != 1 || out.frames[0].reason) fprintf(stderr, "stack: %zu %s; frame: %s\n", out.count,
        out.reason ? out.reason : "none", out.frames[0].reason ? out.frames[0].reason : "none");
    assert(out.count == 1 && out.frames[0].reason == NULL);
    assert(!strcmp(out.frames[0].name, "named") && !strcmp(out.frames[0].file, "synthetic.js"));
    if (out.frames[0].line != 2 || out.frames[0].column != 3) fprintf(stderr, "position: %d:%d\n", out.frames[0].line, out.frames[0].column);
    assert(out.frames[0].line == 2 && out.frames[0].column == 3);
    assert(!strcmp(out.reason, "JavaScriptEntryBoundary"));
    context_cases(out.frames[0]);
    watch_cases(out.frames[0]);
    cache_cases();
    const struct { const char *source; unsigned position; int line, column; } newline_cases[] = {
        {"a\r\nb", 2, 1, 3}, {"a\r\nb", 3, 2, 1}, {"a\rb", 2, 2, 1},
        {"a\nb", 2, 2, 1}, {"a\r\r\nb", 4, 3, 1}
    };
    for (size_t i = 0; i < sizeof newline_cases / sizeof *newline_cases; ++i) {
        put(script + 7, str(newline_cases[i].source), 8);
        put(table + 16, (newline_cases[i].position + 1) * 4, 1);
        r = (struct xjs_reader){.read = read_fake};
        xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
        assert(out.count == 1 && !out.frames[0].reason);
        assert(out.frames[0].line == newline_cases[i].line && out.frames[0].column == newline_cases[i].column);
    }
    layout.build_id[0] ^= 1; r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(out.count == 1 && !out.frames[0].line && !strcmp(out.frames[0].reason, "JavaScriptFrameConfigUnavailable"));
    layout.build_id[0] ^= 1;
    /* The second verified stock image is accepted exactly; one changed byte
     * or a truncated id refuses. */
    const uint8_t stock_2610[] = {0x83,0xdb,0x74,0x69,0x59,0xb3,0x36,0xee,0x59,0xd2,
        0xf5,0x17,0xb4,0x83,0x78,0xda,0x2b,0xbe,0xfa,0x4f};
    memcpy(layout.build_id, stock_2610, sizeof stock_2610); r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(out.count == 1 && !out.frames[0].reason && out.frames[0].line == 3 && out.frames[0].column == 1);
    layout.build_id[19] ^= 1; r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(out.count == 1 && !out.frames[0].line && !strcmp(out.frames[0].reason, "JavaScriptFrameConfigUnavailable"));
    layout.build_id[19] ^= 1; layout.build_id_len = 19; r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(out.count == 1 && !out.frames[0].line && !strcmp(out.frames[0].reason, "JavaScriptFrameConfigUnavailable"));
    layout.build_id_len = sizeof stock_id; memcpy(layout.build_id, stock_id, sizeof stock_id);
    put(table + 15, 0x80, 1); put(table + 16, 0x80, 1); r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(out.count == 1 && !out.frames[0].line && !strcmp(out.frames[0].reason, "JavaScriptSourceTableMalformed"));
    put(api_fp, api_fp, 8); r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(!strcmp(out.reason, "JavaScriptStackLinkInvalid"));
    put(api_fp - 8, 0, 8); r = (struct xjs_reader){.read = read_fake};
    xjs_stack_read(&layout, &r, api_fp, 0x800010, root, stack, stack + 320, &out);
    assert(!strcmp(out.reason, "JavaScriptNativeAnchorUnavailable"));
    layout.build_id_len = 4; memcpy(layout.build_id, "test", 4);
}
int main(void) {
#define META(key, value) layout.present[XJS_##key] = 1; layout.fields[XJS_##key] = value;
#include "fixtures/javascript/metadata.inc"
#undef META
    uint32_t version[] = {14, 6, 202, 34};
    memcpy(layout.version, version, sizeof version); layout.build_id_len = 4; memcpy(layout.build_id, "test", 4);
    strcpy(layout.version_string, "14.6.202.34-node.28");
    assert(!xjs_layout_check(&layout, (const uint8_t *)"test", 4, version));
    assert(!strcmp(xjs_layout_check(&layout, (const uint8_t *)"fail", 4, version), "JavaScriptBuildIdMismatch"));
    version[0]++; assert(xjs_layout_check(&layout, (const uint8_t *)"test", 4, version)); version[0]--;
    layout.fields[XJS_TAGGED_SIZE] = 4; assert(xjs_layout_check(&layout, (const uint8_t *)"test", 4, version)); layout.fields[XJS_TAGGED_SIZE] = 8;
    meta = alloc(80); put(meta, meta + 1, 8); put(meta + 12, layout.fields[XJS_TYPE_MAP], 2);
    struct xjs_value v = decode(UINT64_C(42) << 32); assert(!v.reason && !strcmp(v.display, "smi 42"));
    v = decode((uint64_t)(uint32_t)-7 << 32); assert(!v.reason && !strcmp(v.display, "smi -7"));
    v = decode(6); assert(v.reason && !strcmp(v.reason, "JavaScriptInvalidSmi"));
    uint64_t number = object(layout.fields[XJS_TYPE_NUMBER], 16), bits; double d = 3.25; memcpy(&bits, &d, 8); put(number + 7, bits, 8);
    v = decode(number); assert(!v.reason && !strcmp(v.display, "number 3.25"));
    uint64_t undef = object(layout.fields[XJS_TYPE_ODDBALL], 48); put(undef + 39, UINT64_C(4) << 32, 8);
    v = decode(undef); assert(!v.reason && !strcmp(v.display, "undefined"));
    uint64_t a = str("hi"); v = decode(a); assert(!v.reason && !strcmp(v.display, "string \"hi\""));
    put(a - 1 + 24, 0, 8); v = decode(a);
    assert(v.reason && !strcmp(v.reason, "JavaScriptStringExtentUnproved"));
    assert(!strcmp(v.display, "string \"hi\""));
    put(a - 1 + 24, meta + 1, 8);
    uint64_t b = str(" there"), cons = object(41, 32); put(cons + 11, 8, 4); put(cons + 15, a, 8); put(cons + 23, b, 8);
    v = decode(cons); assert(!v.reason && !strcmp(v.display, "string \"hi there\""));
    uint64_t sliced = object(43, 32); put(sliced + 11, 5, 4); put(sliced + 15, cons, 8); put(sliced + 23, UINT64_C(3) << 32, 8);
    v = decode(sliced); assert(!v.reason && !strcmp(v.display, "string \"there\""));
    uint64_t thin = object(45, 24); put(thin + 11, 5, 4); put(thin + 15, sliced, 8);
    v = decode(thin); assert(!v.reason && !strcmp(v.display, "string \"there\""));
    uint64_t two = object(32, 24); put(two + 11, 4, 4); put(two + 15, 0x202e, 2); put(two + 17, 0xd83d, 2); put(two + 19, 0xde00, 2); put(two + 21, 0xdc00, 2);
    v = decode(two); assert(!v.reason && !strcmp(v.display, "string \"\\u202e😀\\udc00\""));
    uint64_t longstr = object(40, 528); put(longstr + 11, 512, 4); memset(memory + (longstr + 15 - BASE), 'x', 512);
    v = decode(longstr); assert(!v.reason && v.truncated && v.count == 512);
    put(longstr + 11, 100000, 4); v = decode(longstr);
    assert(v.reason && !strcmp(v.reason, "JavaScriptStringExtentUnproved"));
    assert(v.truncated && v.count == 100000 && !strncmp(v.display, "string \"xxxxxxxx", 16));
    put(longstr + 11, 512, 4);
    uint64_t external = object(42, 32), data = alloc(8);
    memcpy(memory + (data - BASE), "external", 8);
    put(external + 11, 8, 4); put(external + 23, data, 8);
    v = decode(external); assert(!v.reason && v.version_table && !strcmp(v.display, "string \"external\""));
    uint64_t elements = object(layout.fields[XJS_TYPE_FIXED], 40);
    put(elements + 7, UINT64_C(3) << 32, 8); put(elements + 15, UINT64_C(42) << 32, 8);
    put(elements + 23, b, 8); put(elements + 31, undef, 8);
    uint64_t array = object(layout.fields[XJS_TYPE_ARRAY], 32);
    put(array + 15, elements, 8); put(array + 23, UINT64_C(3) << 32, 8);
    v = decode(array); assert(!v.reason && v.version_table && v.count == 3 && v.item_count == 3);
    assert(!strcmp(v.display, "Array(3) [smi 42, string \" there\", undefined]"));
    /* A wide UTF-8 preview must retain both its extent advisory and its
     * independent truncation marker when copied into the smaller item. */
    uint64_t wide = object(32, 272);
    put(wide + 11, 128, 4);
    for (size_t i = 0; i < 128; ++i) put(wide + 15 + i * 2, 0x03bb, 2);
    put(wide - 1 + 272, 0, 8);
    put(elements + 23, wide, 8); v = decode(array);
    assert(v.items[1].reason && !strcmp(v.items[1].reason, "JavaScriptStringExtentUnproved"));
    assert(v.items[1].truncated);
    assert(v.extent_advisory && v.items[1].extent_advisory && !v.items[0].extent_advisory);
    size_t preview = strlen(v.items[1].display);
    assert(preview < sizeof v.items[1].display && !strcmp(v.items[1].display + preview - 3, "..."));
    assert((preview - 3 - strlen("string \"")) % 2 == 0);
    assert(!v.items[0].truncated && !strcmp(v.items[0].display, "smi 42"));
    put(elements + 23, b, 8);
    layout.version_string[0] = '2'; v = decode(array);
    assert(v.reason && !strcmp(v.reason, "JavaScriptSupplementVersionUnsupported")); layout.version_string[0] = '1';
    /* Only the listed embedder patch levels are accepted: no prefix, range
     * or nearest match. */
    strcpy(layout.version_string, "14.6.202.34-node.34"); v = decode(array);
    assert(!v.reason && v.version_table);
    const char *const unlisted[] = {"14.6.202.34-node.29", "14.6.202.34-node.33", "14.6.202.34-node.35",
        "14.6.202.34-node.3", "14.6.202.34-node.340", "14.6.202.34-node.2", "14.6.202.34-node.288",
        "14.6.202.34", "14.6.202.34-node.", ""};
    for (size_t i = 0; i < sizeof unlisted / sizeof *unlisted; ++i) {
        strcpy(layout.version_string, unlisted[i]); v = decode(array);
        assert(v.reason && !strcmp(v.reason, "JavaScriptSupplementVersionUnsupported"));
    }
    strcpy(layout.version_string, "14.6.202.34-node.28");
    layout.fields[XJS_CODE_WRAPPER] += 8; v = decode(array);
    assert(v.reason && !strcmp(v.reason, "JavaScriptSupplementMetadataMismatch")); layout.fields[XJS_CODE_WRAPPER] -= 8;
    put(array + 23, UINT64_C(4) << 32, 8); v = decode(array);
    assert(v.reason && !strcmp(v.reason, "JavaScriptArrayCapacityMismatch")); put(array + 23, UINT64_C(3) << 32, 8);
    /* A real function name comes from its shared info, including ScopeInfo's
     * optional name field after inline local names and local info words. */
    uint64_t name = str("named"), shared = object(layout.fields[XJS_TYPE_SHARED], 64);
    put(shared + 23, name, 8);
    uint64_t function = object(layout.fields[XJS_FIRST_FUNCTION], 64); put(function + 31, shared, 8);
    v = decode(function); assert(!v.reason && !strcmp(v.display, "function named"));
    uint64_t scope = object(layout.fields[XJS_TYPE_SCOPE], 88);
    put(scope + 7, 1u << 12, 4); put(scope + 23, UINT64_C(1) << 32, 8); put(scope + 63, name, 8);
    put(shared + 23, scope, 8); v = decode(function);
    assert(!v.reason && v.version_table && !strcmp(v.display, "function named"));
    uint64_t obj = object(layout.fields[XJS_TYPE_OBJECT], 32), map = 0;
    memcpy(&map, memory + (obj - 1 - BASE), 8);
    put(map + 7, 4, 1); put(map + 8, 3, 1); put(map + 15, 1u << layout.fields[XJS_OWN_SHIFT], 4);
    put(map + 31, function, 8); put(obj + 23, UINT64_C(42) << 32, 8);
    put(function + 55, map, 8);
    uint64_t descriptors = object(layout.fields[XJS_TYPE_DESCRIPTORS], 56);
    put(map + 39, descriptors, 8); put(descriptors + 31, name, 8); put(descriptors + 39, 0, 8);
    uint64_t changed_map = alloc(80);
    memcpy(memory + (changed_map - BASE), memory + (map - 1 - BASE), 80);
    put(changed_map + 32, map, 8); put(changed_map + 24, undef, 8);
    put(obj - 1, changed_map + 1, 8); v = decode(obj);
    assert(v.reason && !strcmp(v.reason, "JavaScriptConstructorNameUnproved"));
    assert(!strcmp(v.type, "Object") && v.item_count == 1);
    // An Object literal has a copied initial map, not a constructor backpointer.
    put(changed_map + 32, function, 8); put(changed_map + 24, 0, 8);
    put(shared + 23, str("Object"), 8); v = decode(obj);
    assert(!v.reason && !strcmp(v.type, "Object") && v.item_count == 1);
    put(shared + 23, scope, 8); put(obj - 1, map, 8);
    v = decode(obj); assert(!v.reason && !strcmp(v.display, "named {named: smi 42}"));
    put(function + 55, meta + 1, 8); v = decode(obj);
    assert(v.reason && !strcmp(v.reason, "JavaScriptConstructorNameUnproved"));
    assert(!strcmp(v.type, "Object") && v.item_count == 1);
    put(descriptors + 39, (uint64_t)layout.fields[XJS_PROP_DOUBLE] << (layout.fields[XJS_PROP_REPR_SHIFT] + 32), 8);
    v = decode(obj);
    assert(v.name_reason && !strcmp(v.name_reason, "JavaScriptConstructorNameUnproved"));
    assert(v.reason && !strcmp(v.reason, "JavaScriptDoubleFieldUnsupported"));
    assert(v.items[0].reason && !strcmp(v.items[0].reason, "JavaScriptDoubleFieldUnsupported"));
    put(descriptors + 39, 0, 8);
    put(function + 55, map, 8);
    uint64_t unsupported = object(65000, 24);
    put(elements + 23, unsupported, 8); v = decode(array);
    assert(strcmp(v.type, "unavailable") && v.item_count == 3);
    assert(v.items[1].reason && !strcmp(v.items[1].reason, "JavaScriptObjectLayoutUnavailable"));
    assert(!strcmp(v.items[0].display, "smi 42") && !strcmp(v.items[2].display, "undefined"));
    uint64_t element_map;
    memcpy(&element_map, memory + (elements - 1 - BASE), 8);
    put(element_map + 11, layout.fields[XJS_TYPE_DOUBLE_ARRAY], 2);
    put(elements + 15, UINT64_C(0x7ff8000000000000), 8);
    put(elements + 23, UINT64_C(0xfff7fffffff7ffff), 8);
    put(elements + 31, UINT64_C(0xfff6fffffff6ffff), 8);
    v = decode(array);
    assert(v.item_count == 3 && !strcmp(v.items[0].display, "number NaN"));
    assert(!strcmp(v.items[1].display, "<hole>"));
    assert(v.items[2].reason && !strcmp(v.items[2].reason, "JavaScriptDoubleEncodingUnproved"));
    for (int bad = -1; bad <= 64; bad += 65) {
        int old = layout.fields[XJS_OWN_SHIFT]; layout.fields[XJS_OWN_SHIFT] = bad;
        assert(xjs_layout_check(&layout, (const uint8_t *)"test", 4, version));
        v = decode(obj); assert(v.reason); layout.fields[XJS_OWN_SHIFT] = old;
    }
    stack_cases(function, shared);
    /* Every read failure must remain visible, never a successful partial value. */
    attempts = 0; v = decode(thin); assert(!v.reason); size_t reads = attempts;
    for (size_t i = 1; i <= reads; ++i) { attempts = 0; fail_at = i; v = decode(thin); assert(v.reason); }
    fail_at = 0;
    put(thin + 15, thin, 8); v = decode(thin); assert(v.reason && !strcmp(v.reason, "JavaScriptStringDepthLimit"));
    put(sliced + 23, UINT64_C(100) << 32, 8); v = decode(sliced); assert(v.reason && !strcmp(v.reason, "JavaScriptStringRangeInvalid"));
    put(cons + 11, 7, 4); v = decode(cons); assert(v.reason && !strcmp(v.reason, "JavaScriptStringRangeInvalid"));
    put(a - 1, 1, 8); v = decode(a); assert(v.reason && !strcmp(v.reason, "JavaScriptInvalidMap"));
    /* A synthetic optional metadata entry; the installed runtime does not
     * export this type, so its absence must not imply a guessed type number. */
    layout.present[XJS_TYPE_FREE] = 1; layout.fields[XJS_TYPE_FREE] = 60000;
    uint64_t freed = object(layout.fields[XJS_TYPE_FREE], 24); v = decode(freed); assert(v.reason && !strcmp(v.reason, "JavaScriptFreedOrFillerObject"));
    uint64_t truncated = object(40, 16); put(truncated + 11, 100, 4);
    v = decode(truncated); assert(v.reason && !strcmp(v.reason, "JavaScriptMemoryUnavailable"));
    struct xjs_reader r = {.read = read_fake, .bytes = XJS_BYTE_LIMIT}; xjs_value_read(&layout, &r, number, &v);
    assert(v.reason && !strcmp(v.reason, "JavaScriptReadBudget"));
    puts("JavaScript reader: scalar/string variants, exact identity, corruption, cycles and every-read failure passed");
}
