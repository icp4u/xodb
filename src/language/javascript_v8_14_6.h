#ifndef XODB_JAVASCRIPT_V8_14_6_H
#define XODB_JAVASCRIPT_V8_14_6_H
/* Supplemental fields for exactly V8 14.6.202.34-node.28, x86-64,
 * TaggedSize=SystemPointerSize=8, pointer compression and sandbox disabled.
 * These are independently transcribed layout facts, not copied reader code.
 * Every source below is in the exact Node v26.8.2 tag:
 * https://github.com/nodejs/node/tree/v26.8.2/deps/v8
 * Related exported constants are checked before any supplemented read.
 */
#define XJS_V8_VERSION "14.6.202.34-node.28"
/* src/objects/js-array.tq:61-66: JSObject header followed by Number length. */
#define XJS_V8_ARRAY_LENGTH 24
/* src/common/globals.h:2108-2118, x86-64 signalling-NaN hole encoding. */
#define XJS_V8_DOUBLE_HOLE UINT64_C(0xfff7fffffff7ffff)
/* globals.h:2111-2122: optional undefined encoding; its build option is not
 * proved by the exported metadata, so encountering this pattern refuses. */
#define XJS_V8_DOUBLE_UNDEFINED UINT64_C(0xfff6fffffff6ffff)
/* src/objects/scope-info.tq:64-91, 134-189; scope-info.h:287-293.
 * HeapObject header, flags/padding, parameter count, context-local count,
 * start/end positions, then the variable part. */
#define XJS_V8_SCOPE_FLAGS 8
#define XJS_V8_SCOPE_START 32
#define XJS_V8_SCOPE_END 40
#define XJS_V8_SCOPE_TYPE_MASK 15
#define XJS_V8_SCOPE_MODULE 5
#define XJS_V8_SCOPE_SAVED_CLASS (1u << 10)
#define XJS_V8_SCOPE_FUNCTION_SHIFT 12
#define XJS_V8_SCOPE_FUNCTION_MASK 3
#define XJS_V8_SCOPE_INFERRED (1u << 14)
#define XJS_V8_SCOPE_EMPTY (1u << 29)
/* src/common/globals.h:2048: names use a hash table at this count. */
#define XJS_V8_SCOPE_INLINE_NAMES 75
/* scope-info.tq ScopeFlags/VariableProperties; contexts.tq and contexts.h.
 * Context length is a Smi; the first two elements are ScopeInfo/previous. */
#define XJS_V8_SCOPE_CONTEXT_EXTENSION (1u << 26)
#define XJS_V8_SCOPE_CONTEXT_CELLS (1u << 31)
#define XJS_V8_CONTEXT_LENGTH 8
#define XJS_V8_CONTEXT_DATA 16
#define XJS_V8_CONTEXT_SCOPE 16
#define XJS_V8_CONTEXT_PREVIOUS 24
/* contexts.tq ContextCell; contexts.h State; contexts-inl.h accessors. */
#define XJS_V8_CONTEXT_CELL_TAGGED 8
#define XJS_V8_CONTEXT_CELL_STATE 24
#define XJS_V8_CONTEXT_CELL_NUMBER 32
/* src/objects/bytecode-array.tq:7-23: trusted-object header, Smi length,
 * wrapper, then protected source-position-table pointer (no sandbox). */
#define XJS_V8_BYTECODE_POSITIONS 24
/* src/objects/fixed-array.tq:62-65: TrustedByteArray length and payload. */
#define XJS_V8_POSITION_LENGTH 8
#define XJS_V8_POSITION_DATA 16
/* src/objects/code.h:392-443: first two tagged Code fields, before wrapper. */
#define XJS_V8_CODE_DEOPT 8
#define XJS_V8_CODE_POSITIONS 16
/* src/objects/string.h:1191-1242; string-inl.h:1498-1505,1561-1568:
 * cached external data follows the resource pointer. Uncached strings have
 * no such field and must refuse: obtaining data would call a virtual method. */
#define XJS_V8_EXTERNAL_DATA 24
/* src/codegen/source-position-table.cc:92-139, source-position.h:143-154.
 * Code deltas use two flag bits; script position is a biased 30-bit field.
 * An inlining id is evidence that this is not the physical function's line. */
#define XJS_V8_POSITION_CODE_SHIFT 2
#define XJS_V8_POSITION_SCRIPT_MASK 0x3fffffff
#define XJS_V8_POSITION_INLINE_SHIFT 31
/* script.tq:19-35 and shared-function-info.tq:63-83. */
#define XJS_V8_SCRIPT_LINE 24
#define XJS_V8_SCRIPT_COLUMN 32
#define XJS_V8_SHARED_DATA 8
/* shared-function-info.tq: unique_id follows flags/function_literal_id; unlike
 * the heap address, it is retained across moving garbage collections. */
#define XJS_V8_SHARED_UNIQUE_ID 64
/* x64/constants-x64.h:18; x64/register-x64.h:318;
 * include/v8-internal.h:953-1046 (uncompressed, unsandboxed),
 * js-function.tq:32-38; globals.h:592-607;
 * js-dispatch-table.h:116,132-150 and -inl.h:54-71.
 * The frame profile additionally requires a verified build configuration;
 * these facts cannot be selected from a version string alone. */
#define XJS_V8_ROOT_BIAS 128
#define XJS_V8_DISPATCH_TABLE 616
#define XJS_V8_FUNCTION_DISPATCH 24
#define XJS_V8_DISPATCH_SHIFT 8
#define XJS_V8_DISPATCH_ENTRY 16
#define XJS_V8_DISPATCH_CODE_SHIFT 16
/* code.h:390-443, with V8_JUMP_TABLE_INFO enabled; code-kind.h:20-35;
 * builtins-definitions.h:64-75,176-303,1587-1589 (WASM on, TSAN off). */
#define XJS_V8_CODE_BUILTIN_ID 90
#define XJS_V8_INTERPRETER_BUILTIN 83
#define XJS_V8_KIND_BUILTIN 3
#define XJS_V8_KIND_MAGLEV 12
#define XJS_V8_KIND_TURBOFAN 13
#endif
