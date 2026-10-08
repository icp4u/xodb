#!/usr/bin/env python3
"""Live cross-checks of the system observer on owned synthetic loads.

Opt-in (needs a quiet-ish host and a few seconds per load):
    tests/sysstat-live.py [--overhead] [--json results.json]
Loads: a CPU burner, an fsync'ing file writer, a loopback TCP flood and 500
sleeping children, all started and killed here by PID. Ground truth comes
from /proc, ss and df read around each sample. Prints PASS/FAIL per check.
"""
import json, os, signal, socket, statistics, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="xodb-sysstat-live-", dir=os.environ.get("TMPDIR"))
os.chmod(TMP, 0o755)
DUMP = os.path.join(TMP, "sysstat-dump")
HZ = os.sysconf("SC_CLK_TCK")
results, owned = [], []


def check(name, ok, detail):
    results.append({"check": name, "status": "pass" if ok else "fail", "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + ": " + detail, flush=True)


def spawn(args, **kw):
    p = subprocess.Popen(args, **kw)
    owned.append(p)
    return p


def stream(interval_ms, count, groups=0x1FFF, flags=0):
    """Yields (json, monotonic receive time) per sample."""
    p = subprocess.Popen([DUMP, str(interval_ms), str(count), str(groups), str(flags)], stdout=subprocess.PIPE, text=True)
    for line in p.stdout:
        yield json.loads(line), time.monotonic()
    p.wait()


def ok(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def near(a, b, rel, absolute=0.0):
    return ok(a) and abs(a - b) <= max(rel * abs(b), absolute)


def proc_stat(pid):
    t = open(f"/proc/{pid}/stat").read()
    f = t[t.rindex(")") + 2:].split()
    return int(f[11]) + int(f[12])


def proc_io(pid, key):
    for line in open(f"/proc/{pid}/io"):
        if line.startswith(key + ":"):
            return int(line.split()[1])


def netdev(name):
    for line in open("/proc/net/dev"):
        if line.strip().startswith(name + ":"):
            return int(line.split(":")[1].split()[0])


def diskstat(name):
    for line in open("/proc/diskstats"):
        f = line.split()
        if f[2] == name:
            return int(f[9]) * 512


def row(snap, pid):
    for r in snap["processes"]["rows"]:
        if r["pid"] == pid:
            return r


def ground(sampler, probe, label, field_of, rel, absolute=0.0):
    """Correlate sample k's rate with the probe delta between samples k-1 and k."""
    prev = None
    good = bad = 0
    detail = []
    for snap, t in sampler:
        now = (probe(), t)
        if prev is not None:
            truth = (now[0] - prev[0]) / (now[1] - prev[1])
            got = field_of(snap)
            detail.append(f"{got if not ok(got) else round(got, 1)}~{round(truth, 1)}")
            if near(got, truth, rel, absolute):
                good += 1
            else:
                bad += 1
        prev = now
    check(label, good >= 1 and bad == 0, " ".join(detail))


def cpu_burner():
    p = spawn([sys.executable, "-c", "while True: pass"])
    time.sleep(0.3)
    ground(stream(1000, 4, 1 << 11), lambda: proc_stat(p.pid) * 100.0 / HZ, "cpu burner cpu_pct vs /proc/PID/stat",
           lambda s: (row(s, p.pid) or {}).get("cpu_pct"), 0.08, 3)
    p.kill()
    p.wait()


def io_writer():
    path = os.path.join(TMP, "io-writer.bin")
    code = ("import os,time\nf=os.open(%r,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o644)\nb=b'x'*(4<<20)\n"
            "while True:\n os.write(f,b); os.fsync(f); time.sleep(0.05)\n os.lseek(f,0,0) if os.lseek(f,0,1)>(256<<20) else None\n") % path
    p = spawn([sys.executable, "-c", code])
    time.sleep(0.5)
    ground(stream(1000, 4, (1 << 11) | (1 << 3)), lambda: proc_io(p.pid, "write_bytes"), "io writer io_write_bps vs /proc/PID/io",
           lambda s: (row(s, p.pid) or {}).get("io_write_bps"), 0.10, 256 << 10)
    st = os.stat(TMP)
    real = os.path.realpath(f"/sys/dev/block/{os.major(st.st_dev)}:{os.minor(st.st_dev)}")
    disk = os.path.basename(os.path.dirname(real)) if os.path.exists(os.path.join(real, "partition")) else os.path.basename(real)
    if os.path.exists(f"/sys/block/{disk}"):
        ground(stream(1000, 4, 1 << 3), lambda: diskstat(disk), f"io writer disk write_bps vs /proc/diskstats ({disk})",
               lambda s: next((d["write_bps"] for d in s["disks"]["devices"] if d["name"] == disk), None), 0.10, 1 << 20)
    else:
        check("io writer disk write_bps", False, f"no whole disk found for {real}")
    p.kill()
    p.wait()
    os.unlink(path)


FLOOD = r"""
import socket, sys, threading
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
print(srv.getsockname()[1], flush=True)
c = socket.create_connection(srv.getsockname()); s, _ = srv.accept()
def drain():
    while s.recv(1 << 20): pass
threading.Thread(target=drain, daemon=True).start()
buf = b"y" * (1 << 16)
while True: c.sendall(buf)
"""


def tcp_flood():
    p = spawn([sys.executable, "-c", FLOOD], stdout=subprocess.PIPE, text=True)
    port = int(p.stdout.readline())
    time.sleep(0.3)
    ground(stream(1000, 4, 1 << 5), lambda: netdev("lo"), "loopback flood lo rx_bps vs /proc/net/dev",
           lambda s: next((i["rx_bps"] for i in s["network"]["interfaces"] if i["name"] == "lo"), None), 0.10, 1 << 20)
    snap = list(stream(200, 1, (1 << 6) | (1 << 11)))[-1][0]
    ss_t = len(subprocess.run(["ss", "-tanH"], capture_output=True, text=True).stdout.splitlines())
    ss_u = len(subprocess.run(["ss", "-uanH"], capture_output=True, text=True).stdout.splitlines())
    ss_x = len(subprocess.run(["ss", "-xanH"], capture_output=True, text=True).stdout.splitlines())
    c = snap["connections"]
    check("tcp sockets vs ss -tan", near(c["tcp"], ss_t, 0.05, 3), f"{c['tcp']} vs {ss_t}")
    check("udp sockets vs ss -uan", near(c["udp"], ss_u, 0.05, 3), f"{c['udp']} vs {ss_u}")
    check("unix sockets vs ss -xan", near(c["unix"], ss_x, 0.05, 10), f"{c['unix']} vs {ss_x}")
    mine = [r for r in c["rows"] if r["proto"] == "tcp" and r["local"] == f"127.0.0.1:{port}"]
    owners = sorted({r["pid"] for r in mine if ok(r["pid"])})
    ssp = subprocess.run(["ss", "-tnpH", f"sport = :{port}"], capture_output=True, text=True).stdout
    check("flood sockets owned by flood pid (ss -p agrees)",
          len(mine) == 2 and owners == [p.pid] and f"pid={p.pid}," in ssp,
          f"{len(mine)} sockets, owners {owners}, ss {'agrees' if f'pid={p.pid},' in ssp else 'differs'}")
    p.kill()
    p.wait()


def children(n=500):
    code = "import os,time\nfor i in range(%d):\n if os.fork()==0:\n  time.sleep(600); os._exit(0)\nprint('ready',flush=True)\ntime.sleep(600)\n" % n
    before = list(stream(100, 1, 1 << 0))[0][0]["summary"]["processes"]
    p = spawn([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, start_new_session=True)
    p.stdout.readline()
    snap = list(stream(100, 1, (1 << 11) | (1 << 0)))[0][0]
    kids = [r for r in snap["processes"]["rows"] if r["ppid"] == p.pid]
    truth = len(open(f"/proc/{p.pid}/task/{p.pid}/children").read().split())
    check(f"{n} sleeping children by ppid", len(kids) == n == truth, f"{len(kids)} rows, /proc children {truth}")
    listed = sum(1 for e in os.listdir("/proc") if e.isdecimal())  # read right after the sample
    got = snap["summary"]["processes"]
    check("summary process count vs /proc listing (host churn allowed)", near(got, listed, 0.01, 5) and got - before >= n - 5,
          f"{before} -> {got}, /proc lists {listed}")
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()


def df_and_static():
    snap = list(stream(100, 1))[0][0]
    out = subprocess.run(["df", "-B1", "--output=target,size,avail"], capture_output=True, text=True).stdout.splitlines()[1:]
    df = {l.split()[0]: (int(l.split()[1]), int(l.split()[2])) for l in out}
    bad, seen = [], 0
    for m in snap["filesystems"]["mounts"]:
        if not isinstance(m["mount"], str) or m["mount"] not in df or not ok(m["total"]):
            continue
        seen += 1
        size, avail = df[m["mount"]]
        if m["total"] != size or not near(m["avail"], avail, 0.01, 64 << 20):
            bad.append(m["mount"])
    check("filesystems vs df", seen > 0 and not bad, f"{seen} mounts compared, mismatched {bad}")
    total = int(open("/proc/meminfo").readline().split()[1]) * 1024
    check("memory total vs /proc/meminfo", snap["memory"]["total"] == total, f"{snap['memory']['total']}")
    cpus = os.cpu_count()
    check("logical CPUs vs os.cpu_count", snap["cpu"]["online"] == cpus, f"{snap['cpu']['online']} vs {cpus}")
    for s in snap["power"]["sensors"]:
        if s["kind"] == "temp_c" and s["chip"] in ("k10temp", "coretemp") and ok(s["value"]):
            check("cpu temperature sensor is plausible", 5 < s["value"] < 110, f"{s['chip']} {s['label']} {s['value']}")
            break
    unavailable = {}
    def walk(v, path):
        if isinstance(v, dict):
            if v.get("state") in ("unavailable", "stale") and "why" in v:
                key = path.split(".")[-1]
                unavailable.setdefault(f"{key}: {v['why']}", 0)
                unavailable[f"{key}: {v['why']}"] += 1
            for k, x in v.items():
                walk(x, path + "." + k)
        elif isinstance(v, list):
            for x in v:
                walk(x, path)
    walk({k: v for k, v in snap.items() if k != "groups"}, "")
    return unavailable


def overhead(target_total=2000):
    have = list(stream(100, 1, 1))[0][0]["summary"]["processes"]
    n = max(0, target_total - have)
    code = "import os,time\nfor i in range(%d):\n if os.fork()==0:\n  time.sleep(900); os._exit(0)\nprint('ready',flush=True)\ntime.sleep(900)\n" % n
    p = spawn([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, start_new_session=True)
    p.stdout.readline()
    out = {}
    for label, groups in (("all", 0x1FFF), ("all-but-connections", 0x1FFF & ~(1 << 6)), ("processes", 1 << 11),
                          ("no-processes-no-connections", 0x1FFF & ~(1 << 6) & ~(1 << 11))):
        for interval, count in ((1000, 12), (250, 40)):
            snaps = [s for s, _ in stream(interval, count, groups)][2:]
            cpu = [s["self"]["cpu_ms"] for s in snaps]
            wall = [s["self"]["wall_ms"] for s in snaps]
            sc = [s["self"]["syscalls_estimate"] for s in snaps]
            procs = snaps[-1].get("summary", {}).get("processes") if "summary" in snaps[-1] else None
            row_ = {"interval_ms": interval, "samples": len(snaps), "processes": procs,
                    "cpu_ms_median": round(statistics.median(cpu), 2), "cpu_ms_p95": round(sorted(cpu)[int(len(cpu) * .95) - 1], 2),
                    "wall_ms_median": round(statistics.median(wall), 2), "syscalls_median": int(statistics.median(sc)),
                    "pct_of_core": round(100 * statistics.median(cpu) / interval, 2)}
            out[f"{label}@{interval}ms"] = row_
            print(f"overhead {label}@{interval}ms: {row_}", flush=True)
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    return out


def main():
    subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", os.path.join(ROOT, "src/runtime"),
                    os.path.join(ROOT, "tests/sysstat-dump.c"), os.path.join(ROOT, "src/runtime/sysstat.c"), os.path.join(ROOT, "src/runtime/sysstat_nvml.c"), "-pthread", "-ldl", "-o", DUMP], check=True)
    report = {}
    try:
        cpu_burner()
        io_writer()
        tcp_flood()
        children()
        report["unavailable"] = df_and_static()
        if "--overhead" in sys.argv:
            report["overhead"] = overhead()
    finally:
        for p in owned:
            if p.poll() is None:
                p.kill()
                p.wait()
        subprocess.run(["rm", "-rf", TMP])
    report["checks"] = results
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w") as f:
            json.dump(report, f, indent=1)
    failed = [r for r in results if r["status"] != "pass"]
    print(f"sysstat live: {len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
