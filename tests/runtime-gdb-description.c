#include "gdb_description.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *valid =
    "<target><architecture>i386:x86-64</architecture><feature name='core'>"
    "<reg name='rip' bitsize='64'/><reg name='rsp' bitsize='64'/>"
    "<reg name='eflags' bitsize='32'/></feature></target>";
static enum xrt_status annex(void *ctx, const char *name, char **text, size_t *size)
{
    (void)ctx;
    if (strcmp(name, "core.xml")) return XRT_FILE_UNAVAILABLE;
    const char *s = "<feature name='core'><reg name='pc' bitsize='64'/>"
                    "<reg name='sp' bitsize='64'/><reg name='cpsr' bitsize='32'/></feature>";
    *size = strlen(s); *text = malloc(*size); assert(*text); memcpy(*text, s, *size);
    return XRT_OK;
}
int main(void)
{
    struct xrt_gdb_description *d = calloc(1, sizeof(*d)); assert(d);
    assert(xrt_gdb_description_parse(d, valid, strlen(valid), NULL, NULL) == XRT_OK);
    assert(d->count == 3 && d->register_bytes == 20);
    const uint8_t hex[] = "3412000000000000785600000000000002020000";
    struct xrt_registers regs;
    assert(xrt_gdb_description_decode(d, hex, sizeof(hex) - 1, &regs) == XRT_OK);
    uint64_t value;
    assert(xrt_registers_value(&regs, "rip", 3, &value) == XRT_OK && value == 0x1234);
    assert(xrt_registers_value(&regs, "rsp", 3, &value) == XRT_OK && value == 0x5678);
    assert(xrt_registers_value(&regs, "eflags", 6, &value) == XRT_OK && value == 0x202);
    assert(xrt_registers_value(&regs, "rax", 3, &value) == XRT_REGISTER_UNAVAILABLE);
    assert(xrt_gdb_description_decode(d, hex, 32, &regs) == XRT_OK);
    assert(xrt_registers_value(&regs, "rip", 3, &value) == XRT_OK && value == 0x1234);
    assert(xrt_registers_value(&regs, "eflags", 6, &value) == XRT_REGISTER_UNAVAILABLE);
    assert(xrt_gdb_description_decode(d, hex, 30, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
    assert(xrt_gdb_description_decode(d, hex, 0, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
    uint8_t unknown[sizeof(hex) - 1]; memcpy(unknown, hex, sizeof(unknown)); memset(unknown, 'x', 16);
    assert(xrt_gdb_description_decode(d, unknown, sizeof(unknown), &regs) == XRT_OK);
    assert(xrt_registers_value(&regs, "rip", 3, &value) == XRT_REGISTER_UNAVAILABLE);
    unknown[0] = '0';
    assert(xrt_gdb_description_decode(d, unknown, sizeof(unknown), &regs) == XRT_PROTOCOL_ERROR);
    assert(xrt_gdb_description_decode(d, hex, sizeof(hex) - 2, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
    const char *included = "<target><architecture>aarch64</architecture><xi:include href='core.xml'/></target>";
    assert(xrt_gdb_description_parse(d, included, strlen(included), annex, NULL) == XRT_OK);
    assert(xrt_gdb_description_decode(d, hex, sizeof(hex) - 1, &regs) == XRT_OK);
    assert(xrt_registers_value(&regs, "pc", 2, &value) == XRT_OK && value == 0x1234);
    assert(xrt_registers_value(&regs, "pstate", 6, &value) == XRT_OK && value == 0x202);
    const char *wide = "<target><architecture>aarch64</architecture><feature>"
        "<reg name='pc' bitsize='64'/><reg name='sp' bitsize='64'/>"
        "<reg name='za' bitsize='524288'/></feature></target>";
    assert(xrt_gdb_description_parse(d, wide, strlen(wide), NULL, NULL) == XRT_OK);
    assert(d->register_bytes == 65552);
    assert(xrt_gdb_description_decode(d, hex, 32, &regs) == XRT_OK);
    assert(xrt_registers_value(&regs, "pc", 2, &value) == XRT_OK && value == 0x1234);
    const char *bad[] = {
        "<target><architecture>i386:x86-64</architecture></target>",
        "<target><architecture>unsupported</architecture></target>",
        "<target><architecture>i386:x86-64</architecture><feature><reg name='rip' bitsize='32'/><reg name='rsp' bitsize='64'/></feature></target>",
        "<target><architecture>i386:x86-64</architecture><feature><reg name='rip' bitsize='64' regnum='4294967295'/></feature></target>",
        "<target><architecture>i386:x86-64</architecture><feature><reg name='rip' bitsize='18446744073709551616'/></feature></target>",
        "<target><feature><reg name='rip' bitsize='64'/><reg name='rip' bitsize='64'/></feature></target>",
        "<target><architecture>i386:x86-64</architecture><xi:include href='../core.xml'/></target>",
        "<target><architecture>i386:x86-64</architecture><xi:include href='core.xml'/><xi:include href='core.xml'/></target>",
        "<target><feature><reg name='rip' name='rsp' bitsize='64'/></feature></target>",
        "<!DOCTYPE target [<!ENTITY x SYSTEM 'file:///no-file'>]><target>&x;</target>",
        "<target><architecture>&unknown;</architecture></target>",
        "<target><feature></target></feature>",
        "<target/>junk",
        "<target/><target/>",
        "<target><architecture>i386:x86-64</architecture><feature><reg name='rip' bitsize='64'",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i)
        assert(xrt_gdb_description_parse(d, bad[i], strlen(bad[i]), annex, NULL) != XRT_OK);
    assert(xrt_gdb_description_parse(d, valid, strlen(valid) + 1, NULL, NULL) == XRT_PROTOCOL_ERROR);
    free(d);
    puts("GDB descriptions: register identity, widths, unknown bytes, includes and malicious XML pass");
}
