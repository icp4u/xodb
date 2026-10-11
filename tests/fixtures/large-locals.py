#!/usr/bin/env python3
"""Owned synthetic target: one frame whose locals make a large presentation.

LOCALS struct locals with NAME-character identifiers. The debugger shows each
local plus up to eight fields, so the prepared locals for this one frame carry
about LOCALS * 9 * NAME bytes of names. Usage: gen_big_locals.py LOCALS NAME > big.c
"""
import sys
count, width = int(sys.argv[1]), int(sys.argv[2])
print('#include <signal.h>\n#include <unistd.h>')
print('struct pack { long ' + ', '.join(f'field_{i}' for i in range(8)) + '; };')
print('int main(void) {')
for i in range(count):
    print(f'    volatile struct pack {"v" * (width - 8)}{i:08d} = {{ {i}, 1, 2, 3, 4, 5, 6, 7 }};')
print('    __asm__ volatile ("int3");')
print('    for (;;) pause();\n}')
