/* Synthetic DWARF evidence for the Lua profile parser. Real-runtime field
 * semantics are checked separately against compiled upstream headers. */
#include <stdint.h>
#include <stddef.h>
#ifndef WRONG_NUMBER
#define WRONG_NUMBER 0
#endif
#define HEAD void *next; unsigned char tt, marked
#if WRONG_NUMBER
typedef float TestNumber;
#else
typedef double TestNumber;
#endif
typedef union Value { TestNumber n; int64_t i; void *gc; } Value;
typedef struct TValue { Value value_; unsigned char tt_; } TValue;
typedef union StackValue { TValue val; } StackValue;
typedef struct GCObject { HEAD; } GCObject;
typedef struct TString { HEAD; unsigned char shrlen;
#ifdef WRONG_HASH
    unsigned short hash;
#else
    unsigned hash;
#endif
    union {size_t lnglen;} u; char contents[1]; } TString;
typedef struct Table { HEAD;
#ifdef TABLE_PADDING
    unsigned char unrelated_padding[8];
#endif
    unsigned char flags, lsizenode; unsigned alimit; TValue *array; void *node, *lastfree; struct Table *metatable; } Table;
typedef union Node { TValue i_val; struct {Value value_; unsigned char tt_, key_tt; int next; Value key_val;} u; } Node;
typedef struct LClosure { HEAD; unsigned char nupvalues; void *p; void *upvals[1]; } LClosure;
typedef struct CClosure { HEAD; unsigned char nupvalues; void *f; TValue upvalue[1]; } CClosure;
typedef struct Proto { HEAD; unsigned char is_vararg, numparams; void *source; int linedefined, lastlinedefined; unsigned *code; int sizecode; signed char *lineinfo; int sizelineinfo; void *abslineinfo; int sizeabslineinfo; void *upvalues; int sizeupvalues; void *locvars; int sizelocvars; } Proto;
typedef struct UpVal { HEAD; union {TValue *p;} v; } UpVal;
typedef struct LocVar { void *varname; int startpc, endpc; } LocVar;
typedef struct Upvaldesc { void *name; } Upvaldesc;
typedef struct Udata { HEAD; size_t len; } Udata;
typedef union StkIdRel { StackValue *p; ptrdiff_t offset; } StkIdRel;
typedef struct CallInfo { StkIdRel func, top; struct CallInfo *previous, *next; union {struct {const unsigned *savedpc; int nextraargs;} l;} u; unsigned short callstatus; } CallInfo;
typedef struct global_State { unsigned seed;
#ifdef WRONG_TMNAME
    unsigned long tmname[25];
#else
    TString *tmname[25];
#endif
 } global_State;
typedef struct lua_State { HEAD; unsigned char status; StkIdRel top, stack, stack_last; global_State *l_G; CallInfo *ci; CallInfo base_ci; } lua_State;
typedef struct AbsLineInfo { int pc, line; } AbsLineInfo;
#ifndef RUNTIME_ANCHORS
#define RUNTIME_ANCHORS 3
#endif
#if RUNTIME_ANCHORS & 1
static void luaV_execute(void) { }
#endif
#if RUNTIME_ANCHORS & 2
static const char lua_ident[] = "$LuaVersion: Lua 5.4.9 $";
#endif
int main(void) { return 0; }
