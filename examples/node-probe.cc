#include <node.h>
#include <signal.h>
#include <sys/prctl.h>

/* A named breakpoint site after the argument prologue. DWARF supplies the
 * actual V8 handle layout; the language reader never runs target code. */
extern "C" __attribute__((noinline)) void xodb_node_probe(v8::Local<v8::Value> value) {
    asm volatile(".global xodb_node_stop\n.type xodb_node_stop,@function\nxodb_node_stop:\nnop" : : "m"(value) : "memory");
}
static void probe(const v8::FunctionCallbackInfo<v8::Value>& args) {
    xodb_node_probe(args[0]);
}
static void initialize(v8::Local<v8::Object> exports) {
    (void)prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
    NODE_SET_METHOD(exports, "probe", probe);
}
NODE_MODULE(NODE_GYP_MODULE_NAME, initialize)
