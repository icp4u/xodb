#define _GNU_SOURCE
#include "../src/language/perl.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

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
static void names(struct xpl_layout *l) {
    memset(memory, 0, sizeof memory);
    /* A nested stash, a GV belonging to it and a blessed hash referent. */
    sv(0x6000, 12 | 0x02000000, 0x7000, 0);
    uint64_t aux = 0x7000 + l->fields[XPL_HVAUX].offset;
    field(l, aux, XPL_HVNAME, 0x7800);
    field(l, aux, XPL_HVNAMECOUNT, 0);
    put(0x7800, strlen("Fixture::Nested::Widget"), 4);
    str(0x7804, "Fixture::Nested::Widget");
    sv(0x1100, 9, 0x2000, 0);
    field(l, 0x2000, XPL_GVSTASH, 0x6000);
    field(l, 0x2000, XPL_GVNAME, 0x3000);
    put(0x3000, 5, 4); str(0x3004, "entry");
    struct xpl_reader r = reader();
    struct xpl_value v;
    xpl_value_read(l, &r, 0x1100, &v);
    assert(!v.reason && !strcmp(v.display, "Fixture::Nested::Widget::entry"));
    sv(0x5100, 12 | 0x00100000, 0x5200, 0);
    field(l, 0x5200, XPL_HVKEYS, 0); field(l, 0x5200, XPL_HVMAX, 7);
    field(l, 0x5200, XPL_BLESS_STASH, 0x6000);
    sv(0x5600, 0x801, 0, 0x5100);
    r = reader(); xpl_value_read(l, &r, 0x5600, &v);
    assert(!v.reason && !strcmp(v.class_name, "Fixture::Nested::Widget"));
    assert(strstr(v.display, "Fixture::Nested::Widget RV ->") == v.display);
    assert(!strcmp(v.items[0].display, "Fixture::Nested::Widget HV (0 entries)"));
    /* HvNAME aliases are a bounded single-pointer indirection. */
    field(l, aux, XPL_HVNAMECOUNT, 2); field(l, aux, XPL_HVNAME, 0x7900);
    put(0x7900, 0x7800, 8);
    r = reader(); xpl_value_read(l, &r, 0x5100, &v);
    assert(!v.reason && !strcmp(v.class_name, "Fixture::Nested::Widget"));
    size_t reads = attempts;
    for (size_t i = 1; i <= reads; ++i) {
        fail_at = i; r = reader(); xpl_value_read(l, &r, 0x5100, &v); assert(v.reason);
    }
    fail_at = 0;
    field(l, 0x5200, XPL_BLESS_STASH, 0);
    r = reader(); xpl_value_read(l, &r, 0x5100, &v);
    assert(!strcmp(v.reason, "ClassNameUnavailable") && !v.class_name[0]);
    put(0x3000, 192, 4);
    r = reader(); xpl_value_read(l, &r, 0x1100, &v);
    assert(!strcmp(v.reason, "GvNameUnavailable") && !strcmp(v.display, "GV (name unavailable)"));
}
static void le(unsigned char *out, uint64_t n, size_t size) {
    for (size_t i = 0; i < size; ++i) out[i] = (unsigned char)(n >> (8 * i));
}
static void layout_units(unsigned units, const char *expected) {
    /* An ELF with only empty DWARF4 compilation units. The sixty-fourth
     * unit is EOF in one case and a real search limit in the other. */
    unsigned char elf[1280] = {0};
    memcpy(elf, "\177ELF\2\1\1", 7);
    le(elf+16, 1, 2); le(elf+18, 62, 2); le(elf+20, 1, 4);
    le(elf+40, 1024, 8); le(elf+52, 64, 2);
    le(elf+58, 64, 2); le(elf+60, 4, 2); le(elf+62, 1, 2);
    static const char names[] = "\0.shstrtab\0.debug_abbrev\0.debug_info\0";
    memcpy(elf+64, names, sizeof names);
    memcpy(elf+128, "\1\21\0\0\0\0", 6);
    for (unsigned i = 0; i < units; ++i) {
        unsigned char *cu = elf+160+i*12;
        le(cu, 8, 4); le(cu+4, 4, 2); cu[10]=8; cu[11]=1;
    }
    const unsigned section_names[] = {1, 11, 25}, offsets[] = {64, 128, 160};
    const unsigned sizes[] = {sizeof names, 6, units*12};
    for (unsigned i = 0; i < 3; ++i) {
        unsigned char *sh = elf+1024+(i+1)*64;
        le(sh, section_names[i], 4); le(sh+4, i==0 ? 3 : 1, 4);
        le(sh+24, offsets[i], 8); le(sh+32, sizes[i], 8); le(sh+48, 1, 8);
    }
    int fd = memfd_create("perl-layout-test", MFD_CLOEXEC); assert(fd>=0);
    assert(write(fd, elf, sizeof elf)==sizeof elf);
    assert(lseek(fd, 0, SEEK_SET)==0);
    Dwarf *dw = dwarf_begin(fd, DWARF_C_READ); assert(dw);
    unsigned char id[] = {1}, version[] = {5,44,0};
    struct xpl_layout l;
    const char *why = xpl_layout_build(dw, id, sizeof id, version, &l);
    assert(why && !strcmp(why, expected));
    dwarf_end(dw); close(fd);
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
    field(l, array + 4 * l->context_size, XPL_CXTYPE, 0x8b);
    field(l, array + 4 * l->context_size, XPL_EVALOP, 407u << 7);
    r = reader(); xpl_stack_read(l, &r, interp, &out);
    assert(!out.reason && !out.frames[0].reason && out.frames[0].context_type == 0x8b);
    assert(!strcmp(out.frames[0].name, "(try)"));
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
static void named_fixture(struct xpl_layout *l) {
    memset(memory, 0, sizeof memory);
    l->fields[XPL_SUBDEPTH] = (struct xpl_field_info){32, 4};
    l->fields[XPL_NAMELEN].size = l->fields[XPL_NAMEFLAGS].size = 1;
    l->fields[XPL_NAMELOW].size = l->fields[XPL_NAMEHIGH].size = 4;
    l->fields[XPL_COPSEQ].size = l->fields[XPL_CVDEPTH].size = 4;
    const uint64_t interp=0x1100, si=0x2000, cx=0x3000, cv=0x4000, body=0x5000, cop=0x6000;
    field(l, interp, XPL_CURCOP, cop); field(l, interp, XPL_STACKINFO, si); field(l, interp, XPL_MAINCV, cv);
    field(l, si, XPL_CXSTACK, cx); field(l, si, XPL_CXIX, 0); field(l, si, XPL_CXMAX, 0);
    field(l, cop, XPL_COPLINE, 7); field(l, cop, XPL_COPFILE, 0x6800); field(l, cop, XPL_COPSEQ, 15);
    str(0x6800, "fixture.pl"); sv(cv, 13, body, 0);
    field(l, body, XPL_CVNAME, 0x7000); field(l, body, XPL_CVFLAGS, 0x8000);
    put(0x7000, 10, 4); str(0x7004, "main::leaf");
    field(l, cx, XPL_CXTYPE, 9); field(l, cx, XPL_SUBCV, cv); field(l, cx, XPL_OLDCOP, cop);
    field(l, cx, XPL_SUBDEPTH, 1); field(l, body, XPL_CVDEPTH, 2);
    field(l, body, XPL_CVPADLIST, 0x8000);
    field(l, 0x8000, XPL_PADMAX, 2); field(l, 0x8000, XPL_PADARRAY, 0x9000);
    put(0x9000, 0xa000, 8); put(0x9008, 0xb000, 8); put(0x9010, 0xb100, 8);
    sv(0xb000, 11, 0xc000, 0xe000); sv(0xb100, 11, 0xc800, 0xf000);
    field(l, 0xc000, XPL_AVFILL, 8); field(l, 0xc000, XPL_AVMAX, 8);
    field(l, 0xc800, XPL_AVFILL, 8); field(l, 0xc800, XPL_AVMAX, 8);
    field(l, 0xa000, XPL_NAMESFILL, 8); field(l, 0xa000, XPL_NAMESMAX, 8);
    field(l, 0xa000, XPL_NAMESARRAY, 0xd000);
    const char *names[] = {"", "$x", "$x", "$expired", "$closed", "$state", "$masked", "$masked", "&"};
    for (unsigned i=0;i<9;++i) {
        uint64_t pn=0x11000+i*512, name=0x15000+i*512;
        put(0xd000+i*8,pn,8); field(l,pn,XPL_NAMEPV,name); str(name,names[i]);
        field(l,pn,XPL_NAMELEN,strlen(names[i])); field(l,pn,XPL_NAMELOW,10); field(l,pn,XPL_NAMEHIGH,20);
        sv(0x20000+i*32,0x101,0,100+i); put(0xf000+i*8,0x20000+i*32,8);
        sv(0x21000+i*32,0x101,0,200+i); put(0xe000+i*8,0x21000+i*32,8);
    }
    field(l,0x11000+3*512,XPL_NAMEHIGH,14);
    field(l,0x11000+4*512,XPL_NAMEFLAGS,1); field(l,0x11000+4*512,XPL_NAMELOW,99);
    field(l,0x11000+5*512,XPL_NAMEFLAGS,2);
    field(l,0x11000+7*512,XPL_NAMEOUR,0x8888);
}
static void named_locals(struct xpl_layout *l) {
    struct xpl_locals *out=calloc(1,sizeof *out); assert(out);
    named_fixture(l); struct xpl_reader r=reader();
    xpl_locals_read(l,&r,0x1100,0,0,32,out);
    assert(!out->reason && out->count==3 && out->total==3 && out->depth==2 && !out->truncated);
    assert(!strcmp(out->items[0].name,"$state") && out->items[0].scope==XPL_STATE);
    assert(!strcmp(out->items[1].name,"$closed") && out->items[1].scope==XPL_OUTER);
    assert(!strcmp(out->items[2].name,"$x") && !strcmp(out->items[2].value.display,"IV 102"));
    size_t reads=attempts;
    for(size_t i=1;i<=reads;++i) {
        fail_at=i;r=reader();xpl_locals_read(l,&r,0x1100,0,0,32,out);
        assert(out->reason && r.reads<=8192 && r.bytes<=512*1024);
    }
    fail_at=0;
    for(size_t start=0;start<5;++start) {
        r=reader();xpl_locals_read(l,&r,0x1100,0,start,1,out);
        assert(!out->reason && out->total==3 && out->count==(start<3));
        assert(out->truncated==(start<2));
    }
    r=reader();xpl_locals_read(l,&r,0x1100,0,SIZE_MAX,SIZE_MAX,out);
    assert(!out->reason && out->total==3 && !out->count && !out->truncated);
    r=reader();xpl_local_find(l,&r,0x1100,0,"$x",out);
    assert(!out->reason && out->count==1 && out->items[0].ordinal==2 && out->items[0].sv==0x20040);
    reads=attempts;
    for(size_t i=1;i<=reads;++i) {
        fail_at=i;r=reader();xpl_local_find(l,&r,0x1100,0,"$x",out);assert(out->reason);
    }
    fail_at=0;
    const char *missing[]={"$expired","$masked","$nothing"};
    for(unsigned i=0;i<sizeof missing/sizeof *missing;++i) {
        r=reader();xpl_local_find(l,&r,0x1100,0,missing[i],out);
        assert(out->reason && !strcmp(out->reason, !strcmp(missing[i], "$masked") ? "PerlPackageVariableUnread" : "PerlOuterScopeUnread") && !out->count);
    }
    const char *invalid[]={NULL,"","$","x","$x+1","$x[f()]","$x->foo","@a()","$::x"," $x","$x ","$9x","$$x"};
    for(unsigned i=0;i<sizeof invalid/sizeof *invalid;++i) {
        r=reader();xpl_local_find(l,&r,0x1100,0,invalid[i],out);
        assert(!strcmp(out->reason,"UnsupportedPerlExpression") && attempts==0);
    }
    char long_name[257];memset(long_name,'x',sizeof long_name);long_name[0]='$';long_name[256]=0;
    r=reader();xpl_local_find(l,&r,0x1100,0,long_name,out);assert(!strcmp(out->reason,"UnsupportedPerlExpression"));
    r=reader();xpl_locals_read(l,&r,0x1100,1,0,32,out);
    assert(!out->reason && out->depth==1 && !strcmp(out->items[2].value.display,"IV 202"));
    r=reader();xpl_locals_read(l,&r,0x1100,128,0,32,out);assert(!strcmp(out->reason,"FrameUnavailable"));
    struct { uint64_t object; enum xpl_field field; uint64_t value; const char *reason; } bad[]={
        {0x3000,XPL_SUBDEPTH,2,"PadDepthInvalid"}, {0x3000,XPL_SUBDEPTH,UINT32_MAX,"PadDepthInvalid"},
        {0x5000,XPL_CVFLAGS,0x8008,"XsFrameNoPad"}, {0x6000,XPL_COPSEQ,0,"PadSequenceUnavailable"},
        {0x6000,XPL_COPSEQ,UINT32_MAX,"PadSequenceUnavailable"}, {0x5000,XPL_CVPADLIST,0,"PadlistUnavailable"},
        {0x8000,XPL_PADMAX,1,"PadlistInvalid"}, {0x8000,XPL_PADARRAY,UINT64_MAX-8,"PadAddressOverflow"},
        {0xa000,XPL_NAMESFILL,9,"PadNamesInvalid"}, {0xc800,XPL_AVFILL,7,"PadValuesInvalid"},
        {0x3000,XPL_CXTYPE,10,"FormatPadUnproved"}, {0x3000,XPL_CXTYPE,11,"EvalPadUnproved"}, {0x3000,XPL_CXTYPE,0x8b,"EvalPadUnproved"},
        {0x11000+2*512,XPL_NAMELOW,21,"PadSequenceWrapUnsupported"},
        {0x11000+2*512,XPL_NAMELEN,8,"PadNameInvalid"},
    };
    for(unsigned i=0;i<sizeof bad/sizeof *bad;++i) {
        named_fixture(l);field(l,bad[i].object,bad[i].field,bad[i].value);
        r=reader();xpl_locals_read(l,&r,0x1100,0,0,32,out);
        if(!out->reason || strcmp(out->reason,bad[i].reason)) fprintf(stderr,"named case %u: %s\n",i,out->reason?out->reason:"OK");
        assert(out->reason && !strcmp(out->reason,bad[i].reason) && !out->count);
    }
    named_fixture(l);field(l,0xa000,XPL_NAMESFILL,4096);field(l,0xa000,XPL_NAMESMAX,4096);
    r=reader();xpl_locals_read(l,&r,0x1100,0,0,32,out);assert(!strcmp(out->reason,"PadSlotLimit"));
    named_fixture(l);put(0xf000+2*8,0,8);
    r=reader();xpl_local_find(l,&r,0x1100,0,"$x",out);
    assert(!out->reason && out->count==1 && !strcmp(out->items[0].reason,"PadValueUnavailable"));
    named_fixture(l);field(l,0x11000+2*512,XPL_NAMEFLAGS,0x20);
    r=reader();xpl_local_find(l,&r,0x1100,0,"$x",out);
    assert(!out->reason && !strcmp(out->items[0].reason,"FieldStorageUnproved") && !out->items[0].sv);
    named_fixture(l);r=reader();r.reads=8192;xpl_locals_read(l,&r,0x1100,0,0,32,out);
    assert(!strcmp(out->reason,"PerlReadLimit") && !attempts);
    r=reader();r.bytes=SIZE_MAX;xpl_local_find(l,&r,0x1100,0,"$x",out);
    assert(!strcmp(out->reason,"PerlReadLimit") && !attempts);
    /* A fixed deterministic malformed-memory corpus, never real process data. */
    uint32_t random=123456789;
    for(unsigned i=0;i<2000;++i) {
        named_fixture(l);random=random*1664525u+1013904223u;
        unsigned which=random%(sizeof bad/sizeof *bad);random=random*1664525u+1013904223u;
        uint64_t value=(i&1)?random:((uint64_t)random<<32)|random;
        field(l,bad[which].object,bad[which].field,value);
        r=reader();xpl_locals_read(l,&r,0x1100,i%3,0,32,out);
        assert(out->count<=32 && out->total<=512 && r.reads<=8192 && r.bytes<=512*1024);
    }
    free(out);
    puts("Perl named locals: lexical scopes, recursive pads, shadows, pagination, exact lookup, every-read failure and 2000 corrupt objects passed");
}

static void watch_samples(struct xpl_layout *l) {
    struct xpl_sample a, b;
    struct xpl_reader r;
    memset(memory, 0, sizeof memory);
    sv(0x1100, 0x101, 0, 42); r=reader();xpl_sample_read(l,&r,0x1100,&a);
    assert(!a.reason && a.kind==XPL_SAMPLE_IV && a.size==8 && a.bytes[0]==42);
    sv(0x1200, 0x105, 0x2000, 0);field(l,0x2000,XPL_IV,42);
    r=reader();xpl_sample_read(l,&r,0x1200,&b);
    assert(!b.reason && b.kind==a.kind && b.size==a.size && !memcmp(a.bytes,b.bytes,a.size));
    sv(0x1100, 0x80000101u, 0, 42);r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(!b.reason && b.kind==(XPL_SAMPLE_IV|XPL_SAMPLE_UNSIGNED) && b.kind!=a.kind);
    sv(0x1100,0,0,UINT64_MAX);r=reader();xpl_sample_read(l,&r,0x1100,&a);
    assert(!a.reason && a.kind==XPL_SAMPLE_UNDEF && !a.size && !strcmp(a.display,"undef"));
    /* Equal display is not a complete comparison of a dualvar. */
    sv(0x1100,0x505,0x2000,0x3000);str(0x3000,"same");
    field(l,0x2000,XPL_PVCUR,4);field(l,0x2000,XPL_PVLEN,5);field(l,0x2000,XPL_IV,1);
    r=reader();xpl_sample_read(l,&r,0x1100,&a);
    field(l,0x2000,XPL_IV,2);r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(!a.reason && !b.reason && a.kind==(XPL_SAMPLE_IV|XPL_SAMPLE_PV) && b.kind==a.kind);
    assert(a.size==24 && b.size==a.size && memcmp(a.bytes,b.bytes,a.size));
    assert(strstr(a.display,"IV 1") && strstr(b.display,"IV 2") && strstr(a.display,"same"));
    /* PV encoding flags alone do not change its sequence of characters. */
    sv(0x1100,0x403,0x2000,0x3000);put(0x3000,0xe4,1);
    field(l,0x2000,XPL_PVCUR,1);field(l,0x2000,XPL_PVLEN,8);
    r=reader();xpl_sample_read(l,&r,0x1100,&a);
    sv(0x1100,0x20000403u,0x2000,0x3000);put(0x3000,0xa4c3,2);field(l,0x2000,XPL_PVCUR,2);
    r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(!a.reason && !b.reason && a.size==4 && a.bytes[0]==0xe4 && a.kind==b.kind && !memcmp(a.bytes,b.bytes,a.size));
    sv(0x1100,0x403,0x2000,0x3000);memset(memory+0x3000-0x1000,'x',1025);
    field(l,0x2000,XPL_PVCUR,1024);field(l,0x2000,XPL_PVLEN,1026);
    r=reader();xpl_sample_read(l,&r,0x1100,&a);assert(!a.reason && a.size==4096);
    put(0x3000+1023,'y',1);r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(!b.reason && a.size==b.size && memcmp(a.bytes,b.bytes,a.size));
    field(l,0x2000,XPL_PVCUR,1025);r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(b.reason && !strcmp(b.reason,"PerlWatchSampleLimit"));
    /* Interior NUL is part of the value, not a string terminator. */
    field(l,0x2000,XPL_PVCUR,3);put(0x3000,0x620061,3);
    r=reader();xpl_sample_read(l,&r,0x1100,&a);
    assert(!a.reason && a.size==12 && a.bytes[0]=='a' && !a.bytes[4] && a.bytes[8]=='b');
    const uint64_t invalid_utf8[]={0xff,0x80c0,0x80a0ed,0x808090f4};
    const unsigned lengths[]={1,2,3,4};
    sv(0x1100,0x20000403u,0x2000,0x3000);
    for(unsigned i=0;i<4;++i) {
        put(0x3000,invalid_utf8[i],lengths[i]);field(l,0x2000,XPL_PVCUR,lengths[i]);
        r=reader();xpl_sample_read(l,&r,0x1100,&a);
        assert(a.reason && !strcmp(a.reason,"PerlWatchUtf8Unsupported"));
    }
    sv(0x1100,0x202,0x2000,0);field(l,0x2000,XPL_NV,0);
    r=reader();xpl_sample_read(l,&r,0x1100,&a);
    field(l,0x2000,XPL_NV,UINT64_C(1)<<63);r=reader();xpl_sample_read(l,&r,0x1100,&b);
    assert(!a.reason && !b.reason && a.kind==XPL_SAMPLE_NV && memcmp(a.bytes,b.bytes,8));
    const unsigned refuse[]={0x200101,0x400101,0x800101,0x100007,0x801,11,12,13,8,4,16,255};
    for(size_t i=0;i<sizeof refuse/sizeof *refuse;++i) {
        sv(0x1100,refuse[i],0x2000,42);r=reader();xpl_sample_read(l,&r,0x1100,&a);assert(a.reason);
    }
    sv(0x1100,0x403,0x2000,0x3000);field(l,0x2000,XPL_PVCUR,512);field(l,0x2000,XPL_PVLEN,513);
    memset(memory+0x3000-0x1000,'q',512);r=reader();xpl_sample_read(l,&r,0x1100,&a);assert(!a.reason);
    size_t reads=attempts;
    for(size_t i=1;i<=reads;++i) {
        fail_at=i;r=reader();xpl_sample_read(l,&r,0x1100,&a);assert(a.reason);
    }
    fail_at=0;
    puts("Perl samples: complete dual representations, relocated equal scalars, exact numeric bits, Unicode/byte equivalence, long/NUL strings, limits, magic refusal and every-read failure passed");
}
static void watch_bindings(struct xpl_layout *l) {
    struct xpl_locals *out=calloc(1,sizeof *out);assert(out);
    struct xpl_stack *first=calloc(1,sizeof *first),*second=calloc(1,sizeof *second);assert(first && second);
    named_fixture(l);struct xpl_reader r=reader();xpl_stack_read(l,&r,0x1100,first);
    assert(first->chain_complete && first->frames[0].identity_proved);
    memcpy(memory+0x3500-0x1000,memory+0x3000-0x1000,l->context_size);
    field(l,0x2000,XPL_CXSTACK,0x3500);r=reader();xpl_stack_read(l,&r,0x1100,second);
    assert(second->chain_complete && second->frames[0].identity_proved);
    assert(first->frames[0].context_address!=second->frames[0].context_address);
    assert(first->frames[0].stackinfo==second->frames[0].stackinfo && first->frames[0].context_index==second->frames[0].context_index && first->frames[0].cv==second->frames[0].cv);
    field(l,0x5000,XPL_CVNAME,0);r=reader();xpl_stack_read(l,&r,0x1100,second);
    assert(second->reason && !strcmp(second->reason,"PartialFrames") && second->chain_complete && second->frames[0].identity_proved);
    field(l,0x2000,XPL_SIPREV,0x2000);r=reader();xpl_stack_read(l,&r,0x1100,second);
    assert(!second->chain_complete && !strcmp(second->reason,"StackInfoCycle"));
    named_fixture(l);r=reader();xpl_local_binding(l,&r,0x1100,0,1,"$x",out);
    assert(!out->reason && out->count==1 && out->items[0].ordinal==1 && !strcmp(out->items[0].value.display,"IV 101"));
    r=reader();xpl_local_find(l,&r,0x1100,0,"$x",out);
    assert(!out->reason && out->items[0].ordinal==2 && !strcmp(out->items[0].value.display,"IV 102"));
    r=reader();xpl_local_binding(l,&r,0x1100,0,3,"$expired",out);
    assert(out->reason && !strcmp(out->reason,"PerlWatchBindingUnavailable") && !out->count);
    r=reader();xpl_local_binding(l,&r,0x1100,0,1,"$other",out);
    assert(out->reason && !strcmp(out->reason,"PerlWatchBindingUnavailable") && !out->count);
    r=reader();xpl_local_binding(l,&r,0x1100,0,7,"$masked",out);
    assert(out->reason && !strcmp(out->reason,"PerlPackageVariableUnread") && !out->count);
    r=reader();xpl_local_binding(l,&r,0x1100,0,UINT64_MAX,"$x",out);
    assert(out->reason && !attempts);
    r=reader();xpl_local_binding(l,&r,0x1100,0,1,"$x",out);assert(!out->reason);
    size_t reads=attempts;
    for(size_t i=1;i<=reads;++i) {fail_at=i;r=reader();xpl_local_binding(l,&r,0x1100,0,1,"$x",out);assert(out->reason);}
    fail_at=0;
    named_fixture(l);
    str(0x15000+512,"$\xc3\xa9");field(l,0x11000+512,XPL_NAMELEN,3);
    r=reader();xpl_locals_read(l,&r,0x1100,0,0,32,out);
    assert(!out->reason && out->count==4);
    r=reader();xpl_local_binding(l,&r,0x1100,0,1,"$\xc3\xa9",out);
    assert(!out->reason && out->count==1 && out->items[0].ordinal==1);
    r=reader();xpl_local_find(l,&r,0x1100,0,"$\xc3\xa9",out);
    assert(out->reason && !strcmp(out->reason,"UnsupportedPerlExpression") && !attempts);
    free(out);free(first);free(second);
    puts("Perl watch bindings: relocatable context identity, structural completion, retained shadowed declaration, inactive/package refusal and every-read failure passed");
}

static void paths(void) {
    struct xpl_layout l = layout();
    l.fields[XPL_HEKHASH] = (struct xpl_field_info){0,4};
    l.fields[XPL_HEKLEN] = (struct xpl_field_info){4,4};
    l.fields[XPL_HEKKEY] = (struct xpl_field_info){8,1};
    memset(memory, 0, sizeof memory);
    const char *valid[] = {"$x", "%h", "@a", "$h{k}", "$h{''}", "$h{\"a b\"}", "$a[0]", "$r->{k}->[2]", "$r->[0]{k}"};
    const char *invalid[] = {NULL,"", "$r->{", "$r->{'x}", "$r->{x", "$r->{x}junk", "$r->[01]", "$r->[-1]", "$r->[2147483648]", "$r->{\"$x\"}", "$r->{'\\n'}", "$r->{\xc3\xa9}", "$r->{a}{a}{a}{a}{a}{a}{a}{a}{a}"};
    for (size_t i=0;i<sizeof valid/sizeof *valid;++i) assert(!xpl_expression_check(valid[i]));
    for (size_t i=0;i<sizeof invalid/sizeof *invalid;++i) assert(xpl_expression_check(invalid[i]));
    const uint64_t rv=0x1100,hv=0x1200,body=0x2000,buckets=0x3000,he=0x4000,key=0x5000,av=0x6000,abody=0x7000,slots=0x8000,leaf=0x9000;
    sv(rv,0x801,0,hv);sv(hv,12,body,buckets);field(&l,body,XPL_HVMAX,7);field(&l,body,XPL_HVKEYS,1);
    put(buckets+3*8,he,8);field(&l,he,XPL_HEKEY,key);field(&l,he,XPL_HEVAL,av);
    field(&l,key,XPL_HEKHASH,11);field(&l,key,XPL_HEKLEN,1);str(key+8,"k");
    sv(av,0x801,0,av+64);sv(av+64,11,abody,slots);field(&l,abody,XPL_AVFILL,2);field(&l,abody,XPL_AVMAX,3);
    put(slots+2*8,leaf,8);sv(leaf,0x101,0,7);
    struct xpl_reader r=reader();struct xpl_path_value out;
    xpl_path_read(&l,&r,rv,"$r->{k}[2]",&out);assert(!out.reason && out.sv==leaf && out.slot==slots+16);
    size_t total=attempts;
    for(size_t i=1;i<=total;++i) {fail_at=i;r=reader();xpl_path_read(&l,&r,rv,"$r->{k}[2]",&out);assert(out.reason && !out.sv && !out.slot);}
    fail_at=0;
    r=reader();xpl_path_read(&l,&r,hv,"$h{k}",&out);assert(!out.reason && out.sv==av);
    r=reader();xpl_path_read(&l,&r,rv,"$r->{absent}",&out);assert(!strcmp(out.reason,"PerlPathKeyNotFound"));
    r=reader();xpl_path_read(&l,&r,rv,"$r->{k}[0]",&out);assert(!strcmp(out.reason,"PerlPathArrayHole"));
    r=reader();xpl_path_read(&l,&r,rv,"$r->{k}[3]",&out);assert(!strcmp(out.reason,"PerlPathIndexOutOfRange"));
    for(unsigned bit=0x00100000;bit<=0x00800000;bit<<=1) {
        field(&l,hv,XPL_FLAGS,12|bit);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathMagicOrObjectUnsupported"));
        field(&l,hv,XPL_FLAGS,12);field(&l,rv,XPL_FLAGS,0x801|bit);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathMagicOrObjectUnsupported"));
        field(&l,rv,XPL_FLAGS,0x801);
    }
    field(&l,hv,XPL_FLAGS,12|0x08000000);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathRestrictedHashUnsupported"));field(&l,hv,XPL_FLAGS,12);
    field(&l,leaf,XPL_FLAGS,0x00200101);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}[2]",&out);assert(!strcmp(out.reason,"PerlPathMagicOrObjectUnsupported"));field(&l,leaf,XPL_FLAGS,0x101);
    field(&l,key,XPL_HEKHASH,12);r=reader();xpl_path_read(&l,&r,rv,"$r->{absent}",&out);assert(!strcmp(out.reason,"PerlPathHashUnproved"));field(&l,key,XPL_HEKHASH,11);
    field(&l,he,XPL_HENEXT,he);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"HashEntryCycle"));field(&l,he,XPL_HENEXT,0);
    field(&l,body,XPL_HVKEYS,2);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathHashInvalid"));field(&l,body,XPL_HVKEYS,1);
    field(&l,key,XPL_HEKLEN,UINT32_MAX);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathSvKeyUnsupported"));field(&l,key,XPL_HEKLEN,1);
    field(&l,body,XPL_HVMAX,8191);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}",&out);assert(!strcmp(out.reason,"PerlPathHashLimit"));field(&l,body,XPL_HVMAX,7);
    field(&l,abody,XPL_AVFILL,5);r=reader();xpl_path_read(&l,&r,rv,"$r->{k}[2]",&out);assert(!strcmp(out.reason,"PerlPathArrayInvalid"));
    puts("Perl paths: syntax, nested raw storage, holes, missing keys, magic/object/restricted refusal, stored-hash mismatch, corrupt chains and every-read failure passed");
}

int main(void) {
    struct xpl_layout l = layout();
    assert(!xpl_layout_check(&l, l.build_id, l.build_id_len, l.version));
    unsigned char id[] = {4, 5, 6}, version[] = {5, 42, 0};
    assert(!strcmp(xpl_layout_check(&l, id, 3, l.version), "PerlBuildIdMismatch"));
    assert(!strcmp(xpl_layout_check(&l, l.build_id, 3, version), "PerlVersionMismatch"));
    values(&l);
    malformed_values(&l);
    names(&l);
    layout_units(1, "PerlDwarfTypesUnavailable");
    layout_units(64, "PerlDwarfTypesUnavailable");
    layout_units(65, "PerlDwarfUnitLimit");
    stacks(&l);
    named_locals(&l);
    watch_samples(&l);
    watch_bindings(&l);
    paths();
    puts("Perl memory reader: values, stale undef bits, bounded previews, identity refusal, corrupt contexts and "
         "every-read failure passed");
    return 0;
}
