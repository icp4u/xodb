#!/usr/bin/env python3
"""Read-only Go goroutines at a native stop, checked against the fixture's own
runtime.Stack(buf, true) snapshot (fast lane; component <= ~10 s)."""
import argparse, os, re, signal, subprocess, sys, time
from pathlib import Path
from client import Client
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--go', required=True); p.add_argument('--work', type=Path, required=True)
p.add_argument('--strace', action='store_true')
a = p.parse_args(); root = Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True); w.chmod(0o755)
started = time.monotonic()
env = dict(os.environ, GOCACHE=str(w / 'gocache'), GOPATH=str(w / 'gopath'), GOFLAGS='', GOTOOLCHAIN='local', CGO_ENABLED='0')
exe = w / 'go-demo'
subprocess.run([a.go, 'build', '-o', str(exe), 'go-demo.go'], cwd=root / 'examples', env=env, check=True, timeout=120)
truth_path = w / 'truth.txt'

def check(condition, message):
    if not condition: raise SystemExit('FAIL: ' + str(message))

def parse_truth(text):
    """goroutine id -> (state, [(function, basename, line)], created_by)."""
    out = {}
    for block in text.strip().split('\n\n'):
        lines = block.split('\n')
        m = re.match(r'goroutine (\d+) \[([^\]]+)\]:$', lines[0]); check(m, lines[0])
        frames, creator, i = [], None, 1
        while i + 1 < len(lines):
            call, where = lines[i], lines[i + 1].strip()
            loc = re.match(r'(.*):(\d+)(?: \+0x[0-9a-f]+)?$', where); check(loc, where)
            if call.startswith('created by '):
                creator = (re.sub(r' in goroutine \d+$', '', call[len('created by '):]), os.path.basename(loc[1]), int(loc[2]))
            else:
                frames.append((call[:call.rindex('(')], os.path.basename(loc[1]), int(loc[2])))
            i += 2
        out[int(m[1])] = (m[2], frames, creator)
    return out

def visible(segment):
    return [(f['name'], os.path.basename(f['file'] or ''), f['line']) for f in segment['frames'] if f['go_traceback_visible']]

def compare(stack, truth, current_tid):
    by_id = {s['goroutine']['id']: s for s in stack['segments']}
    user = {i for i, s in by_id.items() if not s['goroutine']['system']}
    check(user == set(truth), f'goroutine ids {sorted(user)} != {sorted(truth)}')
    for gid, (state, frames, creator) in truth.items():
        s = by_id[gid]; g = s['goroutine']
        check(g['state'] == state, f'goroutine {gid} state {g["state"]!r} != {state!r}')
        got = visible(s)
        if g['thread'] == current_tid:
            # Truth was taken before the call; at the stop marker is on top.
            check(s['anchor'] is not None and s['anchor']['frame'] == 0, s['anchor'])
            check([f[0] for f in got[:2]] == ['main.marker', 'main.main'], got[:3])
            check(s['chain_complete'] and s['reason'] is None, (s['state'], s['reason']))
            continue
        check(got[:3] == frames[:3], f'goroutine {gid} frames {got[:3]} != {frames[:3]}')
        check(s['chain_complete'] and s['reason'] is None, (gid, s['state'], s['reason']))
        cb = g['created_by']
        if creator: check(cb and cb['go_traceback_visible'] and (cb['function'], os.path.basename(cb['file'] or ''), cb['line']) == creator, (gid, cb, creator))
        else: check(cb is None or not cb['go_traceback_visible'], (gid, cb))
    check(stack['reason'] is None and not stack['truncated'], (stack['reason'], stack['truncated']))

def audit(client, pid, tid):
    """The read path issues only reads: no writes, resumes or signals."""
    regs = client.inspect('get_registers', tid=tid); generation = client.session()['generation']
    path = w / 'readonly.strace'
    tracer = subprocess.Popen(['strace', '-f', '-qq', '-o', str(path), '-e',
                               'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
                               '-p', str(client.p.pid)], stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not re.search(r'^TracerPid:\s*' + str(tracer.pid) + r'\s*$', Path(f'/proc/{client.p.pid}/status').read_text(), re.M):
            check(tracer.poll() is None and time.monotonic() < deadline, 'strace attach')
            time.sleep(.01)
        client.inspect('get_language_stack', tid=tid, language='go')
    finally:
        if tracer.poll() is None: tracer.send_signal(signal.SIGINT)
        tracer.wait(timeout=10)
    text = path.read_text()
    check(re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA', text), text[:400])
    check(not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b', text), text[:2000])
    check(client.session()['generation'] == generation and client.inspect('get_registers', tid=tid) == regs, 'state changed')

client = Client('control', str(exe), args=[str(truth_path)])
try:
    client.action('set_breakpoint', symbol='main.marker')
    client.continue_initial_stop()
    session = client.stopped('breakpoint', seconds=30)
    tid = next(t['tid'] for t in session['threads'] if t['reason'] == 'breakpoint')
    truth = parse_truth(truth_path.read_text())
    stack = client.inspect('get_language_stack', tid=tid, language='go')
    check(stack['segments'][0]['anchor'] is not None, 'selected thread goroutine first')
    compare(stack, truth, tid)
    # Planted wrong result: a corrupted oracle must fail the same comparison.
    planted = dict(truth); gid = next(g for g in planted if planted[g][1] and planted[g][0] != 'running')
    state, frames, creator = planted[gid]; planted[gid] = (state, [('main.notTheFunction',) + frames[0][1:]] + frames[1:], creator)
    try:
        compare(stack, planted, tid)
    except SystemExit:
        pass
    else:
        raise SystemExit('FAIL: planted wrong frame was accepted')
    # Native Go values at main.marker: scalars, string, slice (len/cap +
    # bounded elements), struct fields and Go containers.
    # Step one source line so stack-passed arguments are past the prologue.
    client.action('step_over', tid=tid)
    stepped = client.stopped(seconds=30)
    frame0 = client.inspect('get_stack', tid=tid)['frames'][0]
    check(frame0['symbol'] == 'main.marker' and frame0['source']['line'] > 37, frame0)
    rows = {l['name']: l for l in client.inspect('list_locals', tid=tid, frame=0)['locals']}
    shown = {name: rows[name]['value']['display'] for name in ('stage', 'label', 'items', 'ratio', 'ok', 'first', 'counts', 'err', 'results')}
    check(shown['stage'] == '30' and shown['ratio'] == '7.5' and shown['ok'] == 'true', shown)
    check(shown['label'] == '"ready" [5 bytes]', shown)
    check(re.fullmatch(r'len 3 cap 3 \[main\.Item\] @ 0x[0-9a-f]+', shown['items']), shown)
    check(rows['p']['value']['kind'] == 'pointer' and rows['p']['value']['bits'] != 0, rows['p'])
    check(shown['counts'] == 'map[string]int len 2' and not rows['counts']['value']['partial'], rows['counts'])
    check(re.fullmatch(r'\*errors\.errorString\(0x[0-9a-f]+\)', shown['err']) and not rows['err']['value']['partial'], rows['err'])
    check(shown['results'] == 'chan int len 0 cap 16 open; queue entries send 0, recv 0, select 0' and not rows['results']['value']['partial'], rows['results'])
    entries = client.inspect('get_value_children', tid=tid, frame=0, expression='counts')['view']
    check({c['name']: c['value']['display'] for c in entries['children']} == {'["alpha" [5 bytes]]': '1', '["beta" [4 bytes]]': '2'}, entries)
    page = client.inspect('get_value_children', tid=tid, frame=0, expression='items', start=0, limit=2)
    page = page['view']
    check(page['total'] == 3 and page['next'] == 2 and [c['name'] for c in page['children']] == ['[0]', '[1]'], page)
    element = client.inspect('get_value_children', tid=tid, frame=0, expression='first')['view']
    fields = {c['name']: c['value']['display'] for c in element['children']}
    check(fields == {'ID': '1', 'Name': '"alpha" [5 bytes]', 'Ready': 'true'}, fields)
    tabs = client.inspect('get_language_tabs')
    go_tab = next(t for t in tabs['view']['tabs'] if t['tab'] == 'go')
    deadline = time.monotonic() + 15
    while go_tab['status'] == 'pending' and time.monotonic() < deadline:
        time.sleep(.02); go_tab = next(t for t in client.inspect('get_language_tabs')['view']['tabs'] if t['tab'] == 'go')
    check(go_tab['status'] == 'ready' and go_tab['version'] == stack['segments'][0]['runtime']['version'], go_tab)
    if a.strace: audit(client, session['pid'], tid)
    print(f"go-language: {len(truth)} goroutines match runtime.Stack (ids, states, top-3 frames); "
          f"version {stack['segments'][0]['runtime']['version']} build {stack['segments'][0]['runtime']['build_id'][:12]}; "
          f"{stack['memory_reads']} reads; {time.monotonic() - started:.1f}s")
finally:
    client.close()
