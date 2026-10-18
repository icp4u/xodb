#!/usr/bin/env python3
"""Step over a Go call that grows the stack.

On aarch64, g lives in x28; on x86-64, r14. A return probe that only
remembers the stack pointer runs away when the copy moves that pointer. This
stops on the next line of the caller, with the same g and a readable local.

release-check only runs on x86-64, so there this guards the r14 path; run it
by hand on aarch64 for x28. Other machines print a skip line and exit 0.
--exe runs a binary already built from SOURCE, for a machine with no Go
toolchain.
"""
import argparse, os, subprocess, sys, time
from pathlib import Path

SOURCE = """package main

//go:noinline
func touch(b *[49152]byte) int {
	return int(b[0]) + int(b[len(b)-1])
}

//go:noinline
func grow() int {
	var buf [49152]byte
	buf[0] = 1
	buf[len(buf)-1] = 2
	return touch(&buf)
}

//go:noinline
func caller() int {
	kept := 41
	n := grow()
	kept += n
	return kept
}

func main() {
	println(caller())
}
"""

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--go')
p.add_argument('--exe', type=Path)
p.add_argument('--work', type=Path, required=True)
a = p.parse_args()
REGS = {'aarch64': ('aarch64', 'x28', 'sp'), 'arm64': ('aarch64', 'x28', 'sp'), 'x86_64': ('x86_64', 'r14', 'rsp')}
if os.uname().machine not in REGS:
    print('go-arm64-step: skip, no Go g register on this host')
    raise SystemExit(0)
ARCH, G, SP = REGS[os.uname().machine]
if a.exe is None and not a.go:
    p.error('--go is required unless --exe is set')

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
sys.path.insert(0, str(root / 'tests'))
from client import Client

w = a.work.resolve()
w.mkdir(parents=True, exist_ok=True)
w.chmod(0o755)
lines = SOURCE.splitlines()
call_line = next(i for i, s in enumerate(lines, 1) if 'n := grow()' in s)
after_line = next(i for i, s in enumerate(lines, 1) if 'kept += n' in s)
src = w / 'grow.go'
src.write_text(SOURCE)
src.chmod(0o644)
exe = w / 'grow'
if a.exe is not None:
    exe = a.exe.resolve()
else:
    env = dict(os.environ, GOCACHE=str(w / 'gocache'), GOPATH=str(w / 'gopath'), GOFLAGS='', GOTOOLCHAIN='local', CGO_ENABLED='0')
    subprocess.run([a.go, 'build', '-gcflags=all=-N -l', '-o', str(exe), str(src)], env=env, check=True, timeout=120)

started = time.monotonic()

def fail(message):
    raise SystemExit('FAIL: ' + str(message))

client = Client('control', str(exe), reply_seconds=30)
try:
    client.action('set_breakpoint', symbol='main.caller')
    client.continue_initial_stop()
    session = client.stopped('breakpoint', seconds=30)
    if session['architecture'] != ARCH:
        fail(session['architecture'])
    tid = next(t['tid'] for t in session['threads'] if t['reason'] == 'breakpoint')

    def frame(tid):
        return client.inspect('get_stack', tid=tid)['frames'][0]

    def at_caller(wanted):
        found = []
        for thread in client.session()['threads']:
            if thread['state'] != 'stopped':
                continue
            top = frame(thread['tid'])
            source = top.get('source') or {}
            if top.get('symbol') == 'main.caller' and source.get('line') == wanted:
                found.append(thread['tid'])
        return found

    for _ in range(8):
        if at_caller(call_line):
            break
        client.action('step_over', tid=tid)
        client.stopped(seconds=30)
        landed = at_caller(call_line)
        if landed:
            tid = landed[0]
            break
    else:
        top = frame(tid)
        fail(('not on the call', top.get('symbol'), (top.get('source') or {}).get('line')))
    tid = at_caller(call_line)[0]
    regs = client.inspect('get_registers', tid=tid)['registers']
    if int(regs[G], 16) == 0:
        fail(G + ' was zero on the call')
    saved_g = int(regs[G], 16)
    saved_sp = int(regs[SP], 16)
    client.action('step_over', tid=tid)
    stepped = client.stopped(seconds=30)
    if stepped['source_stepping'] or stepped['step_diagnostic'] is not None:
        fail(stepped['step_diagnostic'])
    hits = at_caller(after_line)
    if len(hits) != 1:
        tops = []
        for thread in stepped['threads']:
            if thread['state'] != 'stopped':
                continue
            top = frame(thread['tid'])
            tops.append((top.get('symbol'), (top.get('source') or {}).get('line'), thread['reason']))
        fail(tops)
    tid = hits[0]
    regs = client.inspect('get_registers', tid=tid)['registers']
    if int(regs[G], 16) != saved_g:
        fail('g changed')
    if int(regs[SP], 16) == saved_sp:
        fail('caller stack pointer did not move')
    rows = {item['name']: item for item in client.inspect('list_locals', tid=tid, frame=0)['locals']}
    if 'kept' not in rows:
        fail(sorted(rows))
    value = rows['kept']['value']
    if value.get('diagnostic') == 'PartialValue' or value.get('partial') or value.get('availability') == 'unavailable':
        fail(value)
    shown = value.get('display')
    bits = value.get('bits')
    if shown != '41' and bits != 41:
        fail(value)
    print(f'go-arm64-step: next line after a stack copy, g held, kept readable ({time.monotonic() - started:.1f}s)')
finally:
    client.close()
