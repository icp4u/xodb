#!/usr/bin/env python3
"""Bounded Linux observation experiments using the existing xodb recipe CLI."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import random
import re
import resource
import selectors
import signal
import stat
import statistics
import subprocess
import sys
import time
from fractions import Fraction

MAX_JSON = 4 * 1024 * 1024
MAX_INPUT = 256 * 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_LOG = 2 * 1024 * 1024
RESERVE = 8 * 1024 * 1024
LABEL = re.compile(r"[A-Za-z0-9_-]{1,48}\Z")
STATUSES = {"completed", "incomplete", "failed", "timeout", "cancelled", "output_budget", "not_run"}
CANCEL = False


def stop(_sig, _frame):
    global CANCEL
    CANCEL = True


def pairs(items):
    out = {}
    for key, value in items:
        if key in out:
            raise ValueError("duplicate JSON key")
        out[key] = value
    return out


def loads(data):
    if len(data) > MAX_JSON:
        raise ValueError("JSON byte limit")
    return json.loads(data, object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON")))


def encoded(value):
    data = (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()
    if len(data) > MAX_JSON:
        raise ValueError("JSON byte limit")
    return data


def integer(value, lo=0, hi=(1 << 128)-1):
    if type(value) is str:
        value = int(value, 16 if value.startswith("0x") else 10)
    if type(value) is not int or not lo <= value <= hi:
        raise ValueError("integer outside bounds")
    return value


def keys(value, required, optional=()):
    if type(value) is not dict or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise ValueError("unexpected or missing fields")


def string(value):
    if type(value) is not str or not value or len(value) > 4096 or "\0" in value:
        raise ValueError("invalid argument")
    return value


def bounded_read(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise ValueError("input must be a bounded regular file")
        data = bytearray()
        while True:
            part = os.read(fd, min(1048576, maximum + 1 - len(data)))
            if not part:
                break
            data.extend(part)
            if len(data) > maximum:
                raise ValueError("input byte limit")
        after = os.fstat(fd)
        signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if signature(before) != signature(after) or len(data) != before.st_size:
            raise ValueError("input changed during pinning")
        return bytes(data)
    finally:
        os.close(fd)


class Pin:
    """Every launch uses the hashed sealed bytes, never the original pathname."""
    def __init__(self, path, maximum, executable=False):
        data = bounded_read(path, maximum)
        if executable and not data.startswith(b"\x7fELF"):
            raise ValueError("executables must be ELF (scripts/interpreters must be declared separately)")
        self.fd = os.memfd_create("xodb-experiment", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        try:
            offset = 0
            while offset < len(data):
                offset += os.write(self.fd, data[offset:offset+1048576])
            os.fchmod(self.fd, 0o555 if executable else 0o444)
            fcntl.fcntl(self.fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
            # Verify after sealing: the launched inode, not just our source
            # buffer, must contain exactly the bytes recorded in the plan.
            digest = hashlib.sha256()
            offset = 0
            while offset < len(data):
                block = os.pread(self.fd, min(1048576, len(data) - offset), offset)
                if not block:
                    raise ValueError("sealed input truncated")
                digest.update(block)
                offset += len(block)
            if os.fstat(self.fd).st_size != len(data) or digest.digest() != hashlib.sha256(data).digest():
                raise ValueError("sealed input changed before sealing")
        except BaseException:
            self.close()
            raise
        self.identity = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        self.path = f"/proc/{os.getpid()}/fd/{self.fd}"

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def publish(path, value):
    data = encoded(value)
    temporary = path.with_name(path.name + ".partial")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o644)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.link(temporary, path, follow_symlinks=False)
    finally:
        temporary.unlink()


def schedule(variants, repetitions, warmups, order, seed):
    rng = random.Random(seed)
    out = []
    for warmup, count in ((True, warmups), (False, repetitions)):
        if order == "ordered":
            pairs_ = [(v, r) for v in variants for r in range(count)]
        else:
            pairs_ = []
            for r in range(count):
                labels = list(variants)
                rng.shuffle(labels)
                pairs_.extend((v, r) for v in labels)
        for v, r in pairs_:
            out.append({"index": len(out), "variant": v, "repetition": r, "warmup": warmup})
    return out


def validate_spec(spec):
    keys(spec, {"version", "xodb", "recipe", "variants", "repetitions", "warmups", "order", "seed", "timeout_seconds", "output_bytes"}, {"inputs", "runtime_agent", "allocation_helper"})
    if type(spec["version"]) is not int or spec["version"] != 1 or spec["order"] not in ("ordered", "interleaved"):
        raise ValueError("unsupported experiment version/order")
    for field in ("repetitions", "warmups", "seed", "output_bytes"):
        if type(spec[field]) is not int:
            raise ValueError("experiment limits must be integers")
    integer(spec["repetitions"], 1, 20)
    integer(spec["warmups"], 0, 4)
    integer(spec["seed"], 0, (1 << 64)-1)
    if type(spec["timeout_seconds"]) not in (int, float) or not .05 <= spec["timeout_seconds"] <= 300:
        raise ValueError("timeout outside bounds")
    integer(spec["output_bytes"], RESERVE + 4096, 2 * 1024**3)
    if type(spec["variants"]) is not list or not 2 <= len(spec["variants"]) <= 4:
        raise ValueError("declare 2 to 4 variants")
    if len(encoded(spec)) > 65536:
        raise ValueError("experiment spec byte limit")
    names = set()
    for variant in spec["variants"]:
        keys(variant, {"name", "exe", "args"})
        if not LABEL.fullmatch(string(variant["name"])) or variant["name"] in names:
            raise ValueError("duplicate/invalid variant name")
        names.add(variant["name"])
        string(variant["exe"])
        if type(variant["args"]) is not list or len(variant["args"]) > 128:
            raise ValueError("argument limit")
        for arg in variant["args"]:
            if arg != "":
                string(arg)
    names = set()
    if type(spec.get("inputs", [])) is not list or len(spec.get("inputs", [])) > 32:
        raise ValueError("input count limit")
    for item in spec.get("inputs", []):
        keys(item, {"name", "path"})
        if not LABEL.fullmatch(string(item["name"])) or item["name"] in names:
            raise ValueError("duplicate/invalid input name")
        names.add(item["name"])
        string(item["path"])
    for variant in spec["variants"]:
        for arg in variant["args"]:
            if "{input:" not in arg:
                continue
            match = re.fullmatch(r"\{input:([A-Za-z0-9_-]{1,48})\}", arg)
            if match is None:
                raise ValueError("input placeholders must occupy an entire argument")
            if match[1] not in names:
                raise ValueError(f"undeclared input placeholder: {match[1]}")
    for name in ("xodb", "recipe", "runtime_agent", "allocation_helper"):
        if name in spec:
            string(spec[name])


def children(pid):
    try:
        return [int(p) for p in Path(f"/proc/{pid}/task/{pid}/children").read_text().split()]
    except (FileNotFoundError, ProcessLookupError):
        return []


def kill_child(pid, parent):
    # Pin the PID first, then verify its current parent before signalling.
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if int(fields[1]) == parent:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
    except (FileNotFoundError, ProcessLookupError):
        pass
    finally:
        os.close(fd)


def cleanup(process):
    # This standalone runner has no other children. Becoming a subreaper before
    # launch also catches double-fork/setsid descendants when their parents die.
    if process.poll() is None:
        process.kill()
    deadline = time.monotonic() + 5
    while True:
        process.poll()
        for pid in children(os.getpid()):
            kill_child(pid, os.getpid())
        while True:
            try:
                pid, _status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                pid = 0
            if pid == 0:
                break
        if not children(os.getpid()):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(.01)


def family_start():
    os.setsid()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def invoke(argv, timeout, file_limit):
    def setup():
        family_start()
        resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))
    started = time.monotonic_ns()
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=setup)
    out, err = bytearray(), bytearray()
    selector = selectors.DefaultSelector()
    for pipe, buffer in ((process.stdout, out), (process.stderr, err)):
        os.set_blocking(pipe.fileno(), False)
        selector.register(pipe, selectors.EVENT_READ, buffer)
    reason = None
    try:
        while selector.get_map() or process.poll() is None:
            if CANCEL:
                reason = "cancelled"
                break
            if time.monotonic_ns() - started >= timeout * 1e9:
                reason = "timeout"
                break
            for key, _ in selector.select(.02):
                block = os.read(key.fd, 65536)
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                buffer = key.data
                if len(buffer) + len(block) > MAX_LOG:
                    buffer.extend(block[:MAX_LOG-len(buffer)])
                    reason = "output_budget"
                    break
                buffer.extend(block)
            if reason:
                break
        code = process.poll()
    finally:
        clean = cleanup(process)
        selector.close()
        process.stdout.close()
        process.stderr.close()
    return {"exit_code": code, "status": reason, "wall_ns": time.monotonic_ns()-started, "cleanup_verified": clean}, bytes(out), bytes(err)


def artifact(root, path, maximum):
    data = bounded_read(path, maximum)
    return {"path": str(path.relative_to(root)), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def projection(value):
    keys(value, {"observation", "outcome", "comparison", "comparison_error", "archive"}, {"associations", "association_result"})
    obs = value["observation"]
    selected = {k: obs[k] for k in ("records", "calls", "first_gap", "lost", "rejected", "unread_possible", "finish_reason", "stop_reason", "producer")}
    result = {"observation": selected, "comparison": value["comparison"], "comparison_error": value["comparison_error"]}
    validate_result(result)
    return result


def validate_result(result):
    keys(result, {"observation", "comparison", "comparison_error"})
    obs = result["observation"]
    keys(obs, {"records", "calls", "first_gap", "lost", "rejected", "unread_possible", "finish_reason", "stop_reason", "producer"})
    for k in ("records", "calls", "lost", "rejected"):
        integer(obs[k])
    if type(obs["unread_possible"]) is not bool:
        raise ValueError("invalid coverage flag")
    comp = result["comparison"]
    if comp is None:
        if result["comparison_error"] is None:
            raise ValueError("missing comparison without an error")
        return
    summary = comp["summary"]
    for k in ("total_calls", "complete_calls", "incomplete_calls", "matched_calls", "filtered_calls", "unavailable_filter_calls"):
        integer(summary[k])
    if integer(summary["total_calls"]) != integer(obs["calls"]):
        raise ValueError("contradictory call count")
    integer(comp["selection"]["threshold_ns"])
    for cohort in ("fast", "slow"):
        row = comp[cohort]
        if integer(row["count"]) != integer(row["duration"]["count"]):
            raise ValueError("contradictory duration denominator")
        integer(row["duration"]["total_ns"])
    if sum(integer(comp[c]["count"]) for c in ("fast", "slow")) != integer(summary["complete_calls"]):
        raise ValueError("contradictory complete-call denominator")


def incomplete(result):
    obs, comp = result["observation"], result["comparison"]
    return (result["comparison_error"] is not None or comp is None or obs["first_gap"] is not None or obs["unread_possible"] or integer(obs["lost"]) != 0 or integer(obs["rejected"]) != 0 or integer(comp["summary"]["incomplete_calls"]) != 0)


def directory_bytes(folder):
    # Interrupted archive publication can leave two hardlinks to one inode.
    seen = set()
    total = 0
    for path in folder.iterdir():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("unexpected run artifact type")
        identity = (info.st_dev, info.st_ino)
        if identity not in seen:
            seen.add(identity)
            total += info.st_size
    return total


def run(spec, root):
    validate_spec(spec)
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    pins = []
    root_fd = None
    def pin(path, executable=False, maximum=MAX_INPUT):
        maximum = min(maximum, MAX_INPUT - sum(p.identity["bytes"] for p in pins))
        item = Pin(path, maximum, executable)
        pins.append(item)
        if sum(p.identity["bytes"] for p in pins) > MAX_INPUT:
            raise ValueError("aggregate pinned input budget")
        return item
    try:
        tool = pin(spec["xodb"], True)
        recipe = pin(spec["recipe"], maximum=65536)
        agent = pin(spec["runtime_agent"], True) if spec.get("runtime_agent") else None
        inputs = {item["name"]: pin(item["path"]) for item in spec.get("inputs", [])}
        variants = {}
        for v in spec["variants"]:
            args = []
            for arg in v["args"]:
                if arg.startswith("{input:") and arg.endswith("}"):
                    args.append(inputs[arg[7:-1]].path)
                elif "{input:" in arg:
                    raise ValueError("input placeholders must occupy an entire argument")
                else:
                    args.append(arg)
            variants[v["name"]] = (pin(v["exe"], True), args)
        plan = {"spec": spec, "identities": {"xodb": tool.identity, "recipe": recipe.identity,
                "agent": agent.identity if agent else None, "inputs": {n: p.identity for n, p in inputs.items()},
                "executables": {n: p.identity for n, (p, _) in variants.items()}},
                "schedule": schedule(list(variants), spec["repetitions"], spec["warmups"], spec["order"], spec["seed"]),
                "identity_scope": "sealed explicit ELF/recipe/input bytes; libraries, kernel, helper and ambient environment are not pinned"}
        # Pin and validate every input before claiming a destination. mkdir
        # refuses any existing final component, including dangling symlinks.
        root.mkdir(mode=0o755)
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        root = Path(f"/proc/{os.getpid()}/fd/{root_fd}")
        manifest = {"version": 1, "state": "running", "plan": plan, "runs": []}
        publish(root / "plan.json", plan)
        used = (root / "plan.json").stat().st_size
        halted = None
        for item in plan["schedule"]:
            row = dict(item, status="not_run", error=None, exit_code=None, wall_ns=0, cleanup_verified=True,
                       archive=None, stdout=None, stderr=None, result=None)
            if CANCEL:
                halted = "cancelled"
            remaining = spec["output_bytes"] - used - RESERVE
            if remaining <= 2 * MAX_LOG + 4096:
                halted = halted or "output_budget"
            if halted:
                row["error"] = halted
                manifest["runs"].append(row)
                continue
            folder = root / f"run-{item['index']:03d}"
            folder.mkdir(mode=0o755)
            archive = folder / "capture.xoi"
            exe, args = variants[item["variant"]]
            argv = [tool.path, "--observe-recipe", recipe.path, "--observation-out", str(archive)]
            if agent:
                argv += ["--runtime-agent", agent.path]
            if spec.get("allocation_helper"):
                argv += ["--allocation-helper", spec["allocation_helper"]]
            argv += ["--", exe.path, *args]
            file_limit = min(MAX_ARCHIVE, remaining - 2 * MAX_LOG)
            try:
                info, stdout, stderr = invoke(argv, spec["timeout_seconds"], file_limit)
                row.update(info)
                for name, data in (("stdout", stdout), ("stderr", stderr)):
                    path = folder / (name + ".log")
                    path.write_bytes(data)
                    row[name] = artifact(root, path, MAX_LOG)
                if archive.exists():
                    row["archive"] = artifact(root, archive, MAX_ARCHIVE)
                if row["status"] is None:
                    row["status"] = "failed"
                    if info["exit_code"] == 0 and row["archive"] is not None:
                        value = loads(stdout)
                        row["result"] = projection(value)
                        if len(encoded(row["result"])) > 32768:
                            raise ValueError("per-run result budget")
                        if value["archive"]["sha256"] != row["archive"]["sha256"]:
                            raise ValueError("capture digest disagrees with CLI publication")
                        row["status"] = "incomplete" if incomplete(row["result"]) else "completed"
                    else:
                        row["error"] = "CLI failed or no published archive; see retained logs"
                if not row["cleanup_verified"]:
                    row["status"], row["error"] = "failed", "process family cleanup incomplete"
                    halted = "cleanup_failed"
                if row["status"] in ("cancelled", "output_budget"):
                    halted = row["status"]
            except (OSError, ValueError, KeyError, TypeError) as error:
                row["status"], row["error"] = "failed", str(error)[:1024]
                row["result"] = None
            # Check aggregate output before publishing any successful result.
            # RLIMIT_FSIZE bounds each child file, not their sum.
            run_bytes = directory_bytes(folder)
            if used + run_bytes + len(encoded(row)) + RESERVE > spec["output_bytes"]:
                row["additional_reasons"] = ["output_budget"]
                if row["status"] in ("completed", "incomplete"):
                    row["status"], row["error"], row["result"] = "output_budget", "aggregate run output budget", None
                # Timeout, cancellation and cleanup failure remain the primary
                # outcome. In particular, cancellation must still exit 130.
                halted = halted or "output_budget"
            manifest["runs"].append(row)
            publish(folder / "result.json", row)
            used += run_bytes + (folder / "result.json").stat().st_size
            # Small immutable progress record; no growing repeated manifest copies.
            publish(root / f"checkpoint-{item['index']:03d}.json", {"version": 1, "completed": item["index"]+1, "last_status": row["status"]})
            used += (root / f"checkpoint-{item['index']:03d}.json").stat().st_size
        manifest["state"] = halted or ("completed" if all(r["status"] == "completed" for r in manifest["runs"]) else "completed_with_failures")
        publish(root / "manifest.json", manifest)
        budget_recorded = halted == "output_budget" or any("output_budget" in row.get("additional_reasons", []) for row in manifest["runs"])
        if not budget_recorded and used + (root / "manifest.json").stat().st_size > spec["output_bytes"]:
            raise ValueError("output accounting exceeded budget")
        return manifest
    finally:
        if root_fd is not None:
            os.close(root_fd)
        for item in pins:
            item.close()


def validate_manifest(value):
    keys(value, {"version", "state", "plan", "runs"})
    if type(value["version"]) is not int or value["version"] != 1 or value["state"] not in {"completed", "completed_with_failures", "cancelled", "output_budget", "cleanup_failed"}:
        raise ValueError("unsupported or unfinished manifest")
    plan = value["plan"]
    keys(plan, {"spec", "identities", "schedule", "identity_scope"})
    validate_spec(plan["spec"])
    spec = plan["spec"]
    ids = plan["identities"]
    keys(ids, {"xodb", "recipe", "agent", "inputs", "executables"})
    keys(ids["inputs"], {i["name"] for i in spec.get("inputs", [])})
    keys(ids["executables"], {v["name"] for v in spec["variants"]})
    if (ids["agent"] is None) != ("runtime_agent" not in spec):
        raise ValueError("agent identity missing")
    identities = [ids["xodb"], ids["recipe"], *ids["inputs"].values(), *ids["executables"].values()]
    if ids["agent"] is not None:
        identities.append(ids["agent"])
    for identity in identities:
        keys(identity, {"sha256", "bytes"})
        if type(identity["sha256"]) is not str or not re.fullmatch("[a-f0-9]{64}", identity["sha256"]):
            raise ValueError("invalid input hash")
        integer(identity["bytes"], 0, MAX_INPUT)
    if sum(integer(i["bytes"]) for i in identities) > MAX_INPUT:
        raise ValueError("aggregate input identity budget")
    expected = schedule([v["name"] for v in spec["variants"]], spec["repetitions"], spec["warmups"], spec["order"], spec["seed"])
    if plan["schedule"] != expected or len(value["runs"]) != len(expected):
        raise ValueError("schedule/denominator mismatch")
    for wanted, row in zip(expected, value["runs"]):
        keys(row, set(wanted) | {"status", "error", "exit_code", "wall_ns", "cleanup_verified", "archive", "stdout", "stderr", "result"}, {"additional_reasons"})
        reasons = row.get("additional_reasons", [])
        if type(reasons) is not list or reasons not in ([], ["output_budget"]):
            raise ValueError("invalid additional run reasons")
        if reasons and row["status"] in ("completed", "incomplete", "not_run"):
            raise ValueError("budget overrun cannot claim success or an unstarted run")
        if any(row[k] != v for k, v in wanted.items()) or row["status"] not in STATUSES or type(row["cleanup_verified"]) is not bool:
            raise ValueError("invalid run identity/status")
        if type(row["index"]) is not int or type(row["repetition"]) is not int or type(row["warmup"]) is not bool:
            raise ValueError("invalid schedule field types")
        integer(row["wall_ns"])
        if row["status"] not in ("completed", "incomplete") and row["result"] is not None:
            raise ValueError("failed run cannot claim a successful result")
        if row["status"] in ("completed", "incomplete"):
            if row["archive"] is None or row["result"] is None or row["exit_code"] != 0 or not row["cleanup_verified"]:
                raise ValueError("successful run missing evidence")
            validate_result(row["result"])
            if (row["status"] == "incomplete") != bool(incomplete(row["result"])):
                raise ValueError("coverage status contradiction")
        for name in ("archive", "stdout", "stderr"):
            if row[name] is not None:
                item = row[name]
                keys(item, {"path", "bytes", "sha256"})
                suffix = "capture.xoi" if name == "archive" else name + ".log"
                if item["path"] != f"run-{row['index']:03d}/{suffix}" or not re.fullmatch("[a-f0-9]{64}", item["sha256"]):
                    raise ValueError("invalid artifact identity/path")
                integer(item["bytes"], 0, MAX_ARCHIVE if name == "archive" else MAX_LOG)
    statuses = [row["status"] for row in value["runs"]]
    if (value["state"] == "completed") != all(s == "completed" for s in statuses):
        raise ValueError("manifest completion contradicts run outcomes")
    if value["state"] == "completed_with_failures" and (any(s in ("not_run", "cancelled", "output_budget") for s in statuses) or any(row.get("additional_reasons") for row in value["runs"])):
        raise ValueError("manifest must disclose interruption")
    if value["state"] in ("cancelled", "output_budget", "cleanup_failed"):
        if not any(row["status"] == value["state"] or row["error"] == value["state"] or value["state"] in row.get("additional_reasons", []) or (value["state"] == "cleanup_failed" and not row["cleanup_verified"]) for row in value["runs"]):
            raise ValueError("missing interruption evidence")
    return value


def fraction(value):
    return {"numerator": str(value.numerator), "denominator": str(value.denominator), "display_ns": float(value)}


def summarize(value):
    validate_manifest(value)
    output = {"state": value["state"], "basis": "distribution of per-run inclusive complete-call means; overlapping calls are not CPU cost; no cross-process timestamp alignment or causal claim", "variants": {}}
    selections = [r["result"]["comparison"]["selection"] for r in value["runs"] if r["result"] is not None and r["result"]["comparison"] is not None]
    output["selection"] = selections[0] if selections else None
    output["comparison_compatible"] = all(s == output["selection"] for s in selections)
    output["producer_uncertainty_ns"] = [row["result"]["observation"]["producer"]["uncertainty_ns"] for row in value["runs"] if row["result"] is not None and row["result"]["observation"]["producer"] is not None]
    medians = {}
    for variant in value["plan"]["spec"]["variants"]:
        rows = [r for r in value["runs"] if r["variant"] == variant["name"]]
        measured = [r for r in rows if not r["warmup"]]
        means = []
        counts = []
        for row in measured:
            if row["status"] != "completed":
                continue
            comp = row["result"]["comparison"]
            count = integer(comp["summary"]["complete_calls"])
            if count:
                total = sum(integer(comp[c]["duration"]["total_ns"]) for c in ("fast", "slow"))
                means.append(Fraction(total, count))
                counts.append(count)
        stats = {"planned": len(measured), "warmups": len(rows)-len(measured), "statuses": {s: sum(r["status"] == s for r in measured) for s in sorted(STATUSES)}, "eligible_runs": len(means), "complete_calls_per_eligible_run": counts}
        stats["additional_reasons"] = {"output_budget": sum("output_budget" in row.get("additional_reasons", []) for row in measured)}
        if means:
            median = statistics.median(means)
            medians[variant["name"]] = median
            stats["ns_per_complete_call"] = {"min": fraction(min(means)), "median": fraction(median), "max": fraction(max(means)), "mean": fraction(statistics.mean(means)), "sample_sd_display_ns": statistics.stdev([float(v) for v in means]) if len(means) > 1 else None}
        output["variants"][variant["name"]] = stats
    baseline = value["plan"]["spec"]["variants"][0]["name"]
    output["baseline"] = baseline
    output["median_ratios"] = {}
    for name, median in medians.items():
        if output["comparison_compatible"] and name != baseline and median and baseline in medians and all(output["variants"][n]["eligible_runs"] >= 2 for n in (baseline, name)):
            ratio = medians[baseline] / median
            output["median_ratios"][name] = {"baseline_over_variant": float(ratio), "numerator": str(ratio.numerator), "denominator": str(ratio.denominator), "inference": "descriptive only; inspect failed/incomplete denominators and spread"}
    return output


def verified_summary(root, xodb):
    value = validate_manifest(loads(bounded_read(root / "manifest.json", MAX_JSON)))
    # Only fixed artifact names below the user-selected directory are accessed.
    # Recorded executable/input/helper paths in the plan are never followed.
    for row in value["runs"]:
        folder = root / f"run-{row['index']:03d}"
        if folder.is_symlink():
            raise ValueError("symlink run directory")
        for name in ("archive", "stdout", "stderr"):
            item = row[name]
            if item is None:
                continue
            path = root / item["path"]
            maximum = MAX_ARCHIVE if name == "archive" else MAX_LOG
            if artifact(root, path, maximum) != item:
                raise ValueError("artifact digest mismatch")
            if name == "archive" and row["result"] is not None:
                # Existing CLI replays pairing and comparison; no second implementation.
                before = path.stat()
                info, stdout, _stderr = invoke([xodb, "--open-observation", str(path)], 60, MAX_ARCHIVE)
                after = path.stat()
                if (before.st_ino, before.st_mtime_ns, before.st_ctime_ns) != (after.st_ino, after.st_mtime_ns, after.st_ctime_ns):
                    raise ValueError("archive changed during replay")
                if info["status"] is not None or info["exit_code"] != 0 or not info["cleanup_verified"] or projection(loads(stdout)) != row["result"]:
                    raise ValueError("archive replay contradicts recorded result")
    out = summarize(value)
    out["verification"] = "artifact hashes checked; successful capture results replayed by supplied xodb"
    return out


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("spec", type=Path)
    run_parser.add_argument("--out", required=True, type=Path)
    summary_parser = sub.add_parser("summarize")
    summary_parser.add_argument("directory", type=Path)
    summary_parser.add_argument("--xodb", required=True)
    args = parser.parse_args()
    if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        if args.command == "run":
            value = run(loads(bounded_read(args.spec, MAX_JSON)), Path(os.path.abspath(args.out)))
            print(json.dumps(summarize(value), indent=2))
            return 130 if value["state"] == "cancelled" else 0 if value["state"] == "completed" else 1
        print(json.dumps(verified_summary(args.directory.resolve(), str(Path(args.xodb).resolve())), indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError, RecursionError, subprocess.TimeoutExpired) as error:
        print(f"experiment: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
