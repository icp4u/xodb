#!/usr/bin/env python3
"""Orphans of a debuggee must not stay zombies of xodb during the session.

Following arms a child subreaper and the poll loop reaps untraced zombies.
Without following, those orphans are not xodb's children at all.
"""
import ctypes
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
work = Path(sys.argv[sys.argv.index('--work') + 1]).resolve()
work.mkdir(parents=True, exist_ok=True)

SOURCE = r"""
#include <unistd.h>
#include <sys/wait.h>
int main(void) {
    for (int i = 0; i < 3; i++) {
        pid_t child = fork();
        if (child == 0) {
            if (fork() == 0) {
                usleep(200000);
                _exit(0);
            }
            _exit(0);
        }
        waitpid(child, 0, 0);
    }
    sleep(3);
    return 0;
}
"""
binary = work / 'dfork'
subprocess.run(['gcc', '-O2', '-x', 'c', '-o', str(binary), '-'], input=SOURCE.encode(), check=True, timeout=30)

# Following turned on after an untraced child exists: that child's own
# children are untraced orphans of xodb. Only the in-session reap collects them.
LATE = r"""
#include <unistd.h>
#include <sys/wait.h>
__attribute__((noinline)) void marker(void) { __asm__ volatile("" ::: "memory"); }
int main(void) {
    pid_t child = fork();
    if (child == 0) {
        usleep(500000);
        for (int i = 0; i < 3; i++)
            if (fork() == 0) {
                usleep(200000);
                _exit(0);
            }
        _exit(0);
    }
    marker();
    waitpid(child, 0, 0);
    sleep(3);
    return 0;
}
"""
late_binary = work / 'late'
subprocess.run(['gcc', '-O1', '-g', '-x', 'c', '-o', str(late_binary), '-'], input=LATE.encode(), check=True, timeout=30)

libc = ctypes.CDLL(None, use_errno=True)
libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
libc.prctl.restype = ctypes.c_int
PR_SET_CHILD_SUBREAPER = 36
if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
    raise SystemExit('this test could not become a child subreaper')


def stat_fields(pid):
    try:
        text = Path(f'/proc/{pid}/stat').read_text()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None
    try:
        return text.rsplit(') ', 1)[1].split()
    except IndexError:
        return None


def zombies_of(pid):
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        fields = stat_fields(entry.name)
        if not fields or len(fields) < 2:
            continue
        if fields[0] == 'Z' and int(fields[1]) == pid:
            found.append(int(entry.name))
    return found


def our_children():
    found = []
    me = os.getpid()
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        fields = stat_fields(entry.name)
        if fields and len(fields) >= 2 and int(fields[1]) == me:
            found.append(int(entry.name))
    return found


def drain():
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            pid, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            pid = 0
        if pid:
            continue
        kids = our_children()
        if not kids:
            return
        for kid in kids:
            try:
                os.kill(kid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.02)
    left = our_children()
    if left:
        raise SystemExit(f'orphan children survived the test: {left}')


def owners(client):
    pids = {client.p.pid}
    if client.runtime_agent:
        pids.add(client.collector_pid())
    return pids


def scenario(follow):
    label = 'follow' if follow else 'plain'
    options = ['--follow-forks'] if follow else []
    client = Client('mutate', str(binary), options=options, reply_seconds=20)
    try:
        watched = owners(client)
        start = time.monotonic()
        running_since = None
        zombie_since = None
        deadline = start + 4
        while time.monotonic() < deadline:
            state = client.session()
            if state['state'] == 'exited':
                raise SystemExit(f'{label}: target exited before the orphan check')
            if state['state'] == 'stopped':
                client.continue_initial_stop()
                running_since = None
                continue
            if state['state'] == 'running':
                if running_since is None:
                    running_since = time.monotonic()
            found = []
            for pid in watched:
                found.extend(zombies_of(pid))
            now = time.monotonic()
            if found:
                if zombie_since is None:
                    zombie_since = now
                elif now - zombie_since > 0.4:
                    raise SystemExit(f'{label}: zombies remained under {sorted(watched)}: {found}')
            else:
                zombie_since = None
            if running_since is not None and now - running_since > 0.8 and not found:
                print(f'PASS {label}: no zombies under xodb mid-session', flush=True)
                return
            time.sleep(0.05)
        raise SystemExit(f'{label}: session never stayed running through the orphan window')
    finally:
        client.close()


def scenario_late():
    client = Client('mutate', str(late_binary), reply_seconds=20)
    try:
        watched = owners(client)
        client.stopped(seconds=15)
        client.action('set_breakpoint', symbol='marker')
        client.continue_initial_stop()
        client.stopped('breakpoint', seconds=15)
        client.action('set_process_following', enabled=True)
        client.continue_initial_stop()
        # The grandchildren exit about 0.7 s after this continue.
        start = time.monotonic()
        zombie_since = None
        while time.monotonic() - start < 2.0:
            found = []
            for pid in watched:
                found.extend(zombies_of(pid))
            now = time.monotonic()
            if found:
                if zombie_since is None:
                    zombie_since = now
                elif now - zombie_since > 0.4:
                    raise SystemExit(f'late: untraced orphans remained zombies under {sorted(watched)}: {found}')
            else:
                zombie_since = None
            time.sleep(0.05)
        state = client.session()
        if state['state'] != 'running':
            raise SystemExit(f'late: the target left the orphan window early: {state["state"]}')
        print('PASS late: untraced orphans reaped mid-session after following was enabled', flush=True)
    finally:
        client.close()


try:
    scenario(False)
    scenario(True)
    scenario_late()
finally:
    drain()
print('orphan-reap: pass')
