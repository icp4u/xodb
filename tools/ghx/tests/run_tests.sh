#!/bin/sh
# Run the C01 suites against a build (C01-R3).
#   sh tools/ghx/tests/run_tests.sh BIN GHIDRA_SRC FIXDIR SCRATCH RESULTS_DIR
# BIN holds ghx_worker, ghx_supervise and ghx_elfcheck; GHIDRA_SRC is the
# built copy from build_ghidra.sh; FIXDIR is from fixtures/build_fixtures.sh.
# Exit 0 only if every suite passes.
set -u
umask 022
here=$(cd "$(dirname "$0")" && pwd)
bin=$1 gs=$2 fix=$3 scratch=$4 res=$5
mkdir -p "$scratch" "$res"
chmod 0755 "$scratch" "$res"
rc=0
mkdir -p "$scratch/elfcheck"
timeout 300 "$bin/ghx_elfcheck" --selftest "$scratch/elfcheck" > "$res/elfcheck.log" 2>&1 || rc=1
tail -1 "$res/elfcheck.log"
timeout 900 python3 "$here/supervisor_tests.py" "$bin/ghx_supervise" "$scratch/supervisor" \
	"$res/supervisor.json" "$bin/ghx_worker" "$gs" "$fix/fx-gcc-O0" > "$res/supervisor.log" 2>&1 || rc=1
tail -1 "$res/supervisor.log"
timeout 1800 python3 "$here/worker_tests.py" "$bin/ghx_worker" "$gs" "$fix" "$scratch/worker" \
	"$res/worker.json" > "$res/worker.log" 2>&1 || rc=1
tail -1 "$res/worker.log"
timeout 900 python3 "$here/boundary_tests.py" "$bin/ghx_worker" "$gs" "$scratch/boundary" \
	"$res/boundary.json" > "$res/boundary.log" 2>&1 || rc=1
tail -1 "$res/boundary.log"
exit $rc
