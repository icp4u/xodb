#include "perl.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* Perl 5.44.0 sv.h/cop.h/cv.h/hv.h macro rules. The caller first verifies the
 * profile's version and build identity; all offsets are DWARF-derived. */
enum { SV_IV = 1, SV_NV = 2, SV_PV = 3, SV_PVIV = 5, SV_PVNV = 6, SV_GV = 9, SV_AV = 11, SV_HV = 12, SV_CV = 13 };
enum {
    IOK = 0x100,
    NOK = 0x200,
    POK = 0x400,
    ROK = 0x800,
    UV_FLAG = 0x80000000u,
    HV_AUX = 0x02000000,
    CV_NAMED = 0x8000
};
static int read_bytes(struct xpl_reader *r, uint64_t address, void *out, size_t n) {
    if (r->error)
        return 0;
    if (!address || address > UINT64_MAX - n) {
        r->error = "InvalidAddress";
        return 0;
    }
    if (r->reads >= 8192 || r->bytes > 512 * 1024 || n > 512 * 1024 - r->bytes) {
        r->error = "PerlReadLimit";
        return 0;
    }
    ++r->reads;
    r->bytes += n;
    if (r->read(r->context, address, out, n)) {
        r->error = "MemoryUnreadable";
        return 0;
    }
    return 1;
}
static uint64_t number(struct xpl_reader *r, uint64_t address, unsigned n) {
    uint8_t bytes[8] = {0};
    if (!n || n > 8 || !read_bytes(r, address, bytes, n))
        return 0;
    uint64_t value = 0;
    for (unsigned i = 0; i < n; ++i)
        value |= (uint64_t)bytes[i] << (8 * i);
    return value;
}
static uint64_t at(const struct xpl_layout *l, struct xpl_reader *r, uint64_t base, enum xpl_field f) {
    if (!base || base > UINT64_MAX - l->fields[f].offset) {
        r->error = "InvalidAddress";
        return 0;
    }
    return number(r, base + l->fields[f].offset, l->fields[f].size);
}
static int cstring(struct xpl_reader *r, uint64_t address, char *out, size_t cap) {
    out[0] = 0;
    if (!address)
        return 0;
    /* Linux x86-64 profile: read small chunks within each 4096-byte page.
     * A terminator before an unmapped next page must not require that page. */
    for (size_t i = 0; i + 1 < cap;) {
        if (address > UINT64_MAX - i) {
            r->error = "InvalidAddress";
            break;
        }
        size_t n = 4096 - (size_t)((address + i) & 4095);
        if (n > 256) n = 256;
        if (n > cap - 1 - i) n = cap - 1 - i;
        if (!read_bytes(r, address + i, out + i, n)) break;
        if (memchr(out + i, 0, n)) return 1;
        i += n;
    }
    /* An incomplete path must never be exposed as a usable source identity. */
    out[0] = 0;
    return 0;
}

static int hek(const struct xpl_layout *l, struct xpl_reader *r, uint64_t address, char *out, size_t cap) {
    int32_t n = (int32_t)at(l, r, address, XPL_HEKLEN);
    out[0] = 0;
    if (r->error || n < 0 || (uint32_t)n >= cap || address > UINT64_MAX - l->fields[XPL_HEKKEY].offset)
        return 0;
    if (!read_bytes(r, address + l->fields[XPL_HEKKEY].offset, out, (size_t)n))
        return 0;
    out[n] = 0;
    return !memchr(out, 0, (size_t)n); /* never shorten an embedded-NUL identity */
}
static int head(const struct xpl_layout *l, struct xpl_reader *r, uint64_t sv, uint64_t *body, uint32_t *flags,
                uint32_t *refs) {
    *flags = (uint32_t)at(l, r, sv, XPL_FLAGS);
    *refs = (uint32_t)at(l, r, sv, XPL_REFCNT);
    *body = at(l, r, sv, XPL_ANY);
    return !r->error && (*flags & 255) != 255 && *refs;
}
static int stash_name(const struct xpl_layout *l, struct xpl_reader *r, uint64_t hv, char *out, size_t cap) {
    uint64_t body;
    uint32_t flags, refs;
    if (!head(l, r, hv, &body, &flags, &refs) || (flags & 255) != SV_HV || !(flags & HV_AUX))
        return 0;
    if (body > UINT64_MAX - l->fields[XPL_HVAUX].offset)
        return 0;
    uint64_t aux = body + l->fields[XPL_HVAUX].offset;
    int32_t count = (int32_t)at(l, r, aux, XPL_HVNAMECOUNT);
    uint64_t name = at(l, r, aux, XPL_HVNAME);
    if (count)
        name = number(r, name, 8); /* HvNAME, not effective-name alias */
    return name && hek(l, r, name, out, cap);
}
static int cv_name(const struct xpl_layout *l, struct xpl_reader *r, uint64_t cv, char *out, size_t cap) {
    uint64_t body;
    uint32_t flags, refs;
    if (!head(l, r, cv, &body, &flags, &refs) || (flags & 255) != SV_CV || !body)
        return 0;
    uint64_t stash = at(l, r, body, XPL_CVSTASH), name = at(l, r, body, XPL_CVNAME);
    uint32_t cvflags = (uint32_t)at(l, r, body, XPL_CVFLAGS);
    char short_name[192] = {0}, package[128] = {0};
    if (!name)
        return 0;
    if (!(cvflags & CV_NAMED)) {
        uint64_t gv_body;
        uint32_t gv_flags, gv_refs;
        if (!head(l, r, name, &gv_body, &gv_flags, &gv_refs) || ((gv_flags & 255) != SV_GV && (gv_flags & 255) != 10))
            return 0;
        name = at(l, r, gv_body, XPL_GVNAME);
        stash = at(l, r, gv_body, XPL_GVSTASH);
    }
    if (!name || !hek(l, r, name, short_name, sizeof short_name))
        return 0;
    if (strstr(short_name, "::"))
        return snprintf(out, cap, "%s", short_name) < (int)cap;
    if (!stash || !stash_name(l, r, stash, package, sizeof package))
        return 0;
    return snprintf(out, cap, "%s::%s", package, short_name) < (int)cap;
}
struct file_cache { uint64_t address; const struct xpl_frame *frame; };
static void location(const struct xpl_layout *l, struct xpl_reader *r, uint64_t cop, struct xpl_frame *f,
                     struct file_cache *cache, unsigned *cache_count) {
    if (!cop) {
        f->reason = "CopUnavailable";
        return;
    }
    f->line = (uint32_t)at(l, r, cop, XPL_COPLINE);
    uint64_t path = at(l, r, cop, XPL_COPFILE);
    int cached = 0;
    for (unsigned i = 0; i < *cache_count; ++i) {
        if (cache[i].address != path) continue;
        memcpy(f->file, cache[i].frame->file, sizeof f->file);
        cached = 1;
        break;
    }
    if (!cached) {
        if (!path || !cstring(r, path, f->file, sizeof f->file)) {
            f->file[0] = 0;
            f->reason = r->error ? r->error : "FileNameUnavailableOrTruncated";
        } else if (*cache_count < XPL_MAX_FRAMES) {
            cache[(*cache_count)++] = (struct file_cache){path, f};
        }
    }
    if (!f->line && !f->reason)
        f->reason = "LineUnavailable";
}
void xpl_stack_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter, struct xpl_stack *out) {
    memset(out, 0, sizeof *out);
    out->interpreter = interpreter;
    uint64_t cop = at(l, r, interpreter, XPL_CURCOP), si = at(l, r, interpreter, XPL_STACKINFO);
    out->op = at(l, r, interpreter, XPL_OP);
    out->stackinfo = si;
    if (!si || r->error) {
        out->reason = r->error ? r->error : "StackInfoUnavailable";
        return;
    }
    uint64_t visited[32];
    unsigned stacks = 0, contexts = 0, cache_count = 0;
    struct file_cache cache[XPL_MAX_FRAMES];
    while (si && !r->error) {
        for (unsigned j = 0; j < stacks; ++j)
            if (visited[j] == si) {
                out->reason = "StackInfoCycle";
                return;
            }
        if (stacks == 32) {
            out->reason = "StackInfoLimit";
            return;
        }
        visited[stacks++] = si;
        uint64_t array = at(l, r, si, XPL_CXSTACK);
        int32_t ix = (int32_t)at(l, r, si, XPL_CXIX), max = (int32_t)at(l, r, si, XPL_CXMAX);
        if (r->error)
            break;
        if (ix < -1 || max < -1 || ix > max || max > 1048576 || (ix >= 0 && !array)) {
            out->reason = "ContextIndexInvalid";
            return;
        }
        for (; ix >= 0; --ix) {
            if (++contexts > 4096) {
                out->reason = "ContextLimit";
                return;
            }
            uint64_t delta = (uint64_t)(uint32_t)ix * l->context_size;
            if (array > UINT64_MAX - delta) {
                out->reason = "ContextAddressOverflow";
                return;
            }
            uint64_t address = array + delta;
            unsigned kind = (unsigned)at(l, r, address, XPL_CXTYPE) & 15;
            if (r->error)
                break;
            if (kind > 13) {
                out->reason = "ContextTypeInvalid";
                return;
            }
            /* Block/loop oldcop is not the enclosing subroutine's call site. */
            if (kind != 9 && kind != 10 && kind != 11)
                continue;
            if (out->count == XPL_MAX_FRAMES) {
                out->reason = "FrameLimit";
                return;
            }
            struct xpl_frame *f = &out->frames[out->count++];
            f->context_type = kind;
            f->context_address = address;
            f->cv = at(l, r, address, kind == 11 ? XPL_EVALCV : XPL_SUBCV);
            location(l, r, cop, f, cache, &cache_count);
            if (kind == 11) {
                snprintf(f->name, sizeof f->name, "(eval)");
                /* CxOLD_OP_TYPE is blk_u16 >> 7; OP_ENTEREVAL is 352 in
                 * the verified 5.44.0 profile. Block eval, try, G_EVAL and
                 * ithread entry legitimately have no eval CV. */
                if (!f->cv && !f->reason && (at(l, r, address, XPL_EVALOP) >> 7) == 352)
                    f->reason = "EvalCvUnavailable";
            } else if (!f->cv || !cv_name(l, r, f->cv, f->name, sizeof f->name)) {
                snprintf(f->name, sizeof f->name, "(unavailable sub)");
                f->reason = r->error ? r->error : "CvNameUnavailable";
            }
            if (f->reason && !out->reason)
                out->reason = "PartialFrames";
            cop = at(l, r, address, XPL_OLDCOP);
            if (r->error)
                break;
        }
        if (r->error)
            break;
        si = at(l, r, si, XPL_SIPREV);
    }
    if (r->error) {
        out->reason = r->error;
        return;
    }
    if (out->count == XPL_MAX_FRAMES) {
        out->reason = "FrameLimit";
        return;
    }
    struct xpl_frame *main = &out->frames[out->count++];
    main->cv = at(l, r, interpreter, XPL_MAINCV);
    main->context_type = 0;
    snprintf(main->name, sizeof main->name, "main");
    location(l, r, cop, main, cache, &cache_count);
    if (!main->cv && !main->reason)
        main->reason = "MainCvUnavailable";
    if (main->reason || r->error)
        out->reason = r->error ? r->error : "PartialFrames";
}
static void value(const struct xpl_layout *, struct xpl_reader *, uint64_t, struct xpl_value *, unsigned);
static void item(const struct xpl_layout *l, struct xpl_reader *r, uint64_t address, struct xpl_value_item *out,
                 unsigned depth) {
    out->address = address;
    if (!address) {
        strcpy(out->type, "hole");
        strcpy(out->display, "absent slot");
        return;
    }
    struct xpl_value child;
    value(l, r, address, &child, depth);
    snprintf(out->type, sizeof out->type, "%s", child.type);
    snprintf(out->display, sizeof out->display, "%.191s", child.display);
    out->reason = child.reason;
}
static void value(const struct xpl_layout *l, struct xpl_reader *r, uint64_t address, struct xpl_value *out,
                  unsigned depth) {
    memset(out, 0, sizeof *out);
    out->address = address;
    if (!head(l, r, address, &out->body, &out->flags, &out->refcount)) {
        strcpy(out->type, "unavailable");
        out->reason = r->error ? r->error : (out->flags & 255) == 255 ? "FreedSv" : "ZeroRefcount";
        snprintf(out->display, sizeof out->display, "%s", out->reason);
        return;
    }
    unsigned type = out->flags & 255;
    out->stored_value_only = (out->flags & (0x00200000u | 0x00800000u)) != 0;
    out->utf8 = (out->flags & 0x20000000u) != 0;
    uint64_t u = at(l, r, address, XPL_UNION);
    if (r->error)
        goto unreadable;
    if (type == 16) { /* SVt_PVOBJ: valid class object, unsupported preview. */
        strcpy(out->type, "unsupported");
        strcpy(out->display, "SVt_PVOBJ (class object)");
        out->reason = "SvTypeUnsupported";
        return;
    }
    if (type > 16 || ((out->flags & ROK) && (type >= SV_AV || (out->flags & (IOK | NOK | POK)))))
        goto inconsistent;
    /* Scalar validity bits must agree with every advertised storage slot,
     * even when the chosen display prefers one of several cached values.
     * Container flags have their own meanings and are handled separately. */
    if (type < SV_AV && (((out->flags & IOK) && type != SV_IV && (type < SV_PVIV || type > 10)) ||
                         ((out->flags & NOK) && type != SV_NV && (type < SV_PVNV || type > 10)) ||
                         ((out->flags & POK) && type != SV_PV && (type < SV_PVIV || type > 10))))
        goto inconsistent;
    if ((out->flags & ROK) && type == 0)
        goto inconsistent;
    if (out->flags & ROK) {
        strcpy(out->type, "RV");
        if (!u)
            goto inconsistent;
        snprintf(out->display, sizeof out->display, "RV -> 0x%" PRIx64, u);
        if (!depth) {
            item(l, r, u, &out->items[out->item_count++], 1);
            strcpy(out->items[0].key, "referent");
        }
    } else if (type == SV_AV) {
        strcpy(out->type, "AV");
        int64_t fill = (int64_t)at(l, r, out->body, XPL_AVFILL), max = (int64_t)at(l, r, out->body, XPL_AVMAX);
        if (r->error)
            goto unreadable;
        if (fill < -1 || max < -1 || fill > max || fill == INT64_MAX || (fill >= 0 && !u))
            goto inconsistent;
        out->count = (uint64_t)(fill + 1);
        snprintf(out->display, sizeof out->display, "AV (%" PRIu64 " slots)", out->count);
        if (!depth)
            for (uint64_t i = 0; i < out->count && i < XPL_MAX_PREVIEW; ++i) {
                if (u > UINT64_MAX - i * 8)
                    goto inconsistent;
                uint64_t sv = number(r, u + i * 8, 8);
                struct xpl_value_item *entry = &out->items[out->item_count++];
                item(l, r, sv, entry, 1);
                snprintf(entry->key, sizeof entry->key, "[%" PRIu64 "]", i);
                if (r->error)
                    break;
            }
        out->truncated = out->count > out->item_count;
    } else if (type == SV_HV) {
        strcpy(out->type, "HV");
        out->count = at(l, r, out->body, XPL_HVKEYS);
        uint64_t max = at(l, r, out->body, XPL_HVMAX);
        if (r->error)
            goto unreadable;
        if (max == UINT64_MAX || (out->count && !u))
            goto inconsistent;
        snprintf(out->display, sizeof out->display, "HV (%" PRIu64 " entries)", out->count);
        unsigned visited = 0;
        uint64_t seen[64];
        if (!depth && out->count)
            for (uint64_t bucket = 0; bucket <= max && bucket < 256 && out->item_count < XPL_MAX_PREVIEW; ++bucket) {
                if (u > UINT64_MAX - bucket * 8)
                    goto inconsistent;
                uint64_t he = number(r, u + bucket * 8, 8);
                while (he && out->item_count < XPL_MAX_PREVIEW && visited < 64 && !r->error) {
                    for (unsigned i = 0; i < visited; ++i)
                        if (seen[i] == he) {
                            out->reason = "HashEntryCycle";
                            out->truncated = 1;
                            return;
                        }
                    if (out->item_count >= out->count)
                        goto inconsistent;
                    seen[visited++] = he;
                    uint64_t key = at(l, r, he, XPL_HEKEY), sv = at(l, r, he, XPL_HEVAL);
                    struct xpl_value_item *entry = &out->items[out->item_count++];
                    item(l, r, sv, entry, 1);
                    if (!key || !hek(l, r, key, entry->key, sizeof entry->key)) {
                        strcpy(entry->key, "(key unavailable)");
                        entry->reason = r->error ? r->error : "HashKeyUnavailable";
                    }
                    he = at(l, r, he, XPL_HENEXT);
                }
            }
        out->truncated = out->count > out->item_count;
    } else if (type == SV_CV) {
        strcpy(out->type, "CV");
        if (!cv_name(l, r, address, out->display, sizeof out->display)) {
            strcpy(out->display, "CV (name unavailable)");
            out->reason = "CvNameUnavailable";
        }
    } else if (type == SV_GV) {
        strcpy(out->type, "GV");
        uint64_t name = at(l, r, out->body, XPL_GVNAME);
        if (!name || !hek(l, r, name, out->display, sizeof out->display)) {
            strcpy(out->display, "GV (name unavailable)");
            out->reason = "GvNameUnavailable";
        }
    } else if (out->flags & POK) {
        if (type != SV_PV && (type < SV_PVIV || type > 10))
            goto inconsistent;
        strcpy(out->type, "PV");
        uint64_t n = at(l, r, out->body, XPL_PVCUR), capacity = at(l, r, out->body, XPL_PVLEN);
        if (r->error)
            goto unreadable;
        if ((capacity && n >= capacity) || (!u && n))
            goto inconsistent;
        out->count = n;
        out->byte_count = n < sizeof out->bytes ? (size_t)n : sizeof out->bytes;
        if (out->byte_count && !read_bytes(r, u, out->bytes, out->byte_count))
            goto unreadable;
        out->truncated = n > out->byte_count;
        size_t pos = (size_t)snprintf(out->display, sizeof out->display, "PV \"");
        size_t rendered = 0;
        for (; rendered < out->byte_count && pos + 9 < sizeof out->display; ++rendered) {
            unsigned c = out->bytes[rendered];
            if (c >= 32 && c < 127 && c != '"' && c != '\\')
                out->display[pos++] = (char)c;
            else
                pos += (size_t)snprintf(out->display + pos, sizeof out->display - pos, "\\x%02x", c);
        }
        out->truncated |= rendered < out->byte_count;
        snprintf(out->display + pos, sizeof out->display - pos, "\"%s", out->truncated ? "..." : "");
    } else if (out->flags & IOK) {
        if (type != SV_IV && (type < SV_PVIV || type > 10))
            goto inconsistent;
        strcpy(out->type, "IV");
        uint64_t iv = type == SV_IV ? u : at(l, r, out->body, XPL_IV);
        if (out->flags & UV_FLAG)
            snprintf(out->display, sizeof out->display, "UV %" PRIu64, iv);
        else
            snprintf(out->display, sizeof out->display, "IV %" PRId64, (int64_t)iv);
    } else if (out->flags & NOK) {
        if (type != SV_NV && (type < SV_PVNV || type > 10))
            goto inconsistent;
        strcpy(out->type, "NV");
        uint64_t bits = at(l, r, out->body, XPL_NV);
        double n;
        memcpy(&n, &bits, sizeof n);
        snprintf(out->display, sizeof out->display, "NV %.17g", n);
    } else if (type <= 10) {
        strcpy(out->type, "undef");
        strcpy(out->display, "undef");
        /* sv_u can contain stale bytes. No value-valid flag means no value. */
    } else {
        strcpy(out->type, "unsupported");
        snprintf(out->display, sizeof out->display, "SV type %u", type);
        out->reason = "SvTypeUnsupported";
    }
    if (r->error)
        goto unreadable;
    if (out->stored_value_only && !out->reason)
        out->reason = "StoredValueOnlyMagicNotInvoked";
    return;
inconsistent:
    out->reason = "InconsistentSv";
    strcpy(out->type, "inconsistent");
    strcpy(out->display, "inconsistent SV flags/body");
    return;
unreadable:
    out->reason = r->error ? r->error : "MemoryUnreadable";
    if (!out->type[0])
        strcpy(out->type, "unavailable");
    snprintf(out->display, sizeof out->display, "%s (%s)", out->type, out->reason);
}
void xpl_value_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t address, struct xpl_value *out) {
    value(l, r, address, out, 0);
}
