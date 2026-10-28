#!/usr/bin/env python3
"""Opt-in kernel on-CPU stacks. Skips when this host cannot open them."""
from datetime import datetime
from pathlib import Path
import os
import shutil
import subprocess
import time

from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)


def skip(reason):
    print('SKIP kernel stacks: ' + reason)
    raise SystemExit(0)


def read_sysctl(name):
    path = Path('/proc/sys/kernel') / name
    if not path.exists():
        return None
    try:
        return int(path.read_text().strip())
    except ValueError:
        return None


paranoid = read_sysctl('perf_event_paranoid')
if paranoid is None:
    skip('perf_event_paranoid is missing or not an integer')
if paranoid > 1 and os.geteuid() != 0:
    skip(f'perf_event_paranoid is {paranoid}; kernel samples need at most 1')



def kallsyms_visible():
    """Real addresses in kallsyms: root, or kptr_restrict/paranoid low enough."""
    try:
        with open('/proc/kallsyms') as f:
            return any(line.split()[0].strip('0') for line in f if line.strip())
    except OSError:
        return False


visible = kallsyms_visible()
run = root / '.work' / ('kernel-stacks-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
source = run / 'spin.c'
source.write_text(
    '#include <fcntl.h>\n'
    '#include <unistd.h>\n'
    'int main(void) {\n'
    '  int fd = open("/dev/zero", 0);\n'
    '  char buf[4096];\n'
    '  for (;;) if (read(fd, buf, sizeof buf) < 0) return 1;\n'
    '}\n'
)
binary = run / 'spin'
compiler = shutil.which('gcc') or shutil.which('cc')
if compiler is None:
    raise SystemExit('kernel stacks: no C compiler for the read spinner')
built = subprocess.run([compiler, '-O2', '-o', str(binary), str(source)], check=False)
if built.returncode != 0:
    raise SystemExit(f'kernel stacks: could not compile the read spinner with {compiler}')


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


def kernel_names(rows):
    return [node['name'] for node in rows if node['kind'] == 'kernel']


def user_ancestor(rows, node):
    seen = set()
    current = node
    while current is not None and current['id'] not in seen:
        seen.add(current['id'])
        if current['kind'] in ('code', 'unknown', 'unverified', 'incomplete'):
            return True
        parent = current['parent']
        current = next((item for item in rows if item['id'] == parent), None)
    return False


def capture_once(env_extra=None):
    saved = {}
    for key, value in (env_extra or {}).items():
        saved[key] = os.environ.get(key)
        os.environ[key] = value
    client = Client('control', str(binary))
    try:
        stop = client.stopped(seconds=20)
        tid = stop['threads'][0]['tid']
        opened = client.action('start_profile', kernel_stacks=True, duration_ms=3000, frequency_hz=999, tids=[tid])['capture']
        assert opened['accepted']['exclude_kernel'] is False, opened
        assert opened['kernel_stacks_requested'] and opened['kernel_stacks_granted'], opened
        client.action('continue')
        deadline = time.monotonic() + 8
        live = None
        while time.monotonic() < deadline:
            live = client.inspect('get_profile')['capture']
            if live['stored_samples'] > 20:
                break
            time.sleep(0.05)
        assert live['stored_samples'] > 20, live
        stopped = client.action('stop_profile', capture_id=opened['id'])['capture']
        return client, stopped
    except Exception:
        client.close()
        raise
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


client, stopped = capture_once()
try:
    if visible:
        assert stopped['kernel_symbolizable'], stopped
    else:
        assert not stopped['kernel_symbolizable'], stopped
    shown = graph(client, stopped)
    names = kernel_names(shown['nodes'])
    assert names, shown['nodes']
    interesting = ('read', 'syscall', 'entry_SYSCALL')
    hot = [node for node in shown['nodes'] if node['kind'] == 'kernel' and any(part in node['name'] for part in interesting)]
    assert hot, names
    assert any(user_ancestor(shown['nodes'], node) for node in hot), hot
    hidden = graph(client, stopped, hide_kernel=True)
    assert kernel_names(hidden['nodes']) == []
    assert hidden['samples'] == shown['samples']
    assert hidden['filter']['hide_kernel'] is True
finally:
    client.close()

os.environ['XODB_TEST_KERNEL_STACKS'] = 'deny'
client = Client('control', str(binary))
try:
    stop = client.stopped(seconds=20)
    tid = stop['threads'][0]['tid']
    response = client.tool('start_profile', generation=client.session()['generation'], kernel_stacks=True, duration_ms=1000, frequency_hz=99, tids=[tid])
    assert response['result']['isError'], response
    assert response['result']['content'][0]['text'] == 'KernelStacksDenied', response
finally:
    client.close()
    os.environ.pop('XODB_TEST_KERNEL_STACKS', None)

os.environ['XODB_TEST_KPTR_RESTRICT'] = 'hide'
client, stopped = capture_once()
try:
    assert stopped['kernel_stacks_granted'] and not stopped['kernel_symbolizable'], stopped
    shown = graph(client, stopped)
    names = kernel_names(shown['nodes'])
    assert names, shown['nodes']
    assert all(name == '[kernel]' or name.startswith('[kernel] ') for name in names), names
finally:
    client.close()
    os.environ.pop('XODB_TEST_KPTR_RESTRICT', None)
