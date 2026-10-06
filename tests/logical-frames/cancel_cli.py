#!/usr/bin/env python3
"""C05-R2: SIGINT cancels a running xodb-lframes decode through the shared
xlf_cancel object; the process reports a typed 'cancelled' error (exit 2) and no
result. The same input then succeeds without a signal.
usage: cancel_cli.py XODB_LFRAMES [--stacks N]"""
import json, os, signal, subprocess, sys, tempfile, time

cli = sys.argv[1]
stacks = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--stacks" else 150000
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from exact_oracle import HEADER  # noqa: E402

base = os.environ.get("XODB_TEST_TMPDIR") or None
fails = 0
with tempfile.TemporaryDirectory(prefix="xlf-cancel-", dir=base) as tmp:
    os.chmod(tmp, 0o755)
    path = os.path.join(tmp, "big.jsonl")
    fr = ",".join('{"function":"f%d","kind":"logical","line":1,"provenance":"runtime"}' % (j % 4) for j in range(12))
    with open(path, "w") as f:
        f.write(json.dumps(HEADER, separators=(",", ":")) + "\n")
        for i in range(4):
            f.write('{"type":"function","id":"f%d","name":"n%d","qualified":null,"code":null,"first_line":null,"frame_kind":"logical"}\n' % (i, i))
        f.write('{"type":"thread","id":"t","language_id":null,"name":null,"os_tid":null,"os_tid_reason":"x"}\n')
        f.write('{"type":"acquisition","seq":1,"start_ns":null,"end_ns":null,"stacks":%d}\n' % stacks)
        for i in range(stacks):
            f.write('{"type":"stack","id":"s%d","acquisition":1,"thread":"t","start_ns":null,"end_ns":null,"trigger":"t",'
                    '"weight":"18446744073709551615","state":"complete","omitted":null,"reason":null,"frames":[%s]}\n' % (i, fr))
        f.write('{"type":"end","records":%d,"acquisitions":1,"stacks":%d,"status":"complete"}\n' % (stacks + 7, stacks))
    size = os.path.getsize(path)
    t0 = time.monotonic()
    p = subprocess.Popen([cli, "aggregate", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    p.send_signal(signal.SIGINT)  # our own child only
    out, err = p.communicate(timeout=120)
    lines = out.decode().strip().splitlines()
    got = json.loads(lines[-1]) if lines else {}
    ok = p.returncode == 2 and got.get("error") == "cancelled" and len(lines) == 1 and got.get("status") == "error"
    print(("ok   " if ok else "FAIL ") + f"SIGINT after 50 ms on {size} bytes: rc={p.returncode} {got} "
          f"({time.monotonic() - t0:.2f}s)")
    fails += not ok
    p = subprocess.run([cli, "aggregate", path, "--top", "0"], capture_output=True, timeout=300)
    got = json.loads(p.stdout)
    want = str(stacks * (2**64 - 1))
    ok = p.returncode == 0 and got["total_weight"] == want
    print(("ok   " if ok else "FAIL ") + f"uncancelled run exact: total {got.get('total_weight')} == {want}; "
          f"decode peak {got.get('budget', {}).get('decode_peak_bytes')}")
    fails += not ok
print(f"2 checks, {fails} failures")
sys.exit(1 if fails else 0)
