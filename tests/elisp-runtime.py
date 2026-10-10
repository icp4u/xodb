#!/usr/bin/env python3
"""C reader against an owned GNU Emacs, with a target-generated backtrace oracle."""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emacs", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    os.umask(0o022)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    root = Path(__file__).resolve().parents[1]
    scratch = args.scratch.resolve()
    scratch.mkdir(mode=0o755, parents=True, exist_ok=False)
    fixture = scratch / "fixtures"
    shutil.copytree(root / "tests/fixtures/elisp", fixture)
    binary = args.emacs.resolve()
    env = dict(os.environ, XDG_CACHE_HOME=str(scratch / "cache"),
               XODB_ELISP_SOURCE=str(fixture / "functions.el"),
               XODB_ELISP_NATIVE=str(fixture / "functions.eln"),
               XODB_ELISP_READER=str(scratch / "reader.so"))
    for key in ("XODB_ELISP_REDEFINE", "XODB_ELISP_WRONG_ORACLE"):
        env.pop(key, None)
    def run(name, command, run_env=env, expect=0):
        with (scratch / (name + ".log")).open("w") as log:
            p = subprocess.run(command, cwd=root, env=run_env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if p.returncode != expect:
            raise RuntimeError(f"{name}: expected exit {expect}, got {p.returncode}; see {scratch / (name + '.log')}")
    run("compile-reader", [args.cc, "-D_GNU_SOURCE", "-std=c11", "-O2", "-DNDEBUG", "-Wall", "-Wextra", "-Werror",
                           "-shared", "-fPIC", "src/language/elisp.c", "src/language/elisp_layout.c",
                           "tests/elisp-layout-probe.c", "-ldw", "-lelf", "-o", str(scratch / "reader.so")])
    run("compile-lisp", [str(binary), "-Q", "--batch", "-l", str(fixture / "compile.el")])
    results = []
    for mode, suffix, redefine in [("interpreted", "el", False), ("bytecode", "elc", False),
                                   ("native", "eln", False), ("bytecode", "elc", True), ("native", "eln", True),
                                   ("interpreted", "el", "bytecode"), ("interpreted", "el", False)]:
        wrong = len(results) == 6
        label = ("wrong-oracle" if wrong else mode) + ("-redefined" if redefine else "")
        e = dict(env, XODB_ELISP_MODE=mode, XODB_ELISP_FUNCTIONS=str(fixture / ("functions." + suffix)),
                 XODB_ELISP_ORACLE=str(scratch / (label + "-oracle.json")),
                 XODB_ELISP_RESULT=str(scratch / (label + "-reader.json")))
        if redefine:
            e["XODB_ELISP_REDEFINE"] = redefine if isinstance(redefine, str) else "1"
        if wrong:
            e["XODB_ELISP_WRONG_ORACLE"] = "1"
        command = ["gdb", "-nx", "-q", "-batch", "-iex", "set auto-load off", "-iex", "set debuginfod enabled off",
                   "-ex", "set may-call-functions off", "-ex", "set disable-randomization off", "-ex", "set startup-with-shell off",
                   "-ex", "break Fdebugger_trap", "-ex", "run", "-ex", "source " + str(root / "tests/elisp-memory.py"),
                   "-ex", "continue", "--args", str(binary), "-Q", "--batch", "-l", str(fixture / "driver.el")]
        run(label, command, e, 1 if wrong else 0)
        if wrong:
            if "full stable stack mismatch" not in (scratch / (label + ".log")).read_text():
                raise RuntimeError("negative oracle failed for an unrelated reason")
            results.append({"case": label, "status": "pass", "planted_wrong_result_rejected": True})
        else:
            results.append(json.loads(Path(e["XODB_ELISP_RESULT"]).read_text()))
    (scratch / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("elisp C reader: 6 live oracle comparisons + planted wrong oracle PASS")


if __name__ == "__main__":
    main()
