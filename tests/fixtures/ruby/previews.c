/* The owned interpreter supplies counts, names and iteration order independently
 * through CRuby's public API. CHECK remains active under the SDK's NDEBUG. */
#define XODB_RUBY_PATH_ORACLE
#include "paths.c"
struct preview_order { struct xrb_value *value; size_t count; };
static int preview_entry(VALUE key,VALUE value,VALUE context) {
    (void)key;struct preview_order *order=(void *)(uintptr_t)context;
    if(order->count<order->value->item_count)
        CHECK(order->value->items[order->count].tagged==(uint64_t)value);
    ++order->count;return ST_CONTINUE;
}
static VALUE preview(VALUE self,VALUE value) {
    (void)self;struct xrb_reader r={.read=owned_read};struct xrb_value got;
    xrb_value_read(&layout,&r,&path_context,value,&got);
#ifdef XODB_RUBY_PREVIEW_NEGATIVE
    got.count ^= 1; /* This must abort even with -DNDEBUG. */
#endif
    CHECK(!got.reason && got.tagged==(uint64_t)value);
    CHECK(r.reads<=XRB_READ_LIMIT && r.bytes<=XRB_BYTE_LIMIT);
    uint64_t count=0;
    if(SYMBOL_P(value))count=(uint64_t)RSTRING_LEN(rb_sym2str(value));
    else if(RB_TYPE_P(value,T_STRING))count=(uint64_t)RSTRING_LEN(value);
    else if(RB_TYPE_P(value,T_ARRAY)) {
        count=(uint64_t)RARRAY_LEN(value);
        CHECK(got.item_count==(count<XRB_PREVIEW_ITEMS?count:XRB_PREVIEW_ITEMS));
        for(size_t i=0;i<got.item_count;++i)CHECK(got.items[i].tagged==(uint64_t)rb_ary_entry(value,(long)i));
    } else if(RB_TYPE_P(value,T_HASH)) {
        count=(uint64_t)RHASH_SIZE(value);struct preview_order order={.value=&got};
        rb_hash_foreach(value,preview_entry,(VALUE)(uintptr_t)&order);
        CHECK(order.count==count);
        CHECK(got.item_count==(count<XRB_PREVIEW_ITEMS?count:XRB_PREVIEW_ITEMS));
    }
    CHECK(got.count==count);
    VALUE out=rb_hash_new(),items=rb_ary_new();
    set(out,"type",rb_str_new_cstr(got.type));set(out,"display",rb_utf8_str_new_cstr(got.display));
    set(out,"count",ULL2NUM(got.count));set(out,"truncated",got.truncated?Qtrue:Qfalse);
    set(out,"static_symbol",RB_STATIC_SYM_P(value)?Qtrue:Qfalse);
    for(size_t i=0;i<got.item_count;++i) {
        struct xrb_item *item=&got.items[i];VALUE child=rb_hash_new();
        set(child,"key",rb_utf8_str_new_cstr(item->key));set(child,"type",rb_str_new_cstr(item->type));
        set(child,"display",rb_utf8_str_new_cstr(item->display));
        set(child,"diagnostic",item->reason?rb_str_new_cstr(item->reason):Qnil);rb_ary_push(items,child);
    }
    set(out,"children",items);++verified;return out;
}
static VALUE preview_refusal(VALUE self,VALUE value,VALUE reason) {
    (void)self;struct xrb_reader r={.read=owned_read};struct xrb_value got;
    xrb_value_read(&layout,&r,&path_context,value,&got);
    CHECK(got.reason && !strcmp(got.reason,StringValueCStr(reason)) && !got.item_count);
    return Qnil;
}
static VALUE preview_faults(VALUE self,VALUE value) {
    (void)self;struct path_fault fault={0};struct xrb_reader r={.context=&fault,.read=fault_read};
    struct xrb_value got;xrb_value_read(&layout,&r,&path_context,value,&got);
    CHECK(!got.reason && fault.calls);size_t reads=fault.calls;
    for(size_t i=1;i<=reads;++i) {
        fault=(struct path_fault){.fail=i};r=(struct xrb_reader){.context=&fault,.read=fault_read};
        xrb_value_read(&layout,&r,&path_context,value,&got);
        int diagnosed=got.reason!=NULL;
        for(size_t j=0;j<got.item_count;++j)if(got.items[j].reason)diagnosed=1;
        CHECK(fault.calls>=i && diagnosed);
        CHECK(r.reads<=XRB_READ_LIMIT && r.bytes<=XRB_BYTE_LIMIT);
    }
    r=(struct xrb_reader){.read=owned_read,.reads=XRB_READ_LIMIT};
    xrb_value_read(&layout,&r,&path_context,value,&got);
    CHECK(got.reason && !strcmp(got.reason,"RubyReadBudget"));
    return SIZET2NUM(reads);
}
void Init_xodb_previews(void) {
    CHECK(rb_utf8_encindex()==1 && rb_ascii8bit_encindex()==0);
    CHECK(RB_ENCODING_GET_INLINED(rb_utf8_str_new_cstr("é"))==1);
    Init_xodb_paths();VALUE mod=rb_define_module("XodbPreview");
    rb_define_singleton_method(mod,"read",preview,1);
    rb_define_singleton_method(mod,"faults",preview_faults,1);
    rb_define_singleton_method(mod,"refuse",preview_refusal,2);
}
