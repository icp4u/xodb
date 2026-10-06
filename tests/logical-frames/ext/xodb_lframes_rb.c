/* CRuby helper for the cooperating logical-frame exporter (draft C05-1).
 * XodbLFrames.thread_frames(thread, limit) wraps the public
 * rb_profile_thread_frames() API (ruby/debug.h). It runs in the observed
 * process while the caller holds the GVL; the target thread is therefore
 * not executing Ruby code during the read. A frame whose rb_profile_frame_path
 * is nil has no iseq: CRuby reports C-implemented methods (cfunc) that way.
 * XodbNative.through_c(n) { } yields from C: an owned native-extension
 * transition that CRuby itself reports as a C method frame. */
#include <ruby.h>
#include <ruby/debug.h>

static VALUE thread_frames(VALUE self, VALUE thread, VALUE vlimit)
{
    (void)self;
    int limit = NUM2INT(vlimit);
    if (limit < 1 || limit > 4096)
        rb_raise(rb_eArgError, "limit must be 1..4096");
    VALUE *frames = ALLOC_N(VALUE, (size_t)limit);
    int *lines = ALLOC_N(int, (size_t)limit);
    int n = rb_profile_thread_frames(thread, 0, limit, frames, lines);
    VALUE out = rb_ary_new_capa(n);
    for (int i = 0; i < n; ++i) {
        VALUE path = rb_profile_frame_path(frames[i]);
        VALUE row = rb_ary_new_capa(8);
        rb_ary_push(row, NIL_P(path) ? ID2SYM(rb_intern("cfunc")) : ID2SYM(rb_intern("iseq")));
        rb_ary_push(row, rb_profile_frame_full_label(frames[i]));
        rb_ary_push(row, rb_profile_frame_base_label(frames[i]));
        rb_ary_push(row, path);
        rb_ary_push(row, rb_profile_frame_absolute_path(frames[i]));
        rb_ary_push(row, rb_profile_frame_first_lineno(frames[i]));
        rb_ary_push(row, NIL_P(path) ? Qnil : INT2NUM(lines[i]));
        rb_ary_push(row, rb_profile_frame_classpath(frames[i]));
        rb_ary_push(out, row);
    }
    xfree(frames);
    xfree(lines);
    return out;
}

static VALUE through_c(VALUE self, VALUE count)
{
    (void)self;
    long n = NUM2LONG(count);
    VALUE last = Qnil;
    for (long i = 0; i < n; ++i)
        last = rb_yield(LONG2NUM(i));
    return last;
}

void Init_xodb_lframes_rb(void)
{
    VALUE m = rb_define_module("XodbLFrames");
    rb_define_module_function(m, "thread_frames", thread_frames, 2);
    VALUE native = rb_define_module("XodbNative");
    rb_define_module_function(native, "through_c", through_c, 1);
}
