#!/usr/bin/env python3
"""Opt-in off-CPU blocked stacks. A typed refusal is a pass, not a skip."""
from datetime import datetime
from pathlib import Path
import os
import shutil
import subprocess
import time

from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)


def graph(client, capture, **filters):
    rows, start, view_id = [], 0, None
    while True:
        args = dict(capture_id=capture['id'], revision=capture['revision'], start=start, limit=64)
        if view_id:
            args['view_id'] = view_id
        args.update(filters)
        data = client.inspect('get_flamegraph', **args)
        view_id = data['view_id']
        rows += data['nodes']
        if data['next'] is None:
            break
        start = data['next']
    return dict(data, nodes=rows)


def assert_denied(response):
    assert response['result']['isError'], response
    assert response['result']['content'][0]['text'] == 'OffCpuDenied', response


run = root / '.work' / ('off-cpu-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
source = run / 'block.c'
source.write_text(
    '#include <pthread.h>\n'
    '#include <stdatomic.h>\n'
    '#include <stdio.h>\n'
    '#include <time.h>\n'
    '#include <unistd.h>\n'
    '/* Main blocks in read() until a writer thread writes 300 ms after the read is armed, then spins 200 ms. */\n'
    'static int fds[2];\n'
    'static atomic_int armed;\n'
    'static unsigned long long now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }\n'
    'static void *writer(void *arg) {\n'
    '  (void)arg;\n'
    '  for (;;) {\n'
    '    while (!atomic_exchange(&armed, 0)) usleep(1000);\n'
    '    usleep(300000);\n'
    '    if (write(fds[1], "x", 1) != 1) _exit(4);\n'
    '  }\n'
    '}\n'
    '__attribute__((noinline)) void block_on_pipe(void) {\n'
    '  char byte;\n'
    '  atomic_store(&armed, 1);\n'
    '  if (read(fds[0], &byte, 1) != 1) _exit(3);\n'
    '}\n'
    '__attribute__((noinline)) void spin(void) { unsigned long long end = now() + 200000000ull; while (now() < end) ; }\n'
    'int main(int argc, char **argv) {\n'
    '  FILE *log = argc > 1 ? fopen(argv[1], "w") : 0;\n'
    '  pthread_t thread;\n'
    '  if (!log || pipe(fds) != 0 || pthread_create(&thread, 0, writer, 0) != 0) _exit(2);\n'
    '  setvbuf(log, 0, _IONBF, 0);\n'
    '  for (;;) {\n'
    '    fprintf(log, "S %llu\\n", now());\n'
    '    block_on_pipe();\n'
    '    fprintf(log, "E %llu\\n", now());\n'
    '    spin();\n'
    '  }\n'
    '}\n'
)
binary = run / 'block'
compiler = shutil.which('gcc') or shutil.which('cc')
if compiler is None:
    raise SystemExit('off-CPU: no C compiler for the blocking fixture')
built = subprocess.run(
    [compiler, '-O2', '-fno-omit-frame-pointer', '-pthread', '-o', str(binary), str(source)],
    check=False,
)
if built.returncode != 0:
    raise SystemExit('off-CPU: could not compile the blocking fixture')

log = run / 'blocks.log'
client = Client('control', str(binary), args=[str(log)])
try:
    client.stopped(seconds=20)
    # Let the writer thread exist first, then capture every thread.
    client.action('continue')
    time.sleep(0.5)
    client.action('interrupt')
    client.stopped(seconds=20)
    response = client.tool(
        'start_profile',
        generation=client.session()['generation'],
        off_cpu=True,
        duration_ms=2500,
        frequency_hz=99,
    )
    if response['result']['isError'] and client.runtime_agent:
        # A runtime agent is a remote target; its tracefs is not opened from here.
        assert response['result']['content'][0]['text'] == 'OffCpuRemoteUnsupported', response
        print('off-CPU through a runtime agent is refused by name')
        client.close()
        raise SystemExit(0)
    if response['result']['isError']:
        assert_denied(response)
        print('SKIP off-CPU live: open refused by name (needs root, or perf_event_paranoid -1 and a readable tracefs); denial checked')
    else:
        opened = response['result']['structuredContent']['capture']
        assert opened['off_cpu']['requested'] and opened['off_cpu']['granted'], opened
        # CLOCK_MONOTONIC; the debugger stop before this is not pipe time.
        resumed_ns = time.monotonic_ns()
        client.action('continue')
        deadline = time.monotonic() + 8
        live = None
        while time.monotonic() < deadline:
            live = client.inspect('get_profile')['capture']
            if live['status'] != 'collecting':
                break
            time.sleep(0.05)
        if live is None or live['status'] == 'collecting':
            stopped = client.action('stop_profile', capture_id=opened['id'])['capture']
        else:
            stopped = live
        blocked = graph(client, stopped, basis='blocked_ns')
        assert blocked['units'] == 'blocked_ns', blocked
        assert blocked['label'] == 'Blocked time', blocked
        assert blocked['nodes'][0]['name'] == 'Blocked time', blocked['nodes'][0]
        assert blocked['blocked_ns'] > 200_000_000, blocked
        off = stopped['off_cpu']
        assert off['intervals'] > off['truncated'], off
        # Blocked time on the pipe path matches the fixture's own clock. Without
        # switch-ins, the 200 ms spin after each read would count as blocked.
        by_id = {node['id']: node for node in blocked['nodes']}
        # The pipe wait, by its user frame or its kernel frame, counted once
        # per path. A frame-pointer walk can lose block_on_pipe under libc read.
        marks = ('block_on_pipe', 'pipe_read', 'anon_pipe_read')

        def marked_above(node):
            parent = by_id.get(node['parent'])
            while parent is not None:
                if parent['name'] in marks:
                    return True
                parent = by_id.get(parent['parent'])
            return False
        on_path = sum(node['inclusive'] for node in blocked['nodes'] if node['name'] in marks and not marked_above(node))
        truth, start_at = 0, None
        for line in log.read_text().split('\n'):
            if not line.strip():
                continue
            kind, value = line.split()
            if kind == 'S':
                start_at = int(value)
                continue
            truth += max(0, min(int(value), stopped['ended_ns']) - max(start_at, stopped['started_ns'], resumed_ns))
            start_at = None
        if start_at is not None:
            truth += max(0, stopped['ended_ns'] - max(start_at, stopped['started_ns'], resumed_ns))
        assert truth > 600_000_000 and 0.9 <= on_path / truth <= 1.1, (on_path, truth, off)
        assert any('block_on_pipe' in node['name'] or node['name'] == 'read' or node['name'].endswith('read') for node in blocked['nodes']), [node['name'] for node in blocked['nodes']]
        hidden = graph(client, stopped, basis='blocked_ns', hide_kernel=True)
        assert hidden['blocked_ns'] == blocked['blocked_ns'], (hidden['blocked_ns'], blocked['blocked_ns'])
        assert all(node['kind'] != 'kernel' for node in hidden['nodes'])
        samples = graph(client, stopped)
        assert samples['units'] == 'samples', samples
        assert samples['nodes'][0]['name'] == 'All samples'
        assert samples['samples'] * 1000 < blocked['blocked_ns'], (samples['samples'], blocked['blocked_ns'])
        print('off-CPU blocked flame matches the pipe read (%.0f ms of %.0f ms) and stays off the sample tree' % (on_path / 1e6, truth / 1e6))
finally:
    client.close()

os.environ['XODB_TEST_OFF_CPU'] = 'deny'
client = Client('control', str(binary), args=[str(run / 'denied.log')])
try:
    stop = client.stopped(seconds=20)
    tid = stop['threads'][0]['tid']
    response = client.tool(
        'start_profile',
        generation=client.session()['generation'],
        off_cpu=True,
        duration_ms=1000,
        frequency_hz=99,
        tids=[tid],
    )
    assert_denied(response)
    assert client.inspect('get_profile')['capture'] is None
finally:
    client.close()
    os.environ.pop('XODB_TEST_OFF_CPU', None)

print('off-CPU denial keeps the typed name')
