#ifndef XODB_IMPORT_SHA256_H
#define XODB_IMPORT_SHA256_H
#include <stddef.h>
#include <stdint.h>
void sha256_hex(const void *, size_t, char out[65]);
struct jvm_budget;
/* C05-R3: as sha256_hex, polling the budget's cancellation once per MiB;
 * returns -1 (out undefined) when cancelled. */
int sha256_hex_cancellable(const void *, size_t, char out[65], struct jvm_budget *);
#endif
