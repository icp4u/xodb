#!/bin/sh
# mkreq.sh BIN ORACLE FUNC [ID] [extra fields...]
# Emit one DECOMPILE request line using entry/size from the retained symbol
# oracle (needed for stripped inputs; this is declared input, not discovery).
set -eu
bin=$1 oracle=$2 fn=$3 id=${4:-$fn}
shift 3; [ $# -gt 0 ] && shift
line=$(awk -v fn="$fn" '$1==fn{print $2, $3}' "$oracle")
[ -n "$line" ] || { echo "mkreq: $fn not in $oracle" >&2; exit 1; }
set -- "$@"
entry=$(printf '0x%x' "$(echo "$line" | cut -d' ' -f1)")
size=$(printf '0x%x' "$(echo "$line" | cut -d' ' -f2)")
extra=""
for kv in "$@"; do extra="$extra	$kv"; done
printf 'DECOMPILE\tid=%s\telf=%s\tentry=%s\tsize=%s\tname=%s%s\n' "$id" "$bin" "$entry" "$size" "$fn" "$extra"
