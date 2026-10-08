#include <ruby.h>
#include <sys/prctl.h>
#include <unistd.h>
__attribute__((noinline)) void xodb_ruby_probe(VALUE thread, VALUE value) {
    __asm__ volatile(".global xodb_ruby_stop\n.type xodb_ruby_stop,@function\nxodb_ruby_stop:\nnop" : : "m"(thread), "m"(value) : "memory");
}
static VALUE probe(VALUE self, VALUE value) {
    (void)self;
    xodb_ruby_probe(rb_thread_current(), value);
    return value;
}
void Init_xodb_probe(void) {
    (void)prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
    VALUE mod = rb_define_module("XodbRuby");
    rb_define_singleton_method(mod, "probe", probe, 1);
}
