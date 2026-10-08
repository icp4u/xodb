/* An unrelated C++ host with names commonly reused by embedded runtimes. */
#include <cstdint>
struct Node { virtual ~Node() = default; int id; Node *next; };
struct Table { unsigned rows, columns; double cells[16]; };
struct Proto { const char *name; unsigned arity; };
struct Value { unsigned tag; std::uint64_t word; };
struct CallInfo { void *return_address; unsigned depth; };
struct TValue { int tt_; double value_; };
struct StackValue { TValue val; int delta; };
struct GCObject { GCObject *next; unsigned char tt, marked; long refs; };
struct UpVal { TValue *v; unsigned char tt, marked; long refs; };
struct Upvaldesc { void *name; long extra; };
struct AbsLineInfo { int pc, line; long extra; };
template<unsigned N> struct Component : Component<N-1> { std::uint64_t words[N%7+1]; };
template<> struct Component<0> { unsigned id; };
Node host_node;
Table host_table;
Proto host_proto;
Value host_value;
CallInfo host_call;
StackValue host_stack;
GCObject host_gc;
UpVal host_upval;
Upvaldesc host_upvaldesc;
AbsLineInfo host_line;
Component<256> host_components;
extern "C" int lua_host_main(int, char **);
int main(int argc, char **argv) {
    host_node.id=1; host_table.rows=2; host_proto.arity=3;
    host_value.tag=4; host_call.depth=5; host_components.id=6;
    return lua_host_main(argc,argv);
}
