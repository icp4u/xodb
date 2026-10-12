#define _GNU_SOURCE 1
#include "../src/debug/dwarf_types.h"
#include "check.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* dwarf-types IMAGE WORK TYPE... -- FIELD...   where FIELD is
 * owner:name:kind:width[:optional] and "?TYPE" may be absent. Prints one line per type and field, or
 * "error NAME" and exits 2. */
static unsigned kind_of(const char *s) {
    static const char *const names[] = {"any", "pointer", "unsigned", "signed", "boolean"};
    for (unsigned i = 0; i < 5; ++i) if (!strcmp(s, names[i])) return i;
    CHECK(!"kind"); return 0;
}
int main(int argc, char **argv) {
    CHECK(argc >= 4);
    const char *types[XDT_MAX_TYPES + 2]; struct xdt_field fields[XDT_MAX_FIELDS + 2];
    unsigned type_count = 0, field_count = 0; int i = 3; uint64_t optional_types = 0;
    for (; i < argc && strcmp(argv[i], "--"); ++i) {
        CHECK(type_count < XDT_MAX_TYPES + 2);
        if (argv[i][0] == '?') { optional_types |= 1ull << type_count; ++argv[i]; }
        types[type_count++] = argv[i];
    }
    for (++i; i < argc; ++i) {
        CHECK(field_count < XDT_MAX_FIELDS + 2);
        char *owner = strtok(argv[i], ":"), *name = strtok(NULL, ":"), *kind = strtok(NULL, ":"), *width = strtok(NULL, ":"), *optional = strtok(NULL, ":");
        CHECK(owner && name && kind && width);
        fields[field_count++] = (struct xdt_field){(uint8_t)atoi(owner), name, (uint8_t)kind_of(kind), (uint8_t)atoi(width), optional != NULL};
    }
    Dwarf *dwarf = NULL; int fd = -1;
    if (strcmp(argv[1], "none")) {
        fd = open(argv[1], O_RDONLY | O_CLOEXEC); CHECK(fd >= 0);
        dwarf = dwarf_begin(fd, DWARF_C_READ);
    }
    struct xdt_schema schema = {types, fields, type_count, field_count, optional_types};
    struct xdt_slot slots[XDT_MAX_FIELDS + 2]; uint32_t sizes[XDT_MAX_TYPES + 2]; struct xdt_stats stats;
    memset(slots, 0xa5, sizeof slots); memset(sizes, 0xa5, sizeof sizes);
    const char *why = xdt_layout_build(dwarf, &schema, strtoull(argv[2], NULL, 0), slots, sizes, &stats);
    int status = 0;
    if (why) {
        /* A refusal leaves no partial layout behind. */
        if (type_count <= XDT_MAX_TYPES && field_count <= XDT_MAX_FIELDS) {
            for (unsigned t = 0; t < type_count; ++t) CHECK(sizes[t] == 0);
            for (unsigned f = 0; f < field_count; ++f) CHECK(!slots[f].present && !slots[f].offset && !slots[f].size);
        }
        printf("error %s units=%llu work=%llu\n", why, (unsigned long long)stats.units, (unsigned long long)stats.work);
        status = 2;
    } else {
        CHECK(stats.work <= strtoull(argv[2], NULL, 0));
        for (unsigned t = 0; t < type_count; ++t) printf("type %s size=%u definitions=%u\n", types[t], sizes[t], stats.definitions[t]);
        for (unsigned f = 0; f < field_count; ++f) printf("field %s.%s offset=%u size=%u present=%u\n", types[fields[f].owner], fields[f].name, slots[f].offset, slots[f].size, slots[f].present);
        printf("ok units=%llu work=%llu\n", (unsigned long long)stats.units, (unsigned long long)stats.work);
    }
    if (dwarf) dwarf_end(dwarf);
    if (fd >= 0) close(fd);
    return status;
}
