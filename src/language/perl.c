#include "perl.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
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
    OBJECT = 0x00100000,
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
static int gv_name(const struct xpl_layout *l, struct xpl_reader *r, uint64_t body, char *out, size_t cap) {
    uint64_t name = at(l, r, body, XPL_GVNAME), stash = at(l, r, body, XPL_GVSTASH);
    char short_name[192] = {0}, package[256] = {0};
    if (!name || !hek(l, r, name, short_name, sizeof short_name) ||
        !stash || !stash_name(l, r, stash, package, sizeof package))
        return 0;
    return snprintf(out, cap, "%s::%s", package, short_name) < (int)cap;
}
struct file_cache { uint64_t address; const struct xpl_frame *frame; };
static void location(const struct xpl_layout *l, struct xpl_reader *r, uint64_t cop, struct xpl_frame *f,
                     struct file_cache *cache, unsigned *cache_count) {
    f->cop = cop;
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
            unsigned context = (unsigned)at(l, r, address, XPL_CXTYPE);
            unsigned kind = context & 15;
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
            /* cop.h CxTRY: CXt_EVAL with CXp_TRY (0x80). Keep the flag
             * in the observation so try is not presented as an eval. */
            f->context_type = kind == 11 && (context & 0x80) ? 0x8b : kind;
            f->context_address = address;
            f->stackinfo = si;
            f->context_index = (uint64_t)(uint32_t)ix;
            f->cv = at(l, r, address, kind == 11 ? XPL_EVALCV : XPL_SUBCV);
            location(l, r, cop, f, cache, &cache_count);
            if (kind == 11) {
                snprintf(f->name, sizeof f->name, "%s", (context & 0x80) ? "(try)" : "(eval)");
                /* CxOLD_OP_TYPE is blk_u16 >> 7; OP_ENTEREVAL is 352 in
                 * the verified 5.44.0 profile. Block eval, try, G_EVAL and
                 * ithread entry legitimately have no eval CV. */
                if (!f->cv && !f->reason && (at(l, r, address, XPL_EVALOP) >> 7) == 352)
                    f->reason = "EvalCvUnavailable";
            } else if (!f->cv || !cv_name(l, r, f->cv, f->name, sizeof f->name)) {
                snprintf(f->name, sizeof f->name, "(unavailable sub)");
                f->reason = r->error ? r->error : "CvNameUnavailable";
            }
            f->identity_proved = f->cv != 0 && !r->error;
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
    main->identity_proved = main->cv != 0 && !r->error;
    snprintf(main->name, sizeof main->name, "main");
    location(l, r, cop, main, cache, &cache_count);
    if (!main->cv && !main->reason)
        main->reason = "MainCvUnavailable";
    if (main->reason || r->error)
        out->reason = r->error ? r->error : "PartialFrames";
    out->chain_complete = !r->error;
}
static void value(const struct xpl_layout *, struct xpl_reader *, uint64_t, struct xpl_value *, unsigned);
static void item(const struct xpl_layout *l, struct xpl_reader *r, uint64_t address, struct xpl_value_item *out,
                 unsigned depth, char (*class_name)[256]) {
    out->address = address;
    if (!address) {
        strcpy(out->type, "hole");
        strcpy(out->display, "absent slot");
        return;
    }
    struct xpl_value child;
    value(l, r, address, &child, depth);
    if (class_name) memcpy(*class_name, child.class_name, sizeof child.class_name);
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
            item(l, r, u, &out->items[out->item_count++], 1, &out->class_name);
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
                item(l, r, sv, entry, 1, NULL);
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
                    item(l, r, sv, entry, 1, NULL);
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
        if (!gv_name(l, r, out->body, out->display, sizeof out->display)) {
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
    /* SvSTASH is valid only for a blessed SVt_PVMG-or-later body. Never
     * invoke overload/magic or guess a package from a pointer's type name. */
    if (out->flags & OBJECT) {
        if (type < 7 || !out->body) goto inconsistent;
        uint64_t stash = at(l, r, out->body, XPL_BLESS_STASH);
        if (!stash || !stash_name(l, r, stash, out->class_name, sizeof out->class_name)) {
            out->class_name[0] = 0;
            if (!out->reason) out->reason = "ClassNameUnavailable";
        }
    }
    if (out->class_name[0]) {
        char display[sizeof out->display];
        memcpy(display, out->display, sizeof display);
        int n = snprintf(out->display, sizeof out->display, "%s %s", out->class_name, display);
        out->truncated |= n >= (int)sizeof out->display;
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


struct pad_binding {
    uint64_t ordinal;
    unsigned flags, package;
    char name[256];
};
static uint64_t pointer_slot(struct xpl_reader *r, uint64_t base, uint64_t index) {
    if (!base || index > UINT64_MAX / 8 || base > UINT64_MAX - index * 8) {
        r->error = "PadAddressOverflow";
        return 0;
    }
    return base + index * 8;
}
static int lexical_name(const char *name) {
    if (!name || !strchr("$@%&", name[0]) || !name[0]) return 0;
    unsigned char ch = (unsigned char)name[1];
    if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z'))) return 0;
    for (size_t i = 2; i < 256; ++i) {
        ch = (unsigned char)name[i];
        if (!ch) return 1;
        if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9'))) return 0;
    }
    return 0;
}
enum { PATH_DEPTH = 8, PATH_BUCKETS = 4096, PATH_ENTRIES = 512 };
struct path_step { int hash, dereference; uint64_t index; char key[129]; size_t length; };
struct perl_path { char root[129]; size_t count; struct path_step steps[PATH_DEPTH]; };
static int identifier(unsigned char ch, int first) {
    return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
           (!first && ch >= '0' && ch <= '9');
}
static const char *parse_path(const char *text, struct perl_path *out) {
    memset(out, 0, sizeof *out);
    if (!text) return "UnsupportedPerlExpression";
    size_t n = 0;
    while (n <= 128 && text[n]) ++n;
    if (n < 2 || n > 128 || !strchr("$@%&", text[0]) || !identifier((unsigned char)text[1], 1))
        return "UnsupportedPerlExpression";
    size_t at = 2;
    while (at < n && identifier((unsigned char)text[at], 0)) ++at;
    memcpy(out->root, text, at);
    while (at < n) {
        if (text[0] != '$' || out->count == PATH_DEPTH) return "UnsupportedPerlExpression";
        struct path_step *step = &out->steps[out->count];
        if (at + 1 < n && text[at] == '-' && text[at + 1] == '>') {
            at += 2; step->dereference = 1;
        } else step->dereference = out->count != 0;
        if (at == n || (text[at] != '{' && text[at] != '[')) return "UnsupportedPerlExpression";
        step->hash = text[at++] == '{';
        if (out->count == 0 && !step->dereference) out->root[0] = step->hash ? '%' : '@';
        if (step->hash) {
            if (at == n) return "UnsupportedPerlExpression";
            char quote = text[at] == '\'' || text[at] == '"' ? text[at++] : 0;
            size_t begin = at;
            if (quote) {
                while (at < n && text[at] != quote) {
                    unsigned char ch = (unsigned char)text[at++];
                    if (ch < 32 || ch >= 127 || ch == '\\' || ch == '$' || ch == '@')
                        return "UnsupportedPerlExpression";
                }
                if (at == n) return "UnsupportedPerlExpression";
            } else {
                if (!identifier((unsigned char)text[at], 1)) return "UnsupportedPerlExpression";
                while (at < n && identifier((unsigned char)text[at], 0)) ++at;
            }
            step->length = at - begin;
            memcpy(step->key, text + begin, step->length);
            if (quote) ++at;
            if (at == n || text[at++] != '}') return "UnsupportedPerlExpression";
        } else {
            size_t begin = at;
            while (at < n && text[at] >= '0' && text[at] <= '9') {
                unsigned digit = (unsigned)(text[at++] - '0');
                if (step->index > (INT32_MAX - digit) / 10u) return "UnsupportedPerlExpression";
                step->index = step->index * 10 + digit;
            }
            /* Leading zero integers have different Perl octal semantics. */
            if (at == begin || (at - begin > 1 && text[begin] == '0') || at == n || text[at++] != ']')
                return "UnsupportedPerlExpression";
        }
        ++out->count;
    }
    return NULL;
}
const char *xpl_expression_check(const char *expression) {
    struct perl_path path;
    return parse_path(expression, &path);
}
static const char *path_head(const struct xpl_layout *l, struct xpl_reader *r, uint64_t sv,
                             uint64_t *body, uint32_t *flags) {
    uint32_t refs;
    if (!head(l, r, sv, body, flags, &refs)) return r->error ? r->error : "PerlPathInvalidSv";
    /* Refuse all blessed objects, including overload, and all three magic
     * flags. Looking at an RV must not bypass magic on its referent. */
    if (*flags & (0x00e00000u | OBJECT)) return "PerlPathMagicOrObjectUnsupported";
    return NULL;
}
static const char *path_hash(const struct xpl_layout *l, struct xpl_reader *r, uint64_t sv,
                             uint64_t body, uint32_t flags, const struct path_step *step,
                             struct xpl_path_value *out) {
    /* Restricted hashes can throw on absent keys or contain placeholders. */
    if (flags & 0x08000000u) return "PerlPathRestrictedHashUnsupported";
    uint64_t count = at(l, r, body, XPL_HVKEYS), max = at(l, r, body, XPL_HVMAX);
    uint64_t array = at(l, r, sv, XPL_UNION);
    if (r->error) return r->error;
    if (max == UINT64_MAX || ((max + 1) & max) || (count && !array)) return "PerlPathHashInvalid";
    if (max >= PATH_BUCKETS || count > PATH_ENTRIES) return "PerlPathHashLimit";
    if (!array) return "PerlPathKeyNotFound";
    uint8_t buckets[PATH_BUCKETS * 8];
    if (!read_bytes(r, array, buckets, (size_t)(max + 1) * 8)) return r->error;
    uint64_t seen[PATH_ENTRIES]; size_t used = 0;
    struct xpl_path_value found = {0};
    /* Scan the whole bounded table: no seed-dependent hash is computed. Each
     * stored HEK hash must corroborate the physical bucket. A partial scan,
     * invalid chain or inconsistent count never becomes a false absence. */
    for (uint64_t bucket = 0; bucket <= max; ++bucket) {
        uint64_t he = 0;
        for (unsigned b = 0; b < 8; ++b) he |= (uint64_t)buckets[bucket * 8 + b] << (b * 8);
        while (he) {
            for (size_t i = 0; i < used; ++i) if (seen[i] == he) return "HashEntryCycle";
            if (used == PATH_ENTRIES || used >= count) return "PerlPathHashInvalid";
            seen[used++] = he;
            uint64_t key = at(l, r, he, XPL_HEKEY), value_ = at(l, r, he, XPL_HEVAL);
            uint64_t hash = at(l, r, key, XPL_HEKHASH);
            int32_t len = (int32_t)at(l, r, key, XPL_HEKLEN);
            if (r->error) return r->error;
            if ((hash & max) != bucket) return "PerlPathHashUnproved";
            if (len < 0) return "PerlPathSvKeyUnsupported";
            if (len > 1048576 || key > UINT64_MAX - l->fields[XPL_HEKKEY].offset)
                return "PerlPathHashInvalid";
            uint64_t bytes = key + l->fields[XPL_HEKKEY].offset;
            if (bytes > UINT64_MAX - (uint64_t)len - 1) return "PerlPathHashInvalid";
            unsigned key_flags = (unsigned)number(r, bytes + (uint64_t)len + 1, 1);
            if (r->error) return r->error;
            if (key_flags & ~7u) return "PerlPathKeyFlagsUnsupported";
            if ((size_t)len == step->length) {
                char key_text[129];
                if (!read_bytes(r, bytes, key_text, (size_t)len + 1)) return r->error;
                if (key_text[len]) return "PerlPathHashInvalid";
                /* ASCII has the same bytes in both byte and UTF-8 keys. */
                if (!memcmp(key_text, step->key, (size_t)len)) {
                    if (found.sv || !value_) return "PerlPathHashInvalid";
                    found.sv = value_;
                    if (he > UINT64_MAX - l->fields[XPL_HEVAL].offset) return "PerlPathHashInvalid";
                    found.slot = he + l->fields[XPL_HEVAL].offset;
                }
            }
            he = at(l, r, he, XPL_HENEXT);
            if (r->error) return r->error;
        }
    }
    if (used != count) return "PerlPathHashInvalid";
    if (!found.sv) return "PerlPathKeyNotFound";
    *out = found;
    return NULL;
}
static void path_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t root,
                       const struct perl_path *path, struct xpl_path_value *out) {
    memset(out, 0, sizeof *out); out->sv = root;
    for (size_t i = 0; i < path->count; ++i) {
        const struct path_step *step = &path->steps[i];
        uint64_t body; uint32_t flags;
        out->reason = path_head(l, r, out->sv, &body, &flags);
        if (out->reason) break;
        if (step->dereference) {
            if (!(flags & ROK) || (flags & 255) == 0 || (flags & 255) >= SV_AV || (flags & (IOK | NOK | POK))) {
                out->reason = "PerlPathReferenceRequired"; break;
            }
            out->sv = at(l, r, out->sv, XPL_UNION);
            out->reason = path_head(l, r, out->sv, &body, &flags);
            if (out->reason) break;
        }
        if (!body || (flags & ROK) || (flags & 255) != (step->hash ? SV_HV : SV_AV)) {
            out->reason = "PerlPathContainerRequired"; break;
        }
        if (step->hash) out->reason = path_hash(l, r, out->sv, body, flags, step, out);
        else {
            int64_t fill = (int64_t)at(l, r, body, XPL_AVFILL), max = (int64_t)at(l, r, body, XPL_AVMAX);
            uint64_t array = at(l, r, out->sv, XPL_UNION);
            if (r->error) out->reason = r->error;
            else if (fill < -1 || max < -1 || fill > max || (fill >= 0 && !array)) out->reason = "PerlPathArrayInvalid";
            else if (fill < 0 || step->index > (uint64_t)fill) out->reason = "PerlPathIndexOutOfRange";
            else {
                out->slot = pointer_slot(r, array, step->index);
                out->sv = number(r, out->slot, 8);
                out->reason = r->error ? r->error : out->sv ? NULL : "PerlPathArrayHole";
            }
        }
        if (out->reason) break;
    }
    if (!out->reason && path->count) {
        uint64_t body; uint32_t flags;
        out->reason = path_head(l, r, out->sv, &body, &flags);
    }
    if (out->reason) out->sv = out->slot = 0;
}
void xpl_path_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t root,
                   const char *expression, struct xpl_path_value *out) {
    struct perl_path path;
    memset(out, 0, sizeof *out);
    out->reason = parse_path(expression, &path);
    if (!out->reason) path_read(l, r, root, &path, out);
}
static int pad_frame(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter,
                     size_t index, struct xpl_locals *out, uint64_t *names, uint64_t *slots,
                     int64_t *last) {
    if (index >= XPL_MAX_FRAMES) { out->reason = "FrameUnavailable"; return 0; }
    struct xpl_stack *stack = malloc(sizeof *stack);
    if (!stack) { out->reason = "OutOfMemory"; return 0; }
    xpl_stack_read(l, r, interpreter, stack);
    struct xpl_frame f = {0};
    if (r->error || (stack->reason && strcmp(stack->reason, "PartialFrames")))
        out->reason = r->error ? r->error : stack->reason;
    else if (index >= stack->count) out->reason = "FrameUnavailable";
    else f = stack->frames[index];
    free(stack);
    if (out->reason) return 0;
    out->context_address = f.context_address; out->cv = f.cv;
    if (f.context_type == 10) { out->reason = "FormatPadUnproved"; return 0; }
    if (f.context_type != 0 && f.context_type != 9) {
        out->reason = "EvalPadUnproved"; return 0;
    }
    if (!f.cv || !f.cop) { out->reason = "FramePadUnavailable"; return 0; }
    uint64_t body; uint32_t flags, refs;
    if (!head(l, r, f.cv, &body, &flags, &refs) || (flags & 255) != SV_CV || !body) {
        out->reason = "PadCvInvalid"; return 0;
    }
    if (at(l, r, body, XPL_CVFLAGS) & 8) { out->reason = "XsFrameNoPad"; return 0; }
    uint64_t depth = f.context_type ? at(l, r, f.context_address, XPL_SUBDEPTH) + 1 : 1;
    uint64_t active_depth = at(l, r, body, XPL_CVDEPTH);
    /* The main CV is run at depth zero but stores its executing pad at one. */
    if (!depth || depth > 1024 || (f.context_type && depth > active_depth)) {
        out->reason = "PadDepthInvalid"; return 0;
    }
    out->depth = (uint32_t)depth;
    out->sequence = at(l, r, f.cop, XPL_COPSEQ);
    if (!out->sequence || out->sequence == UINT32_MAX) {
        out->reason = "PadSequenceUnavailable"; return 0;
    }
    uint64_t padlist = at(l, r, body, XPL_CVPADLIST);
    if (!padlist) { out->reason = "PadlistUnavailable"; return 0; }
    uint64_t max = at(l, r, padlist, XPL_PADMAX), array = at(l, r, padlist, XPL_PADARRAY);
    if (max < depth || max > 1048576 || !array) { out->reason = "PadlistInvalid"; return 0; }
    uint64_t namelist = number(r, pointer_slot(r, array, 0), 8);
    uint64_t pad = number(r, pointer_slot(r, array, depth), 8);
    if (!namelist || !pad) { out->reason = "PadUnavailable"; return 0; }
    out->pad = pad;
    *last = (int64_t)at(l, r, namelist, XPL_NAMESFILL);
    int64_t name_max = (int64_t)at(l, r, namelist, XPL_NAMESMAX);
    *names = at(l, r, namelist, XPL_NAMESARRAY);
    if (*last < -1 || *last > name_max || name_max < -1 || name_max > 1048576 ||
        (*last >= 0 && !*names)) { out->reason = "PadNamesInvalid"; return 0; }
    if (*last >= XPL_MAX_PAD_SLOTS) { out->reason = "PadSlotLimit"; return 0; }
    if (!head(l, r, pad, &body, &flags, &refs) || (flags & 255) != SV_AV || !body) {
        out->reason = "PadValuesInvalid"; return 0;
    }
    int64_t fill = (int64_t)at(l, r, body, XPL_AVFILL), capacity = (int64_t)at(l, r, body, XPL_AVMAX);
    *slots = at(l, r, pad, XPL_UNION);
    if (fill < *last || fill < -1 || fill > capacity || capacity < -1 || capacity > 1048576 ||
        (fill >= 0 && !*slots)) { out->reason = "PadValuesInvalid"; return 0; }
    return !r->error;
}
static void pad_locals(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter,
                       size_t frame, size_t start, size_t limit, const char *find, const uint64_t *ordinal,
                       int preview, struct xpl_locals *out) {
    memset(out, 0, sizeof *out);
    out->interpreter = interpreter; out->frame = frame; out->start = start;
    if (find && !ordinal && !lexical_name(find)) { out->reason = "UnsupportedPerlExpression"; return; }
    if (ordinal && *ordinal >= XPL_MAX_PAD_SLOTS) { out->reason = "PerlWatchBindingUnavailable"; return; }
    uint64_t names = 0, slots = 0; int64_t last = -1;
    if (!pad_frame(l, r, interpreter, frame, out, &names, &slots, &last)) {
        if (r->error) out->reason = r->error;
        return;
    }
    struct pad_binding *bindings = calloc(XPL_MAX_PAD_NAMES, sizeof *bindings);
    if (!bindings) { out->reason = "OutOfMemory"; return; }
    size_t count = 0;
    /* Highest active slot wins. Retain package declarations in the seen set:
     * an inner `our $x` must mask an outer `my $x`, not expose the outer value. */
    for (int64_t i = last; i >= 0 && !r->error; --i) {
        if (ordinal && (uint64_t)i != *ordinal) continue;
        uint64_t pn = number(r, pointer_slot(r, names, (uint64_t)i), 8);
        if (!pn) continue;
        uint64_t pv = at(l, r, pn, XPL_NAMEPV);
        if (!pv) continue; /* unnamed temporary */
        unsigned flags = (unsigned)at(l, r, pn, XPL_NAMEFLAGS);
        if (!(flags & 1)) {
            uint32_t low = (uint32_t)at(l, r, pn, XPL_NAMELOW), high = (uint32_t)at(l, r, pn, XPL_NAMEHIGH);
            if (low == UINT32_MAX) continue; /* declaration not introduced yet */
            if (low > high) { out->reason = "PadSequenceWrapUnsupported"; break; }
            if (out->sequence <= low || out->sequence > high) continue;
        }
        uint64_t len = at(l, r, pn, XPL_NAMELEN);
        if (len > 255) { out->reason = "PadNameInvalid"; break; }
        if (!len) continue;
        char name[256] = {0};
        if (!read_bytes(r, pv, name, (size_t)len)) break;
        if (memchr(name, 0, (size_t)len) || !strchr("$@%&", name[0])) {
            out->reason = "PadNameInvalid"; break;
        }
        if (len == 1) continue; /* anonymous sub or state initialization flag */
        size_t j = 0;
        for (; j < count; ++j) if (!strcmp(bindings[j].name, name)) break;
        if (j < count) continue;
        if (count == XPL_MAX_PAD_NAMES) { out->reason = "PadNameLimit"; break; }
        struct pad_binding *b = &bindings[count++];
        b->ordinal = (uint64_t)i; b->flags = flags;
        b->package = at(l, r, pn, XPL_NAMEOUR) != 0;
        memcpy(b->name, name, sizeof b->name);
    }
    if (r->error) out->reason = r->error;
    /* A partial name scan cannot establish shadowing or name absence. */
    if (out->reason) { free(bindings); return; }
    for (size_t i = 0; i < count; ++i) if (!bindings[i].package) ++out->total;
    if (limit > XPL_MAX_LOCALS) limit = XPL_MAX_LOCALS;
    size_t position = 0;
    for (size_t i = 0; i < count && out->count < limit; ++i) {
        const struct pad_binding *b = &bindings[i];
        if (b->package) {
            if (find && !strcmp(find, b->name)) out->reason = "PerlPackageVariableUnread";
            continue;
        }
        if (find ? strcmp(find, b->name) != 0 : position++ < start) continue;
        struct xpl_local *entry = &out->items[out->count++];
        entry->ordinal = b->ordinal;
        memcpy(entry->name, b->name, sizeof entry->name);
        entry->scope = b->flags & 1 ? XPL_OUTER : b->flags & 2 ? XPL_STATE : XPL_LOCAL;
        if (b->flags & 0x20) { entry->reason = "FieldStorageUnproved"; continue; }
        entry->slot_address = pointer_slot(r, slots, b->ordinal);
        entry->sv = number(r, entry->slot_address, 8);
        if (!entry->sv || r->error) {
            entry->reason = r->error ? r->error : "PadValueUnavailable";
            continue;
        }
        if (preview) {
            xpl_value_read(l, r, entry->sv, &entry->value);
            entry->reason = entry->value.reason;
        }
    }
    if (r->error) out->reason = r->error;
    else if (find && !out->count && !out->reason) {
        /* The active pad is proved; CvOUTSIDE/file-scope lexicals and globals
         * were not searched, so this is not proof that the name is absent. */
        out->reason = ordinal ? "PerlWatchBindingUnavailable" : "PerlOuterScopeUnread";
    }
    out->truncated = !find && start < out->total && out->count < out->total - start;
    free(bindings);
}
void xpl_locals_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter,
                     size_t frame, size_t start, size_t limit, struct xpl_locals *out) {
    pad_locals(l, r, interpreter, frame, start, limit, NULL, NULL, 1, out);
}
void xpl_local_find(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter,
                    size_t frame, const char *name, struct xpl_locals *out) {
    struct perl_path path;
    const char *why = parse_path(name, &path);
    if (why) { memset(out, 0, sizeof *out); out->reason = why; return; }
    pad_locals(l, r, interpreter, frame, 0, 1, path.root, NULL, !path.count, out);
    if (!path.count || out->reason || out->count != 1) return;
    struct xpl_local *entry = &out->items[0];
    if (entry->reason) return;
    struct xpl_path_value resolved;
    path_read(l, r, entry->sv, &path, &resolved);
    entry->sv = resolved.sv; entry->slot_address = resolved.slot;
    entry->reason = resolved.reason; memset(&entry->value, 0, sizeof entry->value);
    snprintf(entry->name, sizeof entry->name, "%s", name);
    if (!entry->reason) {
        xpl_value_read(l, r, entry->sv, &entry->value);
        entry->reason = entry->value.reason;
    }
}

void xpl_local_binding(const struct xpl_layout *l, struct xpl_reader *r, uint64_t interpreter,
                       size_t frame, uint64_t ordinal, const char *name, struct xpl_locals *out) {
    pad_locals(l, r, interpreter, frame, 0, 1, name ? name : "", &ordinal, 1, out);
}

static int sample_number(struct xpl_sample *out, uint64_t n, size_t bytes) {
    if (bytes > sizeof out->bytes - out->size) {
        out->reason = "PerlWatchSampleLimit";
        return 0;
    }
    for (size_t i = 0; i < bytes; ++i) out->bytes[out->size++] = (uint8_t)(n >> (i * 8));
    return 1;
}
static void sample_display(struct xpl_sample *out, const char *part) {
    size_t used = strlen(out->display);
    snprintf(out->display + used, sizeof out->display - used, "%s%s", used ? "; " : "", part);
}
void xpl_sample_read(const struct xpl_layout *l, struct xpl_reader *r, uint64_t sv,
                     struct xpl_sample *out) {
    memset(out, 0, sizeof *out);
    uint64_t body; uint32_t flags, refs;
    if (!head(l, r, sv, &body, &flags, &refs)) {
        out->reason = r->error ? r->error : "PerlWatchSvUnavailable";
        return;
    }
    unsigned type = flags & 255;
    if (flags & (0x00e00000u | OBJECT)) {
        out->reason = "PerlWatchMagicOrObjectUnsupported"; return;
    }
    if ((flags & ROK) || !(type == 0 || type == SV_IV || type == SV_NV || type == SV_PV ||
                           type == SV_PVIV || type == SV_PVNV || type == 7)) {
        out->reason = "PerlWatchValueUnsupported"; return;
    }
    if (((flags & IOK) && type != SV_IV && type < SV_PVIV) ||
        ((flags & NOK) && type != SV_NV && type < SV_PVNV) ||
        ((flags & POK) && type != SV_PV && type < SV_PVIV)) {
        out->reason = "InconsistentSv"; return;
    }
    out->kind = ((flags & IOK) ? XPL_SAMPLE_IV : 0) | ((flags & NOK) ? XPL_SAMPLE_NV : 0) |
                ((flags & POK) ? XPL_SAMPLE_PV : 0) | ((flags & IOK) && (flags & UV_FLAG) ? XPL_SAMPLE_UNSIGNED : 0);
    char text[256];
    if (flags & IOK) {
        uint64_t iv = at(l, r, type == SV_IV ? sv : body, type == SV_IV ? XPL_UNION : XPL_IV);
        if (!sample_number(out, iv, 8)) return;
        if (flags & UV_FLAG) snprintf(text, sizeof text, "UV %" PRIu64, iv);
        else snprintf(text, sizeof text, "IV %" PRId64, (int64_t)iv);
        sample_display(out, text);
    }
    if (flags & NOK) {
        uint64_t bits = at(l, r, body, XPL_NV);
        if (!sample_number(out, bits, 8)) return;
        double nv; memcpy(&nv, &bits, sizeof nv);
        snprintf(text, sizeof text, "NV %.17g", nv); sample_display(out, text);
    }
    if (flags & POK) {
        uint64_t n = at(l, r, body, XPL_PVCUR), capacity = at(l, r, body, XPL_PVLEN);
        uint64_t pv = at(l, r, sv, XPL_UNION);
        if (!pv || (capacity && n >= capacity)) { out->reason = "InconsistentSv"; return; }
        uint8_t bytes[XPL_SAMPLE_BYTES];
        if (n > sizeof bytes) { out->reason = "PerlWatchSampleLimit"; return; }
        if (n && !read_bytes(r, pv, bytes, (size_t)n)) { out->reason = r->error; return; }
        for (size_t i = 0; i < n;) {
            uint32_t ch = bytes[i++];
            if ((flags & 0x20000000u) && ch >= 128) {
                unsigned left; uint32_t minimum;
                if (ch >= 0xc2 && ch <= 0xdf) { left = 1; ch &= 31; minimum = 0x80; }
                else if (ch >= 0xe0 && ch <= 0xef) { left = 2; ch &= 15; minimum = 0x800; }
                else if (ch >= 0xf0 && ch <= 0xf4) { left = 3; ch &= 7; minimum = 0x10000; }
                else { out->reason = "PerlWatchUtf8Unsupported"; return; }
                if (left > n - i) { out->reason = "PerlWatchUtf8Unsupported"; return; }
                for (unsigned j = 0; j < left; ++j) {
                    unsigned c = bytes[i++];
                    if ((c & 0xc0) != 0x80) { out->reason = "PerlWatchUtf8Unsupported"; return; }
                    ch = (ch << 6) | (c & 63);
                }
                if (ch < minimum || ch > 0x10ffff || (ch >= 0xd800 && ch <= 0xdfff)) {
                    out->reason = "PerlWatchUtf8Unsupported"; return;
                }
            }
            if (!sample_number(out, ch, 4)) return;
        }
        struct xpl_value preview;
        xpl_value_read(l, r, sv, &preview);
        if (preview.reason) { out->reason = preview.reason; return; }
        sample_display(out, preview.display);
    }
    if (r->error) { out->reason = r->error; return; }
    unsigned valid = out->kind & (XPL_SAMPLE_IV | XPL_SAMPLE_NV | XPL_SAMPLE_PV);
    strcpy(out->type, valid == 0 ? "undef" : valid == XPL_SAMPLE_IV ? (flags & UV_FLAG ? "UV" : "IV") :
           valid == XPL_SAMPLE_NV ? "NV" : valid == XPL_SAMPLE_PV ? "PV" : "dual");
    if (!valid) strcpy(out->display, "undef");
}
