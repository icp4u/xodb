"""Run the fixed-work benchmarks: off vs sampling intervals, repeated; median wall overhead.
usage: bench.py BUILD_DIR OUT.json REPS"""
import json, os, statistics, subprocess, sys
build, out, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
here = os.path.dirname(os.path.abspath(__file__))
ext = os.path.join(build, "ruby-3.4.10", "xodb_lframes_rb.so")
configs = {
    "python3.14": (["python3", "-B", os.path.join(here, "bench_python.py")], ["22", "800"]),
    "ruby3.4+ext": (["ruby", os.path.join(here, "bench_ruby.rb")], ["25", "400", ext]),
}
report = {}
for name, (cmd, tail) in configs.items():
    rows = {}
    for interval in ["0", "10", "5", "1"]:
        runs = []
        for r in range(reps):  # interleave-free but repeated; host noise is reported via spread
            path = os.path.join(build, "bench-%s-%s-%d.jsonl" % (name, interval, r))
            p = subprocess.run(cmd + [path, interval] + tail, capture_output=True, text=True, timeout=600)
            if p.returncode:
                raise SystemExit(p.stderr)
            runs.append(json.loads(p.stdout))
            if os.path.exists(path):
                os.unlink(path)
        walls = [x["wall_ns"] for x in runs]
        rows[interval] = {"wall_ns_median": statistics.median(walls), "wall_ns_min": min(walls), "wall_ns_max": max(walls),
                          "process_cpu_ns_median": statistics.median(x["process_cpu_ns"] for x in runs),
                          "acquisitions_median": statistics.median(x["exporter"]["acquisitions"] for x in runs) if runs[0]["exporter"] else 0,
                          "sampling_cost_ns_median": statistics.median(x["exporter"]["sampling_cost_ns"] for x in runs) if runs[0]["exporter"] else 0,
                          "lost_ticks_median": statistics.median(x["exporter"]["lost_ticks"] for x in runs) if runs[0]["exporter"] else 0,
                          "runs": runs}
    base = rows["0"]["wall_ns_median"]
    for interval, row in rows.items():
        row["wall_overhead_pct"] = round(100.0 * (row["wall_ns_median"] - base) / base, 2)
        if row["acquisitions_median"]:
            row["cost_per_acquisition_us"] = round(row["sampling_cost_ns_median"] / row["acquisitions_median"] / 1000, 1)
    report[name] = rows
json.dump(report, open(out, "w"), indent=1)
for name, rows in report.items():
    for interval, row in rows.items():
        print(name, "interval_ms=%s" % interval, "wall_ms=%.1f" % (row["wall_ns_median"] / 1e6),
              "overhead=%s%%" % row["wall_overhead_pct"], "acq=%s" % row["acquisitions_median"],
              "lost=%s" % row["lost_ticks_median"], "cost/acq_us=%s" % row.get("cost_per_acquisition_us"))
