#!/usr/bin/env python3
"""A second owner of a mapped ELF reuses the held image.

The synchronous remote open still names the file. When that version is already
held, the body is not read again. This covers that open from a stopped frame,
not a prepared image and not a symbol projection.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

MIB = 1 << 20
ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / 'tests/fixtures/file-read-count.py'
SHARE_HOST = r'''
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
__attribute__((noinline)) int entered(int phase) { return phase; }
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen %s: %s\n", argv[1], dlerror()); return 2; }
    int (*wait)(int) = (int (*)(int))dlsym(h, "probe_wait");
    if (!wait) return 3;
    puts("ready");
    fflush(stdout);
    if (wait(1) < 0) return 4;
    pid_t p = fork();
    if (p < 0) return 5;
    if (!p) {
        if (wait(0) < 0) _exit(6);
        _exit(0);
    }
    if (wait(0) < 0) return 7;
    int s = 0;
    waitpid(p, &s, 0);
    return 0;
}
'''
SHARE_LIB = r'''
static volatile int hold = 1;
char blob[8 << 20] = {1};
extern int entered(int);
__attribute__((noinline)) int probe_wait(int phase) {
    int saw = entered(phase);
    if (phase == 0) while (hold) ;
    blob[phase & 7] = (char)saw;
    return 0;
}
'''


def counts(path):
    return json.loads(path.read_text())


def shut(client):
    if client and client.p.poll() is None:
        client.p.stdin.close()
        try:
            client.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            client.p.kill()
            client.p.wait()


def stack_of(client, process_id=None):
    route = {'process_id': process_id} if process_id else {}
    session = client.inspect('get_session', **route)
    return client.inspect('get_stack', generation=session['generation'], tid=session['threads'][0]['tid'], **route)


def region_frame(client, name, process_id=None):
    """The stopped frame whose pc falls in the named mapping."""
    route = {'process_id': process_id} if process_id else {}
    found = stack_of(client, process_id)
    regions = []
    cursor = None
    while True:
        page = client.inspect('list_modules', limit=512, **route, **({'cursor': cursor} if cursor else {}))
        regions += [r for r in page.get('regions') or [] if str(r.get('path', '')).endswith(name)]
        cursor = page.get('next')
        if not cursor:
            break
    for frame in found['frames']:
        pc = frame['lookup_pc']
        if any(r['start'] <= pc < r['end'] for r in regions):
            return found, frame
    return found, None


def resume(client, process_id):
    for attempt in range(2):
        session = client.inspect('get_session', process_id=process_id)
        result = client.tool('continue', process_id=process_id, generation=session['generation'])
        err = result['result']
        if err.get('isError') and err['content'][0]['text'] == 'StaleSnapshot' and attempt == 0:
            continue
        assert not err.get('isError'), result
        return


def stop_in_library(client, process_id, name, seconds):
    """Continue fork and loader stops until a frame is inside `name`."""
    deadline = time.monotonic() + seconds
    found = None
    while time.monotonic() < deadline:
        session = client.inspect('get_session', process_id=process_id)
        assert session['state'] != 'exited', session
        if session['state'] != 'stopped' or session['symbol_discovery_pending'] or session['continue_pending']:
            time.sleep(0.02)
            continue
        found, frame = region_frame(client, name, process_id)
        if frame:
            return found, frame
        if any(item.get('symbol') == 'entered' for item in found['frames']):
            time.sleep(0.02)
            continue
        resume(client, process_id)
    raise AssertionError(found)


def child_process(client):
    tree = client.inspect('get_processes')
    kids = [row for row in tree['processes'] if row['parent_process_id'] == 1 and row['process_id'] != 1]
    return kids[0]['process_id'] if kids else None


def source_at(client, pc, process_id, deadline):
    route = {'process_id': process_id} if process_id else {}
    while True:
        reply = client.tool('get_source_location', address=hex(pc), **route)['result']
        if not (reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending'):
            return reply
        assert time.monotonic() < deadline, reply
        time.sleep(0.02)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work', type=Path, required=True)
    p.add_argument('--runtime-agent', type=Path, required=True)
    args = p.parse_args()
    os.chdir(ROOT)
    os.umask(0o022)
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True, mode=0o755)
    agent = args.runtime_agent.resolve()
    (work / 'share_host.c').write_text(SHARE_HOST)
    (work / 'share_lib.c').write_text(SHARE_LIB)
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-rdynamic', str(work / 'share_host.c'), '-o', str(work / 'share_host'), '-ldl'], check=True, timeout=60)
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-shared', '-fPIC', str(work / 'share_lib.c'), '-o', str(work / 'share.so')], check=True, timeout=120)
    lib = work / 'share.so'
    lib_size = lib.stat().st_size
    total_limit = 14 * MIB
    assert lib_size > total_limit // 2 and lib_size <= 32 * MIB, lib_size
    count_path = work / 'share.json'
    os.environ['XODB_FILE_AGENT'] = str(agent)
    os.environ['XODB_FILE_COUNT'] = str(count_path)
    if count_path.exists():
        count_path.unlink()
    libc = ctypes.CDLL(None, use_errno=True)
    assert libc.prctl(36, 1, 0, 0, 0) == 0, ctypes.get_errno()
    client = Client('control', str(work / 'share_host'), args=[str(lib)],
                    options=['--runtime-agent', str(PROXY), '--follow-forks', '--break', 'entered',
                             '--image-limit', '32M', '--image-total-limit', '14M'],
                    reply_seconds=60)
    try:
        deadline = time.monotonic() + 40
        _, frame = stop_in_library(client, 1, lib.name, 30)
        parent = source_at(client, frame['lookup_pc'], 1, deadline)
        assert not (parent.get('isError') and parent['content'][0]['text'] == 'BinarySnapshotLimit'), parent
        held = client.inspect('list_modules', limit=1, process_id=1)['image_bytes']['held']
        assert total_limit - held < lib_size, (held, lib_size, total_limit)
        before = counts(count_path)['read_bytes']
        resume(client, 1)
        child = None
        while time.monotonic() < deadline:
            child = child_process(client)
            if child:
                break
            time.sleep(0.02)
        assert child, client.inspect('get_processes')
        _, child_frame = stop_in_library(client, child, lib.name, 30)
        reply = source_at(client, child_frame['lookup_pc'], child, deadline)
        assert not (reply.get('isError') and reply['content'][0]['text'] == 'BinarySnapshotLimit'), reply
        after_held = client.inspect('list_modules', limit=1, process_id=child)['image_bytes']['held']
        moved = counts(count_path)['read_bytes'] - before
        assert after_held < held + lib_size // 2, (held, after_held, lib_size)
        assert moved < lib_size // 2, (moved, lib_size)
        result = {'status': 'pass', 'held': held, 'held_after': after_held, 'copied': moved, 'child': child}
        (work / 'results.json').write_text(json.dumps(result) + '\n')
        print('image budget held:', result)
    finally:
        shut(client)
        libc.prctl(36, 0, 0, 0, 0)
        deadline = time.monotonic() + 5
        try:
            while True:
                if os.waitpid(-1, os.WNOHANG) == (0, 0):
                    assert time.monotonic() < deadline, 'a followed process outlived the debugger'
                    time.sleep(0.02)
        except ChildProcessError:
            pass


if __name__ == '__main__':
    main()
