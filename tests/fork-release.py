#!/usr/bin/env python3
"""With following off, a program that forks, vforks or spawns keeps running.

The child inherits a software breakpoint (in its own copy for fork, in the
shared image for vfork). Nobody resolves the birth: the parent must reach a
later breakpoint on its own and the child must exit 0. Lane: fast.
"""
from datetime import datetime
import ctypes, json, os, platform, time
from pathlib import Path
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('fork-release-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
fixture = os.environ.get('XODB_PROCESS_FIXTURE', str(root / 'zig-out/bin/xodb-process-fixture'))
# Released children can outlive their parent. They are re-parented here
# (PR_SET_CHILD_SUBREAPER) and collected at the end, so none outlives the test.
assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
def snap(c): return c.inspect('get_session')
def action(c, name, **args): return c.inspect(name, generation=snap(c)['generation'], **args)
def settled(c, done=('stopped', 'exited')):
    deadline = time.monotonic() + 8
    while True:
        s = snap(c)
        if s['state'] in done: return s
        assert time.monotonic() < deadline, s
        time.sleep(.003)
def to_breakpoint(c):
    """One continue, nothing else: no held birth and no stop for the child's SIGCHLD."""
    action(c, 'continue')
    s = settled(c)
    assert s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']), s
    tree = c.inspect('get_processes')
    parent = tree['processes'][0]
    assert tree['total'] == 1 and parent['pending_count'] == 0 and parent['admission_error'] is None, tree
    return s
for mode in ('fork', 'fork-exec', 'vfork', 'vfork-exec', 'system'):
    c = Client('control', fixture, args=(mode,), options=('--break', 'tree_ready'))
    try:
        to_breakpoint(c)
        assert not c.inspect('get_processes')['processes'][0]['following']
        inherited = action(c, 'set_breakpoint', symbol='tree_child')['id']
        done = action(c, 'set_breakpoint', symbol='tree_done')['id']
        to_breakpoint(c)
        hits = [e['detail'] for e in c.inspect('query_events')['events'] if e['kind'] == 'breakpoint_hit']
        # tree_child ran only in the released child, so this debugger never saw it.
        assert hits[-1] == done and inherited not in hits, hits
        released = [e for e in c.inspect('query_events')['events'] if e['kind'] == 'process_released']
        assert len(released) == 1 and released[0]['tid'] != snap(c)['pid'], released
        # The fixture returns its child's status; a trap death would be 93.
        action(c, 'continue')
        settled(c, ('exited',))
        exits = [e for e in c.inspect('query_events')['events'] if e['kind'] == 'exit']
        assert snap(c)['state'] == 'exited' and exits[-1]['detail'] == 0, exits
    finally:
        c.p.stdin.close()
        c.p.wait(timeout=10)
        stderr = c.p.stderr.read()
        (run / (mode + '.json')).write_text(json.dumps(c.transcript, indent=2))
        (run / (mode + '.stderr')).write_bytes(stderr)
    assert stderr.count(b'released (not following; --follow-forks or F to follow)') == 1, stderr
    assert b'held' not in stderr, stderr
def events(c, kind, after=0):
    found = []
    while True:
        page = c.inspect('query_events', after=after)
        found += [e for e in page['events'] if e['kind'] == kind]
        if not page['has_more']: return found
        after = page['events'][-1]['sequence']
def finish(c, mode, status=0):
    action(c, 'continue')
    settled(c, ('exited',))
    assert events(c, 'exit')[-1]['detail'] == status, events(c, 'exit')
    c.p.stdin.close()
    c.p.wait(timeout=10)
    stderr = c.p.stderr.read()
    (run / (mode + '.json')).write_text(json.dumps(c.transcript, indent=2))
    assert b'held' not in stderr, stderr
# Threads that spawn at the same time: several children borrow the image at
# once. Every one is released, and the traps are back when the last is done.
# A vfork child that starts its own process: that process is not ours either.
for mode, count in (('vfork-threads', 40), ('vfork-grand', 1)):
    c = Client('control', fixture, args=(mode,), options=('--break', 'tree_ready'))
    try:
        to_breakpoint(c)
        inherited = action(c, 'set_breakpoint', symbol='tree_child')['id']
        done = action(c, 'set_breakpoint', symbol='tree_done')['id']
        to_breakpoint(c)
        hits = [e['detail'] for e in events(c, 'breakpoint_hit')]
        assert hits[-1] == done and inherited not in hits, hits
        assert len(events(c, 'process_released')) == count, events(c, 'process_released')
        finish(c, mode)
    finally:
        if c.p.poll() is None: c.close()
# The process exits while its vfork child is still out. The child is not ours
# to kill: it runs on and leaves its note.
note, seen = run / 'orphan.note', run / 'orphan.seen'
c = Client('control', fixture, args=('vfork-orphan', str(note), str(seen)), options=('--break', 'tree_ready'))
try:
    to_breakpoint(c)
    action(c, 'continue')
    settled(c, ('exited',))
    assert events(c, 'exit')[-1]['detail'] == 0, events(c, 'exit')
    # The debugger has handled the exit. The child shares its stderr, so the
    # session is closed only after the child is done.
    seen.write_text('exit seen')
    deadline = time.monotonic() + 8
    while not (note.exists() and note.read_bytes() == b'survived'):
        assert time.monotonic() < deadline, 'the borrowed child did not survive its parent'
        time.sleep(.003)
    c.close()
finally:
    seen.write_text('cleanup')
    if c.p.poll() is None: c.p.kill(); c.p.wait()
# A step over a syscall instruction is a completed step, not a signal stop,
# and the program then runs to its normal end. "step" steps over a raw fork.
if platform.machine() == 'x86_64':
    for mode, symbol in (('syscall', 'tree_syscall_instruction'), ('step', 'tree_fork_instruction')):
        c = Client('control', fixture, args=(mode,), options=('--break', symbol))
        try:
            s = to_breakpoint(c)
            done = action(c, 'set_breakpoint', symbol='tree_done')['id']
            action(c, 'step_instruction', tid=s['threads'][0]['tid'])
            s = settled(c, ('stopped',))
            assert [(t['reason'], t['signal']) for t in s['threads']] == [('single_step', 0)], s
            assert len(events(c, 'process_released')) == (mode == 'step')
            to_breakpoint(c)
            assert events(c, 'breakpoint_hit')[-1]['detail'] == done
            finish(c, mode)
        finally:
            if c.p.poll() is None: c.close()
# Continue off a breakpoint the parent hits on the call right after fork,
# while that child is exiting. SIGCHLD lands in the hidden step. None of those
# is a user stop, and the step still reaches the next breakpoint.
burst_count = int(os.environ.get('XODB_FORK_BURST', '32'))
assert 1 <= burst_count <= 1000
c = Client('control', fixture, args=('fork-burst', str(burst_count)), options=('--break', 'tree_burst_hit'))
try:
    s = to_breakpoint(c)
    done = action(c, 'set_breakpoint', symbol='tree_done')['id']
    hits = 0
    last_hit = events(c, 'breakpoint_hit')[-1]
    for _ in range(burst_count + 1):
        action(c, 'continue')
        s = settled(c, ('stopped', 'exited'))
        assert not any(t['reason'] == 'signal' for t in s.get('threads', ())), s
        if s['state'] == 'exited':
            break
        assert any(t['reason'] == 'breakpoint' for t in s['threads']), s
        hits += 1
        new_hits = events(c, 'breakpoint_hit', last_hit['sequence'])
        assert len(new_hits) == 1, new_hits
        last_hit = new_hits[0]
        if last_hit['detail'] == done:
            break
    # The first burst breakpoint was consumed above; the final hit is tree_done.
    assert hits == burst_count and last_hit['detail'] == done, last_hit
    assert len(events(c, 'process_released')) == burst_count, events(c, 'process_released')
    finish(c, 'fork-burst')
finally:
    if c.p.poll() is None: c.close()
# A genuine admission failure still holds the child.
c = Client('control', fixture, args=('fork',), options=('--follow-forks', '--process-limit', '1', '--break', 'tree_ready'))
try:
    action(c, 'continue'); settled(c, ('stopped',))
    action(c, 'continue')
    deadline = time.monotonic() + 8
    while True:
        tree = c.inspect('get_processes')
        if tree['processes'][0]['admission_error'] == 'ProcessLimit': break
        assert time.monotonic() < deadline, tree
        time.sleep(.003)
    assert tree['total'] == 1 and tree['processes'][0]['pending_count'] == 1, tree
    assert not [e for e in c.inspect('query_events')['events'] if e['kind'] == 'process_released']
    action(c, 'detach_process_family')
    assert snap(c)['state'] == 'idle'
finally:
    c.close()
    (run / 'limit.json').write_text(json.dumps(c.transcript, indent=2))
deadline = time.monotonic() + 8
while True:
    try: pid, _ = os.waitpid(-1, os.WNOHANG)
    except ChildProcessError: break
    assert pid or time.monotonic() < deadline, 'a process started by the fixtures is still running'
    if not pid: time.sleep(.003)
print('fork-release ok')
