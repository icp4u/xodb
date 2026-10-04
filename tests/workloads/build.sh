#!/bin/sh
# Build the T04 workloads into tests/workloads/out/. Needs only a C compiler.
# Frame pointers and debug info are kept so samplers can unwind and symbolize.
# Leaf functions keep a frame too; without that, frame-pointer unwinding skips
# the caller of the hot leaf. Sibling-call optimization is off so each stall_*
# function stays on the stack of the work it causes; a tail call would erase it.
# CFLAGS_EXTRA appends flags, for example to reproduce either pitfall.
set -eu
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
mkdir -p out "$root/.work/tmp"
export TMPDIR="$root/.work/tmp"
flags="-O2 -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -fno-optimize-sibling-calls -Wall -Wextra -Werror -pthread ${CFLAGS_EXTRA:-}"
${CC:-cc} $flags frameloop.c -o out/frameloop
${CC:-cc} $flags reqserver.c -lm -o out/reqserver
ls -l out
