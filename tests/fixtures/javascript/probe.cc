#include <node.h>
#include <dlfcn.h>
#include <cstdio>
#include <string>
#include <sys/prctl.h>
#include <unistd.h>

/* Capture V8's ground truth at the actual native call site. The debugger
 * still stops only after the handle argument has its DWARF location. */
extern "C" __attribute__((noinline)) void xodb_node_probe(v8::Local<v8::Value> value) {
    asm volatile(".global xodb_node_stop\n.type xodb_node_stop,@function\nxodb_node_stop:\nnop" : : "m"(value) : "memory");
}
static std::string quoted(const char *s) {
    std::string out = "\"";
    for (; s && *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { out += '\\'; out += (char)c; }
        else if (c < 32) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); out += b; }
        else out += (char)c;
    }
    return out + "\"";
}
static bool armed = true;
static void load_library(const v8::FunctionCallbackInfo<v8::Value>& args) {
    v8::String::Utf8Value path(args.GetIsolate(), args[0]);
    args.GetReturnValue().Set(dlopen(*path, RTLD_NOW | RTLD_LOCAL) != nullptr);
}
static void arm(const v8::FunctionCallbackInfo<v8::Value>& args) {
    armed = args[0]->BooleanValue(args.GetIsolate());
}
static void probe(const v8::FunctionCallbackInfo<v8::Value>& args) {
    if (!armed) return;
    v8::Isolate *iso = args.GetIsolate();
    v8::HandleScope scope(iso);
    v8::String::Utf8Value label(iso, args.Length() > 1 ? args[1] : v8::Local<v8::Value>(v8::String::Empty(iso)));
    auto stack = v8::StackTrace::CurrentStackTrace(iso, 160, v8::StackTrace::kDetailed);
    std::string out = "{\"label\":" + quoted(*label) + ",\"frames\":[";
    for (int i = 0; i < stack->GetFrameCount(); ++i) {
        auto f = stack->GetFrame(iso, i);
        v8::String::Utf8Value name(iso, f->GetFunctionName()), file(iso, f->GetScriptName());
        char pos[96];
        snprintf(pos, sizeof pos, ",\"line\":%d,\"column\":%d}", f->GetLineNumber(), f->GetColumn());
        if (i) out += ',';
        out += "{\"name\":" + quoted(*name) + ",\"file\":" + quoted(*file) + pos;
    }
    out += "]}\n";
    size_t sent = 0;
    while (sent < out.size()) {
        ssize_t n = write(STDOUT_FILENO, out.data() + sent, out.size() - sent);
        if (n <= 0) return;
        sent += (size_t)n;
    }
    xodb_node_probe(args[0]);
}
static void initialize(v8::Local<v8::Object> exports) {
    (void)prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
    NODE_SET_METHOD(exports, "probe", probe);
    NODE_SET_METHOD(exports, "arm", arm);
    NODE_SET_METHOD(exports, "loadLibrary", load_library);
}
NODE_MODULE(NODE_GYP_MODULE_NAME, initialize)
