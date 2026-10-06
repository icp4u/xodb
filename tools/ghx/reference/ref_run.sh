#!/bin/sh
# ref_run.sh GHIDRA_INSTALL BIN SPECFILE OUTDIR [noanalysis]
# SPECFILE lines: "<id> <entry-hex> <size-hex> <name>"
# Java headless REFERENCE route (requires a JVM + Ghidra distribution).
# Isolated: HOME/XDG dirs, project and java tmpdir live under $REF_WORK.
set -eu
umask 022
gh=$1 bin=$2 spec=$3 outdir=$4 mode=${5:-analysis}
mkdir -p "$outdir"
here=$(cd "$(dirname "$0")" && pwd)
: "${REF_WORK:?set REF_WORK to a task-owned directory}"
mkdir -p "$REF_WORK/home" "$REF_WORK/tmp" "$REF_WORK/proj"
chmod 0755 "$REF_WORK" "$REF_WORK/home" "$REF_WORK/tmp" "$REF_WORK/proj"
proj=p$$
na=""
[ "$mode" = noanalysis ] && na=-noanalysis
env -u DISPLAY -u WAYLAND_DISPLAY HOME="$REF_WORK/home" XDG_CONFIG_HOME="$REF_WORK/home/.config" \
    XDG_CACHE_HOME="$REF_WORK/home/.cache" GHIDRA_HEADLESS_MAXMEM=${REF_MAXMEM:-2G} \
    GHIDRA_HEADLESS_JAVA_OPTIONS="-Djava.io.tmpdir=$REF_WORK/tmp -Dcpu.core.limit=3" \
    timeout --kill-after=10 ${REF_TIMEOUT:-900} "$gh/support/analyzeHeadless" "$REF_WORK/proj" "$proj" \
    -import "$bin" $na -scriptPath "$here" -postScript GhxRefExport.java "$spec" "$outdir" 60 \
    -deleteProject && rc=0 || rc=$?
# Ghidra's launch.sh forces umask 027; restore 0644 on the owned output
n=0
for f in "$outdir"/*.json; do [ -f "$f" ] && chmod 0644 "$f" && n=$((n+1)); done
[ $n -gt 0 ] || { echo "ref_run: no output produced (rc=$rc)" >&2; [ $rc -ne 0 ] || rc=3; }
exit $rc
