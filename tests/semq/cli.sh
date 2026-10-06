#!/bin/sh
# CLI contract: distinct exit codes per outcome, parseable JSON for every query
# kind on every fixture, bounded text, and no crash on any adversarial input.
# usage: cli.sh XSQ FIXTURE_DIR
set -u
X=$1 F=$2
fail=0 n=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xsq-cli.XXXXXX")
chmod 0755 "$tmp"
trap 'rm -rf "$tmp"' EXIT
expect() { # expect CODE cmd...
	want=$1; shift
	n=$((n + 1))
	timeout 60 "$@" > "$tmp/out" 2> "$tmp/err"
	got=$?
	if [ "$got" != "$want" ]; then
		echo "FAIL exit $got (want $want): $*"; head -3 "$tmp/err"; fail=$((fail + 1))
	fi
}
json() { # json cmd... : stdout must be one JSON document
	n=$((n + 1))
	timeout 60 "$@" --json - > "$tmp/j" 2> /dev/null
	if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/j" 2> "$tmp/e"; then
		echo "FAIL json: $*"; tail -1 "$tmp/e"; fail=$((fail + 1))
	fi
}
U=$F/synthetic/units.xsg
expect 0 "$X" validate "$U"
expect 0 "$X" slice "$U" --op 1007 --in 1
expect 3 "$X" controls "$U" --op 8002            # partial: nonterminating
expect 5 "$X" controls "$U" --op 8001            # unsupported
expect 6 "$X" slice "$U" --op 424242             # not found
expect 6 "$X" slice "$U" --op 1001               # CBRANCH has no output
expect 6 "$X" slice "$U" --origin no-such-origin
expect 4 "$X" slice "$U" --op 3010 --in 1 --cancel
expect 3 "$X" slice "$U" --op 3010 --in 1 --max-nodes 2
expect 2 "$X" slice "$U"                          # no selector
expect 2 "$X" slice "$U" --op 1 --bogus
expect 2 "$X"
expect 7 "$X" validate "$F/malformed/dup-op-id.xsg"
expect 8 "$X" validate "$F/malformed/oversized-line.xsg"
expect 9 "$X" validate "$F/does-not-exist.xsg"
# --lines bounds the explanation and says so; the producer qualification
# line is always printed in addition (C02-R3: never dropped from text output)
"$X" slice "$U" --op 7007 --in 1 --lines 2 > "$tmp/t"
n=$((n + 1))
if [ "$(wc -l < "$tmp/t")" -ne 4 ] || ! grep -q "more lines omitted" "$tmp/t" ||
   ! grep -q "^  input qualification=.* verified_semantics=no$" "$tmp/t"; then
	echo "FAIL --lines bound"; fail=$((fail + 1))
fi
# bench (C02-R3): each sampled query is its own operation on the loaded graph,
# so load bytes + that query's bytes never exceed --max-bytes
"$X" bench "$U" --sample 4 > "$tmp/b0" 2>/dev/null
lb=$(sed -n 's/.*"load_bytes":\([0-9]*\).*/\1/p' "$tmp/b0")
n=$((n + 1))
if [ -z "$lb" ]; then
	echo "FAIL bench reports no load_bytes"; fail=$((fail + 1))
else
	"$X" bench "$U" --sample 4 --max-bytes "$lb" > "$tmp/b1" 2>/dev/null
	n=$((n + 1))
	if ! grep -q '"query_max_bytes":1,' "$tmp/b1" || ! grep -q '"last_slice":{"status":"partial","limit":"memory"' "$tmp/b1" ||
	   grep -q '"slice_status":{"ok"' "$tmp/b1"; then
		echo "FAIL bench with the whole budget used by loading still ran queries"; head -c 600 "$tmp/b1"; fail=$((fail + 1))
	fi
	"$X" bench "$U" --sample 4 --max-bytes $((lb + 600)) > "$tmp/b2" 2>/dev/null
	n=$((n + 1))
	q=$(sed -n 's/.*"last_slice":{[^}]*"bytes":\([0-9]*\).*/\1/p' "$tmp/b2")
	if ! grep -q '"query_max_bytes":600,' "$tmp/b2" || [ -z "$q" ] || [ "$q" -gt 600 ]; then
		echo "FAIL bench per-query budget"; head -c 600 "$tmp/b2"; fail=$((fail + 1))
	fi
fi
# JSON for every op output slice and control query in every valid fixture
for f in "$U" "$F"/compiled/*.xsg; do
	[ -e "$f" ] || continue
	for id in $("$X" ops "$f" | awk '{print $2}'); do
		json "$X" controls "$f" --op "$id"
		"$X" ops "$f" | awk -v id="$id" '$2==id' | grep -q " out=" && json "$X" slice "$f" --op "$id"
	done
done
# no crash (exit > 9 or signal) on any adversarial input
for f in "$F"/malformed/*.xsg; do
	n=$((n + 1))
	timeout 60 "$X" validate "$f" > /dev/null 2>&1
	rc=$?
	if [ $rc -gt 9 ]; then echo "FAIL crash $rc on $f"; fail=$((fail + 1)); fi
done
echo "cli: $n checks, $fail failures"
[ $fail -eq 0 ]
