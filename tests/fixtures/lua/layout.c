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
typedef struct TString { HEAD; unsigned char shrlen; union {size_t lnglen;} u; char contents[1]; } TString;
typedef struct Table { HEAD; unsigned char flags, lsizenode; unsigned alimit; TValue *array; void *node, *lastfree; } Table;
typedef union Node { TValue i_val; struct {Value value_; unsigned char tt_, key_tt; int next; Value key_val;} u; } Node;
typedef struct LClosure { HEAD; unsigned char nupvalues; void *p; void *upvals[1]; } LClosure;
typedef struct CClosure { HEAD; unsigned char nupvalues; void *f; TValue upvalue[1]; } CClosure;
typedef struct Proto { HEAD; void *source; int linedefined, lastlinedefined; unsigned *code; int sizecode; signed char *lineinfo; int sizelineinfo; void *abslineinfo; int sizeabslineinfo; void *upvalues; int sizeupvalues; } Proto;
typedef struct UpVal { HEAD; union {TValue *p;} v; } UpVal;
typedef struct Upvaldesc { void *name; } Upvaldesc;
typedef struct Udata { HEAD; size_t len; } Udata;
typedef union StkIdRel { StackValue *p; ptrdiff_t offset; } StkIdRel;
typedef struct CallInfo { StkIdRel func, top; struct CallInfo *previous, *next; union {struct {const unsigned *savedpc;} l;} u; unsigned short callstatus; } CallInfo;
typedef struct lua_State { HEAD; unsigned char status; StkIdRel top, stack, stack_last; void *l_G; CallInfo *ci; CallInfo base_ci; } lua_State;
typedef struct AbsLineInfo { int pc, line; } AbsLineInfo;
int main(void) { return 0; }
