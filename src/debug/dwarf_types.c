#include "dwarf_types.h"
#include <dwarf.h>
#include <string.h>

struct scan {
    const struct xdt_schema *schema;
    struct xdt_slot *fields;
    uint32_t *sizes;
    struct xdt_stats *stats;
    uint64_t work, limit;
    const char *error;
};
static int tick(struct scan *s) {
    if (s->error) return 0;
    if (++s->work > s->limit) { s->error = "DwarfTypesWorkLimit"; return 0; }
    return 1;
}
static int ud(Dwarf_Die *d, unsigned code, uint64_t *v) {
    Dwarf_Attribute a; Dwarf_Word word; Dwarf_Sword sword;
    if (!dwarf_attr(d, code, &a)) return 0;
    if (!dwarf_formudata(&a, &word)) { *v = word; return 1; }
    if (!dwarf_formsdata(&a, &sword) && sword >= 0) { *v = (uint64_t)sword; return 1; }
    return 0;
}
static int flag(Dwarf_Die *d, unsigned code) {
    Dwarf_Attribute a; bool set = false;
    return dwarf_attr(d, code, &a) && !dwarf_formflag(&a, &set) && set;
}
static int type_of(Dwarf_Die *d, Dwarf_Die *out) {
    Dwarf_Attribute a;
    return dwarf_attr(d, DW_AT_type, &a) && dwarf_formref_die(&a, out);
}
/* Through typedefs and qualifiers to the type that has the size. */
static int resolve(Dwarf_Die *d, struct scan *s) {
    for (unsigned n = 0; n < 32 && tick(s); ++n) {
        int tag = dwarf_tag(d);
        if (tag != DW_TAG_typedef && tag != DW_TAG_const_type && tag != DW_TAG_volatile_type &&
            tag != DW_TAG_atomic_type && tag != DW_TAG_restrict_type) return tag > 0;
        Dwarf_Die next;
        if (!type_of(d, &next)) return 0; /* e.g. const void */
        *d = next;
    }
    return 0;
}
static int byte_size(Dwarf_Die *d, uint64_t *out) {
    Dwarf_Word n;
    if (dwarf_aggregate_size(d, &n) || !n || n > 1u << 24) return 0;
    *out = n; return 1;
}
static int aggregate(int tag) {
    return tag == DW_TAG_structure_type || tag == DW_TAG_class_type || tag == DW_TAG_union_type;
}
static int kind_matches(Dwarf_Die *d, unsigned want) {
    uint64_t encoding;
    if (want == XDT_ANY) return 1;
    if (want == XDT_POINTER) return dwarf_tag(d) == DW_TAG_pointer_type;
    if (dwarf_tag(d) != DW_TAG_base_type || !ud(d, DW_AT_encoding, &encoding)) return 0;
    if (want == XDT_BOOLEAN) return encoding == DW_ATE_boolean;
    if (want == XDT_SIGNED) return encoding == DW_ATE_signed || encoding == DW_ATE_signed_char;
    return encoding == DW_ATE_unsigned || encoding == DW_ATE_unsigned_char;
}
/* One complete definition of types[t]: every requested member, checked. */
static void definition(struct scan *s, unsigned t, Dwarf_Die *die) {
    const struct xdt_schema *schema = s->schema;
    struct xdt_slot got[XDT_MAX_FIELDS];
    uint64_t total;
    memset(got, 0, sizeof got);
    if (!byte_size(die, &total) || total > UINT32_MAX) { s->error = "DwarfTypesMalformed"; return; }
    Dwarf_Die child;
    int rc = dwarf_child(die, &child);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    if (rc == 0) do {
        if (!tick(s)) return;
        if (dwarf_tag(&child) != DW_TAG_member) continue;
        const char *name = dwarf_diename(&child);
        if (!name) continue;
        for (unsigned f = 0; f < schema->field_count; ++f) {
            const struct xdt_field *field = &schema->fields[f];
            if (field->owner != t || strcmp(name, field->name)) continue;
            uint64_t at, bytes; Dwarf_Die member;
            /* A bit-field is not a whole member. */
            if (dwarf_hasattr(&child, DW_AT_bit_size) || dwarf_hasattr(&child, DW_AT_data_bit_offset)) { s->error = "DwarfFieldMismatch"; return; }
            /* A static member has no location; it is not this field. */
            if (!ud(&child, DW_AT_data_member_location, &at)) continue;
            if (got[f].present) { s->error = "DwarfTypeAmbiguous"; return; }
            if (!type_of(&child, &member) || !resolve(&member, s)) {
                if (!s->error) s->error = "DwarfFieldMismatch";
                return;
            }
            if (dwarf_tag(&member) == DW_TAG_pointer_type || dwarf_tag(&member) == DW_TAG_reference_type) bytes = 8;
            else if (!byte_size(&member, &bytes)) { s->error = "DwarfFieldMismatch"; return; }
            if (at > total || bytes > total - at || !kind_matches(&member, field->kind) ||
                (field->width && bytes != field->width)) { s->error = "DwarfFieldMismatch"; return; }
            got[f] = (struct xdt_slot){(uint32_t)at, (uint32_t)bytes, 1};
        }
    } while ((rc = dwarf_siblingof(&child, &child)) == 0);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    for (unsigned f = 0; f < schema->field_count; ++f) {
        if (schema->fields[f].owner != t) continue;
        if (!got[f].present && !schema->fields[f].optional) { s->error = "DwarfFieldNotFound"; return; }
        if (s->stats->definitions[t] && memcmp(&got[f], &s->fields[f], sizeof got[f])) { s->error = "DwarfTypeAmbiguous"; return; }
        s->fields[f] = got[f];
    }
    if (s->stats->definitions[t] && s->sizes[t] != (uint32_t)total) { s->error = "DwarfTypeAmbiguous"; return; }
    s->sizes[t] = (uint32_t)total;
    if (s->stats->definitions[t] != UINT32_MAX) ++s->stats->definitions[t];
}
/* Children of `parent` against the path suffixes still wanted. `rest[t]` is
 * the unmatched tail of types[t], or NULL when this scope is not on its path. */
static void scope(struct scan *s, Dwarf_Die *parent, const char *const *rest, unsigned depth) {
    Dwarf_Die d;
    int rc = dwarf_child(parent, &d);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    if (rc > 0) return;
    do {
        if (!tick(s)) return;
        int tag = dwarf_tag(&d);
        if (!aggregate(tag) && tag != DW_TAG_namespace) continue;
        const char *name = dwarf_diename(&d);
        if (!name) continue;
        size_t len = strlen(name);
        const char *inner[XDT_MAX_TYPES]; int descend = 0;
        for (unsigned t = 0; t < s->schema->type_count; ++t) {
            inner[t] = NULL;
            if (!rest[t] || strncmp(rest[t], name, len)) continue;
            if (!rest[t][len]) {
                if (aggregate(tag) && !flag(&d, DW_AT_declaration) && dwarf_hasattr(&d, DW_AT_byte_size)) definition(s, t, &d);
                if (s->error) return;
            } else if (rest[t][len] == ':' && rest[t][len + 1] == ':') { inner[t] = rest[t] + len + 2; descend = 1; }
        }
        if (descend && depth < 8) { scope(s, &d, inner, depth + 1); if (s->error) return; }
    } while ((rc = dwarf_siblingof(&d, &d)) == 0);
    if (rc < 0) s->error = "DwarfTypesMalformed";
}
const char *xdt_layout_build(Dwarf *dwarf, const struct xdt_schema *schema, uint64_t work,
                             struct xdt_slot *fields, uint32_t *sizes, struct xdt_stats *stats) {
    struct xdt_stats local;
    if (!stats) stats = &local;
    memset(stats, 0, sizeof *stats);
    if (!schema || !schema->type_count || schema->type_count > XDT_MAX_TYPES || schema->field_count > XDT_MAX_FIELDS) return "DwarfTypesSchemaLimit";
    memset(fields, 0, schema->field_count * sizeof *fields);
    memset(sizes, 0, schema->type_count * sizeof *sizes);
    for (unsigned f = 0; f < schema->field_count; ++f) if (schema->fields[f].owner >= schema->type_count) return "DwarfTypesSchemaLimit";
    if (!dwarf) return "DwarfTypesUnavailable";
    struct scan s = {.schema = schema, .fields = fields, .sizes = sizes, .stats = stats, .limit = work};
    Dwarf_Off off = 0, next; size_t header;
    int rc;
    while ((rc = dwarf_nextcu(dwarf, off, &next, &header, NULL, NULL, NULL)) == 0) {
        Dwarf_Die unit;
        if (++stats->units > 1u << 20) { s.error = "DwarfTypesUnitLimit"; break; }
        if (next <= off || !dwarf_offdie(dwarf, off + header, &unit)) { s.error = "DwarfTypesMalformed"; break; }
        scope(&s, &unit, schema->types, 0);
        if (s.error) break;
        off = next;
    }
    if (rc < 0 && !s.error) s.error = "DwarfTypesMalformed";
    stats->work = s.work;
    if (!s.error && !stats->units) s.error = "DwarfTypesUnavailable";
    for (unsigned t = 0; !s.error && t < schema->type_count; ++t) if (!stats->definitions[t]) s.error = "DwarfTypeNotFound";
    if (s.error) {
        memset(fields, 0, schema->field_count * sizeof *fields);
        memset(sizes, 0, schema->type_count * sizeof *sizes);
    }
    return s.error;
}
