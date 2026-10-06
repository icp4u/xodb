#include "../src/language/perl.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* An owned synthetic address space; invalid addresses never reach a real
 * pointer. Offsets intentionally differ from a real interpreter layout. */
static unsigned char memory[512 * 1024];
static size_t attempts, fail_at;
static int read_fake(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    if (++attempts == fail_at || address < 0x1000 || address - 0x1000 > sizeof memory ||
        n > sizeof memory - (size_t)(address - 0x1000))
        return -1;
    memcpy(out, memory + (size_t)(address - 0x1000), n);
    return 0;
}
static void put(uint64_t address, uint64_t value, size_t n) {
    assert(address >= 0x1000 && address + n <= 0x1000 + sizeof memory);
    for (size_t i = 0; i < n; ++i)
        memory[address - 0x1000 + i] = (unsigned char)(value >> (i * 8));
}
static void str(uint64_t address, const char *value) {
    size_t n = strlen(value) + 1;
    assert(address >= 0x1000 && address + n <= 0x1000 + sizeof memory);
    memcpy(memory + address - 0x1000, value, n);
}
static struct xpl_reader reader(void) {
    attempts = 0;
    return (struct xpl_reader){.read = read_fake};
}
static struct xpl_layout layout(void) {
    struct xpl_layout l = {.context_size = 64, .build_id = {1, 2, 3}, .build_id_len = 3, .version = {5, 44, 0}};
    for (unsigned i = 0; i < XPL_FIELD_COUNT; ++i)
        l.fields[i] = (struct xpl_field_info){.offset = i * 8, .size = 8};
    l.fields[XPL_ANY] = (struct xpl_field_info){0, 8};
    l.fields[XPL_REFCNT] = (struct xpl_field_info){8, 4};
    l.fields[XPL_FLAGS] = (struct xpl_field_info){12, 4};
    l.fields[XPL_UNION] = (struct xpl_field_info){16, 8};
    l.fields[XPL_CXTYPE] = (struct xpl_field_info){0, 1};
    l.fields[XPL_OLDCOP] = (struct xpl_field_info){8, 8};
    l.fields[XPL_SUBCV] = (struct xpl_field_info){16, 8};
    l.fields[XPL_EVALCV] = (struct xpl_field_info){24, 8};
    l.fields[XPL_EVALOP] = (struct xpl_field_info){2, 2};
    l.fields[XPL_CXIX].size = l.fields[XPL_CXMAX].size = 4;
    l.fields[XPL_COPLINE].size = 4;
    l.fields[XPL_CVFLAGS].size = 4;
    l.fields[XPL_HEKLEN] = (struct xpl_field_info){0, 4};
    l.fields[XPL_HEKKEY] = (struct xpl_field_info){4, 1};
    return l;
}
static void field(struct xpl_layout *l, uint64_t address, enum xpl_field f, uint64_t value) {
    put(address + l->fields[f].offset, value, l->fields[f].size);
}
static void sv(uint64_t address, uint32_t flags, uint64_t body, uint64_t value) {
    put(address, body, 8);
    put(address + 8, 1, 4);
    put(address + 12, flags, 4);
    put(address + 16, value, 8);
}
static void values(struct xpl_layout *l) {
    struct xpl_value v;
    struct xpl_reader r = reader();
    sv(0x1100, 0, 0, 0xfeedface);
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !strcmp(v.display, "undef") && !strcmp(v.type, "undef"));
    sv(0x1100, 0x101, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !strcmp(v.display, "IV 42") && v.refcount == 1);
    sv(0x1100, 0x00200101u, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(v.stored_value_only && !strcmp(v.display, "IV 42") && !strcmp(v.reason, "StoredValueOnlyMagicNotInvoked"));
    sv(0x1100, 16, 0x2000, 0);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.type, "unsupported") && !strcmp(v.reason, "SvTypeUnsupported"));
    sv(0x1100, 0x80000101u, 0, UINT64_MAX);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !strcmp(v.display, "UV 18446744073709551615"));
    sv(0x1100, 0x100, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(v.reason && !strcmp(v.reason, "InconsistentSv"));
    sv(0x1100, 255, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "FreedSv"));
    sv(0x1100, 0x101, 0, 42);
    put(0x1108, 0, 4);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "ZeroRefcount"));
    sv(0x1100, 0x403, 0x2000, 0x3000);
    field(l, 0x2000, XPL_PVCUR, 4);
    field(l, 0x2000, XPL_PVLEN, 8);
    memory[0x3000 - 0x1000] = 'a';
    memory[0x3001 - 0x1000] = 0;
    memory[0x3002 - 0x1000] = 0xff;
    memory[0x3003 - 0x1000] = 'b';
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && v.byte_count == 4 && v.bytes[2] == 255 && strstr(v.display, "\\x00"));
    put(0x1100 + 12, 0x20000403u, 4);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(v.utf8 && !v.stored_value_only && !v.reason);
    field(l, 0x2000, XPL_PVLEN, 2);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "InconsistentSv"));
    sv(0x1100, 0x202, 0x2000, 0);
    double n = 3.25;
    uint64_t bits;
    memcpy(&bits, &n, 8);
    field(l, 0x2000, XPL_NV, bits);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !strcmp(v.display, "NV 3.25"));
    sv(0x1100, 11, 0x2000, 0x3000);
    field(l, 0x2000, XPL_AVFILL, 10);
    field(l, 0x2000, XPL_AVMAX, 12);
    for (unsigned i = 0; i < 11; ++i)
        put(0x3000 + i * 8, 0, 8);
    sv(0x3100, 0x101, 0, 42);
    put(0x3000 + 3 * 8, 0x3100, 8);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && v.count == 11 && v.item_count == 8 && v.truncated && !strcmp(v.items[3].display, "IV 42"));
    field(l, 0x2000, XPL_AVMAX, 2);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "InconsistentSv"));
    sv(0x1100, 0x801, 0, 0x1100);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && v.item_count == 1 && r.reads < 20);
    sv(0x1100, 0x101, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    size_t complete = attempts;
    for (size_t i = 1; i <= complete; ++i) {
        fail_at = i;
        r = reader();
        xpl_value_read(l, &r, 0x1100, &v);
        assert(v.reason);
    }
    fail_at = 0;
}
static void malformed_values(struct xpl_layout *l) {
    struct xpl_value v;
    struct xpl_reader r;
    /* An IV cannot advertise a public NV slot, even if its IV is valid. */
    sv(0x1100, 0x301, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(v.reason && !strcmp(v.reason, "InconsistentSv"));
    sv(0x1100, 0x403, 0x2000, 0x3000);
    field(l, 0x2000, XPL_PVCUR, 128);
    field(l, 0x2000, XPL_PVLEN, 129);
    memset(memory + 0x3000 - 0x1000, 0xff, 128);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && v.byte_count == 128 && v.truncated && strstr(v.display, "..."));
    /* A cycle must not manufacture repeated hash entries. */
    memset(memory, 0, sizeof memory);
    sv(0x1100, 12, 0x2000, 0x3000);
    field(l, 0x2000, XPL_HVKEYS, 2);
    field(l, 0x2000, XPL_HVMAX, 7);
    put(0x3000, 0x4000, 8);
    field(l, 0x4000, XPL_HEKEY, 0x5000);
    field(l, 0x4000, XPL_HEVAL, 0x6000);
    field(l, 0x4000, XPL_HENEXT, 0x4000);
    put(0x5000, 3, 4);
    str(0x5004, "key");
    sv(0x6000, 0x101, 0, 42);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(v.reason && !strcmp(v.reason, "HashEntryCycle") && v.item_count == 1);
    assert(!strcmp(v.items[0].key, "key") && !strcmp(v.items[0].display, "IV 42"));
    field(l, 0x4000, XPL_HENEXT, 0);
    field(l, 0x2000, XPL_HVKEYS, 1);
    r = reader();
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !v.truncated && v.item_count == 1);
    size_t complete = attempts;
    for (size_t i = 1; i <= complete; ++i) {
        fail_at = i;
        r = reader();
        xpl_value_read(l, &r, 0x1100, &v);
        assert(v.reason);
    }
    fail_at = 0;
    r = reader();
    r.bytes = SIZE_MAX;
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "PerlReadLimit") && attempts == 0);
    r = reader();
    r.reads = 8192;
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "PerlReadLimit") && attempts == 0);
}
static void stacks(struct xpl_layout *l) {
    memset(memory, 0, sizeof memory);
    const uint64_t interp = 0x1100, si = 0x2000, array = 0x3000, cv = 0x4000, body = 0x5000, cop = 0x6000;
    field(l, interp, XPL_CURCOP, cop);
    field(l, interp, XPL_STACKINFO, si);
    field(l, interp, XPL_MAINCV, cv);
    field(l, si, XPL_CXSTACK, array);
    field(l, si, XPL_CXIX, 4);
    field(l, si, XPL_CXMAX, 4);
    field(l, cop, XPL_COPLINE, 7);
    field(l, cop, XPL_COPFILE, 0x6800);
    str(0x6800, "fixture.pl");
    sv(cv, 13, body, 0);
    field(l, body, XPL_CVNAME, 0x7000);
    field(l, body, XPL_CVFLAGS, 0x8000);
    put(0x7000, 10, 4);
    str(0x7004, "main::leaf");
    for (unsigned i = 0; i < 5; ++i) {
        uint64_t cx = array + i * l->context_size;
        field(l, cx, XPL_CXTYPE, 9);
        field(l, cx, XPL_SUBCV, cv);
        field(l, cx, XPL_OLDCOP, cop);
    }
    struct xpl_stack out;
    struct xpl_reader r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!out.reason && out.count == 6 && !strcmp(out.frames[0].name, "main::leaf") && out.frames[0].line == 7);
    assert(!strcmp(out.frames[5].name, "main"));
    size_t complete = attempts;
    for (size_t i = 1; i <= complete; ++i) {
        fail_at = i;
        r = reader();
        xpl_stack_read(l, &r, interp, &out);
        assert(out.reason && out.count <= 6 && r.reads <= 8192);
    }
    fail_at = 0;
    // Block eval with a null CV is normal; string eval still needs its CV.
    field(l, array + 4 * l->context_size, XPL_CXTYPE, 11);
    field(l, array + 4 * l->context_size, XPL_EVALCV, 0);
    field(l, array + 4 * l->context_size, XPL_EVALOP, 0);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!out.reason && !out.frames[0].reason);
    field(l, array + 4 * l->context_size, XPL_EVALOP, 352u << 7);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.frames[0].reason, "EvalCvUnavailable"));
    field(l, array + 4 * l->context_size, XPL_CXTYPE, 9);
    // Terminator at the final byte of a readable page does not require a
    // following page; an unreadable pathname never leaves a plausible prefix.
    str(0x7ff8, "edge.pl");
    field(l, cop, XPL_COPFILE, 0x7ff8);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!out.reason && !strcmp(out.frames[0].file, "edge.pl"));
    field(l, cop, XPL_COPFILE, 0x1000 + sizeof memory - 4);
    memcpy(memory + sizeof memory - 4, "oops", 4);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(out.reason && !out.frames[0].file[0]);
    field(l, cop, XPL_COPFILE, 0x6800);
    // Walk the newest bounded window of a valid deep stack.
    field(l, si, XPL_CXSTACK, 0x20000);
    field(l, si, XPL_CXIX, 5000);
    field(l, si, XPL_CXMAX, 5000);
    for (unsigned i = 0; i <= 5000; ++i) {
        uint64_t cx = 0x20000 + i * l->context_size;
        field(l, cx, XPL_CXTYPE, 9);
        field(l, cx, XPL_SUBCV, cv);
        field(l, cx, XPL_OLDCOP, cop);
    }
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(out.count == XPL_MAX_FRAMES && !strcmp(out.reason, "FrameLimit") && r.reads < 4096);
    for (unsigned i = 0; i <= 5000; ++i) field(l, 0x20000 + i * l->context_size, XPL_CXTYPE, 0);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.reason, "ContextLimit"));
    field(l, si, XPL_CXSTACK, array);
    field(l, si, XPL_CXIX, 4);
    field(l, si, XPL_CXMAX, 4);
    field(l, interp, XPL_STACKINFO, 0);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(out.reason && !strcmp(out.reason, "StackInfoUnavailable") && out.count == 0);
    field(l, interp, XPL_STACKINFO, si);
    field(l, si, XPL_CXIX, 5);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.reason, "ContextIndexInvalid"));
    field(l, si, XPL_CXIX, (uint32_t)-2);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.reason, "ContextIndexInvalid"));
    field(l, si, XPL_CXIX, 4);
    field(l, si, XPL_SIPREV, si);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.reason, "StackInfoCycle"));
    field(l, si, XPL_SIPREV, 0);
    field(l, array + 4 * l->context_size, XPL_SUBCV, 0);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(out.reason && out.frames[0].reason && !strcmp(out.frames[0].name, "(unavailable sub)"));
    field(l, array + 4 * l->context_size, XPL_CXTYPE, 15);
    r = reader();
    xpl_stack_read(l, &r, interp, &out);
    assert(!strcmp(out.reason, "ContextTypeInvalid"));
}
int main(void) {
    struct xpl_layout l = layout();
    assert(!xpl_layout_check(&l, l.build_id, l.build_id_len, l.version));
    unsigned char id[] = {4, 5, 6}, version[] = {5, 42, 0};
    assert(!strcmp(xpl_layout_check(&l, id, 3, l.version), "PerlBuildIdMismatch"));
    assert(!strcmp(xpl_layout_check(&l, l.build_id, 3, version), "PerlVersionMismatch"));
    values(&l);
    malformed_values(&l);
    stacks(&l);
    puts("Perl memory reader: values, stale undef bits, bounded previews, identity refusal, corrupt contexts and "
         "every-read failure passed");
    return 0;
}
