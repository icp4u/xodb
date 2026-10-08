#include "javascript_ranged.h"
#include "javascript_checks.h"
#include "../debug/dwarf_constants.h"
#include <stdlib.h>

struct scope { unsigned ns; uint64_t owners; };
struct xjs_ranged {
    struct xbo_object *object;
    struct xdw_cursor *cursor;
    struct xbo_budget *budget;
    struct scope scopes[130];
    struct xjs_dwarf_profile profile;
    uint64_t observations;
    enum xbo_status failure;
    int complete;
    uint64_t *units;
    size_t unit_count, unit_next;
    int selected;
    uint64_t completed_dies;
};
static int integer_form(unsigned form) {
    return form == DW_FORM_data1 || form == DW_FORM_data2 ||
        form == DW_FORM_data4 || form == DW_FORM_data8 ||
        form == DW_FORM_udata || form == DW_FORM_sdata ||
        form == DW_FORM_implicit_const;
}
static enum xbo_status visit(void *context, const struct xdw_die *die,
                             enum xdw_action *action) {
    struct xjs_ranged *p = context;
    if (die->depth >= 129 || die->address_size != 8) return XBO_MALFORMED;
    if (!die->depth) {
        p->scopes[1] = (struct scope){0};
        return XBO_OK;
    }
    struct scope current = p->scopes[die->depth], child = current;
    *action = XDW_SKIP_CHILDREN;
    if (die->tag != DW_TAG_namespace && current.ns != 2) return XBO_OK;
    const struct xdw_attribute *value = xdw_attribute(die, DW_AT_const_value);
    if (die->tag != DW_TAG_namespace && die->tag != DW_TAG_class_type &&
        die->tag != DW_TAG_structure_type && die->tag != DW_TAG_enumeration_type && !value)
        return XBO_OK;
    char name[65536];
    enum xbo_status status = xdw_name(p->cursor, die, name, sizeof name, p->budget);
    if (status != XBO_OK && status != XBO_NOT_FOUND) return status;
    if (status == XBO_NOT_FOUND) name[0] = 0;
    uint64_t fields = p->profile.fields, observations = p->observations;
    if (die->tag == DW_TAG_namespace) {
        if (!current.ns && !strcmp(name, "v8")) child = (struct scope){1, 0};
        else if (current.ns == 1 && !strcmp(name, "internal")) child = (struct scope){2, 0};
        else return XBO_OK;
        *action = XDW_DESCEND;
    } else {
        if (value) for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i) {
            if (strcmp(name, checks[i].name)) continue;
            if (!(current.owners & (UINT64_C(1) << i)) &&
                (current.owners || *checks[i].owner)) continue;
            if (!integer_form(value->form)) {
                p->profile.error = "JavaScriptDwarfConstantUnsupported";
                return XBO_LIMIT;
            }
            if (value->value != checks[i].value) {
                p->profile.error = "JavaScriptDwarfLayoutMismatch";
                return XBO_MALFORMED;
            }
            fields |= UINT64_C(1) << i;
            ++observations;
        }
        if (die->tag == DW_TAG_class_type || die->tag == DW_TAG_structure_type ||
            die->tag == DW_TAG_enumeration_type) {
            if (die->tag != DW_TAG_enumeration_type || !current.owners) {
                child.owners = 0;
                for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i)
                    if (owner_match(name, checks[i].owner)) child.owners |= UINT64_C(1) << i;
            }
            if (child.owners) *action = XDW_DESCEND;
        }
    }
    /* No resumable operation follows publication of this DIE's observations. */
    p->profile.fields = fields;
    p->observations = observations;
    p->scopes[die->depth + 1] = child;
    return XBO_OK;
}
enum xbo_status xjs_ranged_create(struct xbo_object *object, struct xjs_ranged **out) {
    if (!object || !out) return XBO_MALFORMED;
    *out = NULL;
    struct xjs_ranged *p = calloc(1, sizeof *p);
    if (!p) return XBO_NOMEM;
    p->object = object;
    uint32_t index;
    enum xbo_status status = xbo_find_section(object, ".debug_info", &index);
    if (status == XBO_NOT_FOUND) {
        if (xbo_find_section(object, ".zdebug_info", &index) == XBO_OK) status = XBO_LIMIT;
        else { p->complete = 1; status = XBO_OK; }
    } else if (status == XBO_OK) {
        if (!xbo_section(object, index)->size) status = XBO_MALFORMED;
        else {
            status = xdw_create(object, &p->cursor);
            if (status == XBO_NOT_FOUND) status = XBO_MALFORMED;
        }
    }
    if (status != XBO_OK) { free(p); return status; }
    *out = p;
    return XBO_OK;
}
size_t xjs_ranged_names(const char **out, size_t capacity) {
    size_t count = sizeof checks / sizeof *checks;
    if (out && capacity >= count) for (size_t n = 0; n < count; ++n) out[n] = checks[n].name;
    return count;
}
enum xbo_status xjs_ranged_create_units(struct xbo_object *object, const uint64_t *units,
        size_t count, struct xjs_ranged **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (count > 16384) return XBO_LIMIT;
    if (count && !units) return XBO_MALFORMED;
    for (size_t n = 1; n < count; ++n) if (units[n] <= units[n-1]) return XBO_MALFORMED;
    struct xjs_ranged *p;
    enum xbo_status status = xjs_ranged_create(object, &p);
    if (status != XBO_OK) return status;
    p->selected = 1; p->unit_count = count;
    if (!count) p->complete = 1;
    else {
        if (!p->cursor) { xjs_ranged_destroy(p); return XBO_MALFORMED; }
        p->units = malloc(count * sizeof *p->units);
        if (!p->units) { xjs_ranged_destroy(p); return XBO_NOMEM; }
        memcpy(p->units, units, count * sizeof *units);
        status = xdw_select_unit(p->cursor, units[0]);
        if (status != XBO_OK) { xjs_ranged_destroy(p); return status; }
    }
    *out = p; return XBO_OK;
}
void xjs_ranged_destroy(struct xjs_ranged *p) {
    if (!p) return;
    xdw_destroy(p->cursor);
    free(p->units);
    free(p);
}
enum xbo_status xjs_ranged_step(struct xjs_ranged *p, struct xbo_budget *budget, uint64_t work) {
    if (!p || !budget) return XBO_MALFORMED;
    if (p->failure) return p->failure;
    p->budget = budget;
    enum xbo_status status = p->complete ? xbo_validate(p->object, budget) :
        xdw_walk(p->cursor, budget, work, visit, p);
    p->budget = NULL;
    if (status == XBO_OK && !p->complete) {
        struct xdw_progress progress;
        xdw_progress(p->cursor, &progress);
        p->complete = progress.complete;
        if (p->complete && p->selected && ++p->unit_next < p->unit_count) {
            p->completed_dies += progress.dies;
            status = xdw_select_unit(p->cursor, p->units[p->unit_next]);
            p->complete = 0;
            if (status != XBO_OK) { p->failure = status; return status; }
        }
        if (!p->complete) status = XBO_AGAIN;
    }
    if (status != XBO_OK && status != XBO_AGAIN && status != XBO_CANCELLED) {
        p->failure = status;
        if (!p->profile.error) p->profile.error = status == XBO_CHANGED ? "JavaScriptDwarfFileChanged" :
            status == XBO_LIMIT ? "JavaScriptDwarfLimit" :
            status == XBO_IO ? "JavaScriptDwarfUnavailable" : "JavaScriptDwarfMalformed";
    }
    return status;
}
enum xbo_status xjs_ranged_result(const struct xjs_ranged *p, struct xjs_dwarf_profile *out) {
    if (!out) return XBO_MALFORMED;
    memset(out, 0, sizeof *out);
    if (!p) { out->error = "JavaScriptDwarfUnavailable"; return XBO_MALFORMED; }
    if (p->failure) { out->error = p->profile.error; return p->failure; }
    if (!p->complete) { out->error = "JavaScriptDwarfPending"; return XBO_AGAIN; }
    *out = p->profile;
    uint64_t required = 0;
    for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i)
        if (checks[i].frame_config) required |= UINT64_C(1) << i;
    out->frame_config = (out->fields & required) == required;
    return XBO_OK;
}
void xjs_ranged_progress(const struct xjs_ranged *p, struct xjs_ranged_progress *out) {
    memset(out, 0, sizeof *out);
    if (!p) return;
    if (p->cursor) xdw_progress(p->cursor, &out->dwarf);
    if (p->selected) {
        out->dwarf.dies += p->completed_dies;
        out->dwarf.units = p->unit_next + (!p->complete && out->dwarf.units != 0);
    }
    out->complete = p->complete && !p->failure;
    out->observed_fields = p->profile.fields;
    out->observations = p->observations;
}
