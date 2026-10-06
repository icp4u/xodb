#!/usr/bin/env python3
"""Owned JIT fixture check: run tests/fixtures/jit-fixture twice (two process
incarnations), then check xodb-jitmap attribution against recorded ground truth
before/after a move and after address reuse, plus unavailable/ambiguous outcomes
when time, clock relation, identity or lifetime evidence is missing.

usage: jitmap-fixture.py BUILD_DIR OUT_DIR   (BUILD_DIR holds xodb-jitmap, jit-fixture)
"""
import json
import os
import re
import subprocess
import sys

build, out = sys.argv[1], sys.argv[2]
cli = os.path.join(build, "xodb-jitmap")
fixture = os.path.join(build, "jit-fixture")
os.makedirs(out, mode=0o755, exist_ok=True)
failures = []
checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)
        print("FAIL:", what, file=sys.stderr)


def run_fixture():
    pid = subprocess.run([fixture, out], check=True, capture_output=True, text=True, timeout=30).stdout.strip()
    truth = {"pid": int(pid), "loads": [], "obs": [], "moves": []}
    for line in open(os.path.join(out, "truth-%s.txt" % pid), encoding="utf-8"):
        line = line.rstrip("\n")
        key, _, rest = line.partition(" ")
        if key in ("load", "obs", "move", "close", "debug"):
            fields = dict(re.findall(r"(\w+)=(\S+)", rest.split(" name=")[0]))
            if " name=" in rest:
                fields["name"] = rest.split(" name=", 1)[1]
            if key == "close":
                truth["close"] = int(fields["time"])
            elif key == "debug":
                truth["debug"] = fields
            else:
                truth[key + "s" if key != "obs" else "obs"].append(fields)
        else:
            truth[key] = rest
    truth["truth_path"] = os.path.join(out, "truth-%s.txt" % pid)
    truth["dump"] = os.path.join(out, "jit-%s.dump" % pid)
    truth["map"] = os.path.join(out, "perf-%s.map" % pid)
    truth["maps"] = os.path.join(out, "maps-%s.txt" % pid)
    return truth


def jitmap(*args):
    p = subprocess.run([cli, *args], capture_output=True, text=True, timeout=30)
    if p.returncode != 0:
        raise RuntimeError("xodb-jitmap %s failed: %s" % (" ".join(args), p.stderr))
    return json.loads(p.stdout)


def resolve(truth, ats, *extra, sources=("--jitdump",), pre=()):
    args = ["resolve", "--truth", truth["truth_path"], *pre]
    for s in sources:
        args += [s, truth["dump"] if s == "--jitdump" else truth["map"]]
    args += list(extra)
    for a in ats:
        args += ["--at", a]
    return jitmap(*args)["results"]


def at(pc, time=None):
    return "0x%x" % pc + ("" if time is None else "@%d" % time)


runs = [run_fixture(), run_fixture()]
summary = {"runs": []}
for n, t in enumerate(runs):
    other = runs[1 - n]
    loads = {int(l["index"]): l for l in t["loads"]}
    alpha, beta = loads[1], loads[2]
    a1, a2 = int(alpha["addr"], 16), int(t["moves"][0]["to"], 16)
    check(int(beta["addr"], 16) == a1, "fixture reused address A1")

    # Decode: code bytes and names match ground truth, perf map parses cleanly.
    d = jitmap("decode", "--code", "--truth", t["truth_path"], "--jitdump", t["dump"], "--perfmap", t["map"])
    check(not d["diagnostics"], "no diagnostics on owned fixture: %s" % d["diagnostics"])
    src = d["sources"][0]
    check(src["complete"] and src["jitdump"]["closed"] and src["jitdump"]["byte_order"] == "little", "jitdump header")
    vs = [v for v in d["versions"] if v["source"] == 0]
    check(len(vs) == 3, "three code versions (load, move-in, reuse)")
    for v in vs:
        if v["begin"]["kind"] == "load":
            l = loads[int(v["code_index"])]
            check(v["code_hex"] == l["code"] and v["name"] == l["name"] and v["start"] == l["addr"],
                  "load %s bytes/name/address" % v["code_index"])
            check(int(v["begin"]["time"]) == int(l["time"]), "load %s timestamp" % v["code_index"])
    moved = [v for v in vs if v["begin"]["kind"] == "move_in"]
    check(len(moved) == 1 and moved[0]["moved_from_version"] == 1 and moved[0]["start"] == "0x%x" % a2,
          "move creates new version linked to predecessor")
    check(vs[0]["end"]["kind"] == "move_out", "alpha at A1 ended by move")
    check(len([v for v in d["versions"] if v["source"] == 1]) == 3, "perf map has three untimed lines")

    # Each observation: frame 0 is the return address inside generated code.
    for o in t["obs"]:
        pcs = [int(x, 16) for x in o["frames"].split(",")]
        time = int(o["time"])
        r = resolve(t, [at(pcs[0] - 1, time)])[0]["result"]
        ok = r["outcome"] == "resolved" and len(r["candidates"]) == 1
        c = r["candidates"][0]["code"] if r["candidates"] else {}
        check(ok and c.get("code_index") == o["expect_index"] and c.get("start") == o["expect_start"],
              "obs %s resolves to code_index %s at %s: %s" % (o["id"], o["expect_index"], o["expect_start"], r))
        # Same PC without a time: A1 hosted alpha and beta.
        r = resolve(t, [at(pcs[0] - 1)])[0]["result"]
        want = "ambiguous" if o["expect_start"] == "0x%x" % a1 else "unverified"
        check(r["outcome"] == want and "no_query_time" in r["reasons"], "obs %s untimed -> %s" % (o["id"], want))
        # Perf map alone: never resolved; ambiguous where the address was reused.
        r = resolve(t, [at(pcs[0] - 1, time)], sources=("--perfmap",))[0]["result"]
        check(r["outcome"] == want and "untimed_snapshot" in r["reasons"], "obs %s perf map -> %s" % (o["id"], want))
        # Wrong incarnation (other run's identity with this run's pid): skipped.
        r = resolve(t, [at(pcs[0] - 1, time)], "--q-start-ticks", str(int(t["start_ticks"]) + 1))[0]["result"]
        check(r["outcome"] == "no_match" and "identity_skipped" in r["reasons"], "obs %s pid reuse" % o["id"])
        # PID only: unverified, not resolved.
        r = resolve(t, [at(pcs[0] - 1, time)], "--q-unknown-identity")[0]["result"]
        check(r["outcome"] == "unverified" and "identity_unverified" in r["reasons"], "obs %s pid only" % o["id"])
        # Unrelated clock domain: never resolved.
        r = resolve(t, [at(pcs[0] - 1, time)], "--q-clock-scope", "00" * 16)[0]["result"]
        check(r["outcome"] in ("unavailable", "ambiguous") and "clock_unrelated" in r["reasons"],
              "obs %s unrelated clock -> %s" % (o["id"], r["outcome"]))
        # Declared relation into another domain (+1 s, +-1 us): resolved again.
        unc = 1000
        r = resolve(t, [at(pcs[0] - 1, time + 10**9)], "--q-clock-scope", "ab" * 16,
                    pre=("--map-offset", str(10**9), "--map-uncertainty", str(unc), "--map-target-scope", "ab" * 16))
        r = r[0]["result"]
        near_close = time + unc >= t["close"]
        want = "unverified" if near_close else "resolved"
        check(r["outcome"] == want and r["candidates"][0]["code"]["code_index"] == o["expect_index"] and
              (not near_close or "after_coverage" in r["reasons"]),
              "obs %s declared clock map -> %s: %s" % (o["id"], want, r["outcome"]))
        # Same declaration, but the observation is within the uncertainty of a lifetime boundary.
        bound = int(loads[int(o["expect_index"])]["time"]) if o["expect_start"] == alpha["addr"] or \
            o["expect_index"] == "2" else int(t["moves"][0]["time"])
        r = resolve(t, [at(pcs[0] - 1, bound + 10**9 + unc // 2)], "--q-clock-scope", "ab" * 16,
                    pre=("--map-offset", str(10**9), "--map-uncertainty", str(unc), "--map-target-scope", "ab" * 16))
        r = r[0]["result"]
        check(r["outcome"] in ("unverified", "ambiguous") and "boundary_uncertain" in r["reasons"],
              "obs %s near boundary under declared uncertainty -> %s" % (o["id"], r["outcome"]))
        # Mixed stack: raw PCs kept, JIT frame labelled, native frames from maps, logical separate.
        s = jitmap("stack", "--truth", t["truth_path"], "--jitdump", t["dump"], "--time", str(time), "--pcs",
                   o["frames"], "--maps", t["maps"], "--logical", o["logical"])
        f = s["physical_frames"]
        check([int(x["raw_pc"], 16) for x in f] == pcs, "obs %s raw PCs preserved" % o["id"])
        check(f[0]["kind"] == "jit" and f[0]["jit"]["outcome"] == "resolved", "obs %s frame 0 jit" % o["id"])
        check(all(x["kind"] == "native" for x in f[1:]), "obs %s callers native" % o["id"])
        check(f[1]["native_mapping"]["path"].endswith("/jit-fixture"), "obs %s caller in fixture image" % o["id"])
        line = f[0]["jit"]["candidates"][0]["source_line"]
        if o["expect_index"] == "1":
            check(line and line["file"] == "fixture-alpha.toy" and line["line"] == 2 and line["derived"],
                  "obs %s derived line via %s" % (o["id"], line))
        else:
            check(line is None, "beta has no debug info, no fabricated line")
        check(s["logical_frames"]["frames"] == o["logical"].split(">") and s["logical_frames"]["bridge"] is None,
              "obs %s logical frames separate" % o["id"])
        # ASLR / second incarnation: this PC under the other run's identity.
        r = jitmap("resolve", "--truth", other["truth_path"], "--jitdump", other["dump"], "--truth", t["truth_path"],
                   "--jitdump", t["dump"], "--q-pid", str(other["pid"]), "--q-start-ticks", other["start_ticks"],
                   "--at", at(pcs[0] - 1, time))["results"][0]["result"]
        check(all(c["code"]["source"] == 0 for c in r["candidates"]) and "identity_skipped" in r["reasons"],
              "obs %s other incarnation never borrows this run's code" % o["id"])

    # Lifetime edges at A1 / A2 between records.
    move_t, beta_t = int(t["moves"][0]["time"]), int(beta["time"])
    alpha_t = int(alpha["time"])
    gap = (move_t + beta_t) // 2
    r = resolve(t, [at(a1, gap), at(a2, alpha_t + (move_t - alpha_t) // 2), at(a1, alpha_t - 1),
                    at(a2, t["close"] + 1)])
    check(r[0]["result"]["outcome"] == "no_match" if move_t + 1 < beta_t else True, "A1 empty between move and reuse")
    check(r[1]["result"]["outcome"] == "no_match", "A2 empty before move")
    check(r[2]["result"]["outcome"] == "no_match", "A1 empty before load")
    check(r[3]["result"]["outcome"] == "unverified" and "after_coverage" in r[3]["result"]["reasons"],
          "after CODE_CLOSE is unverified")
    summary["runs"].append({"pid": t["pid"], "start_ticks": t["start_ticks"], "a1": "0x%x" % a1, "a2": "0x%x" % a2,
                            "observations": len(t["obs"])})

check(runs[0]["pid"] != runs[1]["pid"], "two incarnations")
summary.update(checks=checks, failures=failures)
print(json.dumps(summary, indent=1))
sys.exit(1 if failures else 0)
