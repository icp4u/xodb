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
    uint8_t seen[XDT_MAX_FIELDS];
    uint64_t dropped; /* optional types whose definitions were not usable */
};
/* An optional type that is not what the schema expects, or that two units
 * define differently, is left out; the other types keep their answers. */
static void settle(struct scan *s, unsigned t) {
    if (!s->error || !(s->schema->optional_types >> t & 1)) return;
    if (strcmp(s->error, "DwarfTypeAmbiguous") && strcmp(s->error, "DwarfFieldNotFound") && strcmp(s->error, "DwarfFieldMismatch")) return;
    s->dropped |= 1ull << t;
    s->error = NULL;
}
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
/* What one definition gave for types[t], against the ones before it. */
static void merge(struct scan *s, unsigned t, const struct xdt_slot *got, uint64_t total) {
    const struct xdt_schema *schema = s->schema;
    for (unsigned f = 0; f < schema->field_count; ++f) {
        if (schema->fields[f].owner != t || got[f].present == 2) continue;
        if (!got[f].present && !schema->fields[f].optional) { s->error = "DwarfFieldNotFound"; return; }
        if (s->seen[f] && (got[f].offset != s->fields[f].offset || got[f].size != s->fields[f].size ||
                           got[f].present != s->fields[f].present)) { s->error = "DwarfTypeAmbiguous"; return; }
        s->fields[f] = got[f]; s->seen[f] = 1;
    }
    if (s->stats->definitions[t] && s->sizes[t] != (uint32_t)total) { s->error = "DwarfTypeAmbiguous"; return; }
    s->sizes[t] = (uint32_t)total;
    if (s->stats->definitions[t] != UINT32_MAX) ++s->stats->definitions[t];
}
/* The data member `name[0..len)` of `type`: 1 with its offset and resolved
 * type, 0 when there is none, -1 with s->error set. */
static int member_of(struct scan *s, Dwarf_Die *type, const char *name, size_t len, uint64_t *at, Dwarf_Die *out) {
    Dwarf_Die child; int found = 0;
    int rc = dwarf_child(type, &child);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return -1; }
    if (rc == 0) do {
        if (!tick(s)) return -1;
        if (dwarf_tag(&child) != DW_TAG_member) continue;
        const char *have = dwarf_diename(&child);
        if (!have || strncmp(have, name, len) || have[len]) continue;
        if (dwarf_hasattr(&child, DW_AT_bit_size) || dwarf_hasattr(&child, DW_AT_data_bit_offset)) { s->error = "DwarfFieldMismatch"; return -1; }
        if (!ud(&child, DW_AT_data_member_location, at)) continue;
        if (found) { s->error = "DwarfTypeAmbiguous"; return -1; }
        if (!type_of(&child, out) || !resolve(out, s)) {
            if (!s->error) s->error = "DwarfFieldMismatch";
            return -1;
        }
        found = 1;
    } while ((rc = dwarf_siblingof(&child, &child)) == 0);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return -1; }
    return found;
}
/* The rest of a member path, through members held by value: 1 found, 0 when
 * this unit only declares a type on the way or the member is absent
 * (*absent), -1 with s->error set. */
static int nested(struct scan *s, Dwarf_Die *type, const char *path, uint64_t *at, int *absent) {
    for (unsigned depth = 0; depth < 8; ++depth) {
        size_t len = strcspn(path, ".");
        uint64_t inner; Dwarf_Die next;
        if (!aggregate(dwarf_tag(type))) { s->error = "DwarfFieldMismatch"; return -1; }
        if (flag(type, DW_AT_declaration)) return 0;
        int rc = member_of(s, type, path, len, &inner, &next);
        if (rc < 0) return -1;
        if (!rc) { *absent = 1; return 0; }
        if (inner > 1u << 24 || *at > 1u << 24) { s->error = "DwarfFieldMismatch"; return -1; }
        *at += inner; *type = next;
        if (!path[len]) return 1;
        path += len + 1;
    }
    s->error = "DwarfFieldMismatch";
    return -1;
}
/* One complete definition of types[t]: every requested member, checked. */
static void definition(struct scan *s, unsigned t, Dwarf_Die *die) {
    const struct xdt_schema *schema = s->schema;
    struct xdt_slot got[XDT_MAX_FIELDS];
    uint64_t total;
    memset(got, 0, schema->field_count * sizeof got[0]);
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
            if (field->owner != t) continue;
            size_t len = strcspn(field->name, ".");
            if (strncmp(name, field->name, len) || name[len]) continue;
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
            if (field->name[len]) {
                int absent = 0, found = nested(s, &member, field->name + len + 1, &at, &absent);
                if (found < 0) return;
                if (!found) { got[f].present = absent ? 0 : 2; continue; }
            }
            if (dwarf_tag(&member) == DW_TAG_pointer_type || dwarf_tag(&member) == DW_TAG_reference_type) bytes = 8;
            else if (!byte_size(&member, &bytes)) { s->error = "DwarfFieldMismatch"; return; }
            if (at > total || bytes > total - at || !kind_matches(&member, field->kind) ||
                (field->width && bytes != field->width)) { s->error = "DwarfFieldMismatch"; return; }
            got[f] = (struct xdt_slot){(uint32_t)at, (uint32_t)bytes, 1};
        }
    } while ((rc = dwarf_siblingof(&child, &child)) == 0);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    merge(s, t, got, total);
}
/* One complete enumeration types[t]: each requested enumerator's value. */
static void enumeration(struct scan *s, unsigned t, Dwarf_Die *die) {
    const struct xdt_schema *schema = s->schema;
    struct xdt_slot got[XDT_MAX_FIELDS];
    uint64_t total;
    memset(got, 0, schema->field_count * sizeof got[0]);
    if (!ud(die, DW_AT_byte_size, &total) || !total || total > 8) { s->error = "DwarfTypesMalformed"; return; }
    Dwarf_Die child;
    int rc = dwarf_child(die, &child);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    if (rc == 0) do {
        if (!tick(s)) return;
        if (dwarf_tag(&child) != DW_TAG_enumerator) continue;
        const char *name = dwarf_diename(&child);
        if (!name) continue;
        for (unsigned f = 0; f < schema->field_count; ++f) {
            uint64_t value;
            if (schema->fields[f].owner != t || strcmp(name, schema->fields[f].name)) continue;
            if (got[f].present) { s->error = "DwarfTypeAmbiguous"; return; }
            if (!ud(&child, DW_AT_const_value, &value) || value > UINT32_MAX) { s->error = "DwarfFieldMismatch"; return; }
            got[f] = (struct xdt_slot){(uint32_t)value, 0, 1};
        }
    } while ((rc = dwarf_siblingof(&child, &child)) == 0);
    if (rc < 0) { s->error = "DwarfTypesMalformed"; return; }
    merge(s, t, got, total);
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
        if (!aggregate(tag) && tag != DW_TAG_namespace && tag != DW_TAG_enumeration_type) continue;
        const char *name = dwarf_diename(&d);
        if (!name) continue;
        size_t len = strlen(name);
        const char *inner[XDT_MAX_TYPES]; int descend = 0;
        for (unsigned t = 0; t < s->schema->type_count; ++t) {
            inner[t] = NULL;
            if (!rest[t] || strncmp(rest[t], name, len)) continue;
            if (!rest[t][len]) {
                if (!(s->dropped >> t & 1) && !flag(&d, DW_AT_declaration) && dwarf_hasattr(&d, DW_AT_byte_size)) {
                    if (aggregate(tag)) definition(s, t, &d);
                    else if (tag == DW_TAG_enumeration_type) enumeration(s, t, &d);
                    settle(s, t);
                }
                if (s->error) return;
            } else if (tag != DW_TAG_enumeration_type && rest[t][len] == ':' && rest[t][len + 1] == ':') { inner[t] = rest[t] + len + 2; descend = 1; }
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
    for (unsigned t = 0; !s.error && t < schema->type_count; ++t)
        if (!stats->definitions[t] && !(schema->optional_types >> t & 1)) s.error = "DwarfTypeNotFound";
    /* A member path that no unit could follow to its end. */
    for (unsigned f = 0; !s.error && f < schema->field_count; ++f)
        if (!s.seen[f] && !schema->fields[f].optional && stats->definitions[schema->fields[f].owner]) {
            s.error = "DwarfFieldNotFound";
            settle(&s, schema->fields[f].owner);
        }
    for (unsigned t = 0; !s.error && t < schema->type_count; ++t) {
        if (!(s.dropped >> t & 1)) continue;
        sizes[t] = 0; stats->definitions[t] = 0;
        for (unsigned f = 0; f < schema->field_count; ++f) if (schema->fields[f].owner == t) fields[f] = (struct xdt_slot){0, 0, 0};
    }
    stats->dropped = s.dropped;
    if (s.error) {
        memset(fields, 0, schema->field_count * sizeof *fields);
        memset(sizes, 0, schema->type_count * sizeof *sizes);
    }
    return s.error;
}
