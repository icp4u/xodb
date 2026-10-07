#ifndef WRONG_LAYOUT
#define WRONG_LAYOUT 0
#endif
namespace other {
struct JSArray { enum { kLengthOffset = 999 }; };
template <class T> struct Local { T *location_; };
}
namespace v8 {
struct Empty {};
struct Indirect { unsigned long *location_; };
template <class T> struct Local : Indirect, Empty {};
namespace internal { template <class T> struct Tagged { unsigned long ptr_; }; }
}
namespace v8 { namespace internal {
struct JSArray { enum { kLengthOffset = 24 + WRONG_LAYOUT }; };
struct ScopeInfo { enum Fields { kFlags, kParameterCount, kContextLocalCount, kPositionInfoStart, kPositionInfoEnd, kVariablePartIndex }; };
struct Code { enum Offsets { kBuiltinIdOffset = 90, kPositionTableOffset = 16 }; };
struct JSFunction { enum { kDispatchHandleOffset = 24 }; };
struct Internals { static const int kIsolateJSDispatchTableOffset = 616; };
struct JSDispatchEntry { static const unsigned kObjectPointerShift = 16; };
enum class Builtin { kInterpreterEntryTrampoline = 83 };
const unsigned kRootRegisterBias = 128, kJSDispatchHandleShift = 8, kJSDispatchTableEntrySize = 16;
}}
/* Materialized owned types ensure the compiler emits DWARF, including named
 * nested enums and the unrelated same-name type which must be ignored. */
other::JSArray unrelated; other::Local<unsigned long> unrelated_handle;
v8::Local<unsigned long> indirect_handle;
v8::internal::Tagged<unsigned long> direct_handle;
v8::internal::JSArray array_layout;
v8::internal::ScopeInfo scope_layout;
v8::internal::Code code_layout;
v8::internal::JSFunction function_layout;
v8::internal::Internals internals_layout;
v8::internal::JSDispatchEntry dispatch_layout;
v8::internal::Builtin builtin_layout;
int main() { return array_layout.kLengthOffset == 24 ? 0 : 1; }
