/* Shared declarations for the owned corpus fixture (C). */
#ifndef XF_DEP_H
#define XF_DEP_H
#include <stdint.h>
struct dep_record { uint32_t id; uint16_t kind; uint8_t flags; char tag[9]; double weight; };
extern volatile uint64_t dep_counter;
int dep_add(int a, int b);
struct dep_record dep_make(uint32_t id, const char *tag);
uint64_t util_mix(uint64_t value, unsigned rounds);
int util_sum(int count, ...);
uint64_t types_touch(uint64_t seed);
#endif
