#ifndef XODB_JAVASCRIPT_CHECKS_H
#define XODB_JAVASCRIPT_CHECKS_H
#include <stdint.h>
#include <string.h>

/* Shared by libdw and ranged readers. This is the sole cross-check table. */
static const struct {
    const char *owner, *name;
    uint64_t value;
    int frame_config;
} checks[] = {
    {"JSArray", "kLengthOffset", 24, 0},
    {"ScopeInfo", "kFlags", 0, 0},
    {"ScopeInfo", "kParameterCount", 1, 0},
    {"ScopeInfo", "kContextLocalCount", 2, 0},
    {"ScopeInfo", "kPositionInfoStart", 3, 0},
    {"ScopeInfo", "kPositionInfoEnd", 4, 0},
    {"ScopeInfo", "kVariablePartIndex", 5, 0},
    {"BytecodeArray", "kSourcePositionTableOffset", 24, 0},
    {"TrustedByteArray", "kLengthOffset", 8, 0},
    {"TrustedByteArray", "kHeaderSize", 16, 0},
    {"Code", "kDeoptimizationDataOrInterpreterDataOffset", 8, 0},
    {"Code", "kPositionTableOffset", 16, 0},
    {"Code", "kBuiltinIdOffset", 90, 1},
    {"ExternalString", "kResourceDataOffset", 24, 0},
    {"Script", "kLineOffsetOffset", 24, 0},
    {"Script", "kColumnOffsetOffset", 32, 0},
    {"SharedFunctionInfo", "kTrustedFunctionDataOffset", 8, 0},
    {"SharedFunctionInfo", "kUniqueIdOffset", 64, 0},
    {"JSFunction", "kDispatchHandleOffset", 24, 1},
    {"Internals", "kIsolateJSDispatchTableOffset", 616, 1},
    {"JSDispatchEntry", "kObjectPointerShift", 16, 1},
    {"Builtin", "kInterpreterEntryTrampoline", 83, 1},
    {"", "kRootRegisterBias", 128, 1},
    {"", "kJSDispatchHandleShift", 8, 1},
    {"", "kJSDispatchTableEntrySize", 16, 1},
};
static int owner_match(const char *actual, const char *want) {
    if (!strcmp(actual, want)) return 1;
    const char prefix[] = "TorqueGenerated";
    if (strncmp(actual, prefix, sizeof prefix - 1)) return 0;
    actual += sizeof prefix - 1;
    size_t n = strlen(want);
    return !strncmp(actual, want, n) && actual[n] == '<';
}
#endif
