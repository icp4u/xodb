#ifndef XODB_DEMANGLE_H
#define XODB_DEMANGLE_H
#include <stddef.h>
#define XODB_DEMANGLE_INPUT 4096
#define XODB_DEMANGLE_OUTPUT 1024
#ifdef __cplusplus
extern "C" {
#endif
/* Compact Itanium C++ name: parameter/template-argument types are omitted.
 * Returns 1 only for a complete parse fitting out, including its terminator.
 * Refusal clears out[0] when writable. Never allocates or calls a full demangler.
 * Input need not be terminated; embedded NULs are refused. */
int xodb_demangle_name(const char *name, size_t length, char *out, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
