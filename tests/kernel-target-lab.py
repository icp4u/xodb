#!/usr/bin/env python3
"""Periodic owned kernel-lab oracle. No host kernel access or root required.

XODB_KERNEL_LAB names the installed lab kit; its built images are read-only.
Every invocation creates and stops its own guest under a private lease.
--gui uses only a private headless compositor; --kcore runs inside the guest.
--gdbstub reads the same guest through QEMU's gdbstub instead of KGDB.
--arm64 uses the arm64 guest (TCG); with --core its QEMU paging dump has no
VMCOREINFO note, so the image is found by its own kimage_voffset.
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from types import SimpleNamespace
from client import Client
from helpers.orphans import adopt, reap

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--gui', action='store_true')
parser.add_argument('--kcore', action='store_true')
parser.add_argument('--core', action='store_true')
parser.add_argument('--gdbstub', action='store_true')
parser.add_argument('--arm64', action='store_true')
args = parser.parse_args()
if args.arm64 and args.kcore:
    parser.error('--arm64 does not combine with --kcore')
boot_seconds = 600 if args.arm64 else 120
setting = os.environ.get('XODB_KERNEL_LAB')
if not setting:
    print('SKIP kernel-target-lab: XODB_KERNEL_LAB is not configured')
    raise SystemExit(77)
lab = Path(setting).resolve()
adopt()  # Keep the daemonized guest ours, including under release-check's reaper.
binary = Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')).resolve()
(root / '.work').mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='input-kt-', dir=root / '.work'))
work.chmod(0o755)
for name in ('out', 'initramfs', 'linux-stable'):
    (work / name).symlink_to(lab / name, target_is_directory=True)
sections = ('tasks', 'cpus', 'modules', 'waits')

def kit(command, *values, timeout=60):
    return subprocess.check_output([str(lab / 'kit' / command), *map(str, values)],
                                   env=dict(os.environ, KL_ROOT=str(work)), text=True, timeout=timeout)

def marker(console, text, seconds=120):
    end = time.monotonic() + seconds
    while text not in console.read_text(errors='replace'):
        assert time.monotonic() < end, ('guest marker timeout', text)
        time.sleep(.05)

def stop_guest(run):
    pid = int((run / 'qemu.pid').read_text())
    def reap_guest():
        try:
            return os.waitpid(pid, os.WNOHANG)[0] == pid
        except ChildProcessError:
            return True
    reap_guest()
    # kl-stop validates UID and the exact run socket before signalling. Reap
    # our guest concurrently: a zombie still has /proc/PID and would otherwise
    # make the kit wait for a process that has already exited.
    stop = subprocess.Popen([str(lab / 'kit/kl-stop'), str(run)], stdout=subprocess.PIPE, text=True)
    try:
        end = time.monotonic() + 30
        while stop.poll() is None:
            reap_guest()
            assert time.monotonic() < end, 'owned guest stop timeout'
            time.sleep(.02)
        output = stop.communicate(timeout=5)[0]
        # The kit may observe an empty command line before QEMU has become
        # waitable. Its stop acknowledgement is not our child-reap completion.
        end = time.monotonic() + 10
        while not reap_guest():
            assert time.monotonic() < end, 'owned guest did not become waitable'
            time.sleep(.02)
        (work / 'stop.log').write_text(output)
        assert stop.returncode == 0, ('owned guest stop failed', stop.returncode)
        # kl-run also leaves its console broker to us; kl-stop ends it.
        assert reap(10), 'owned guest helpers did not exit'
    finally:
        if stop.poll() is None:
            stop.kill()
            stop.wait()

def inventory(inspect):
    answer = {}
    for section in sections:
        page = inspect('get_kernel_target', section=section, limit=128)
        answer[section] = dict(page, rows=list(page['rows']))
        while page['next'] is not None:
            page = inspect('get_kernel_target', section=section, start=page['next'],
                           limit=128, generation=page['generation'])
            answer[section]['rows'].extend(page['rows'])
        assert len(answer[section]['rows']) == page['total']
    verify(answer)
    return answer

def verify(answer):
    assert all(not page['atomic_snapshot'] and not page['truncated'] for page in answer.values()), answer
    tasks = answer['tasks']['rows']
    assert any(t['name'] == 'kg0-blocked' and t['state'] is not None for t in tasks), tasks
    cpus = answer['cpus']['rows']
    assert [c['cpu'] for c in cpus] == [0, 1, 2, 3], cpus
    assert all(c['current_task'].startswith('0x') for c in cpus), cpus
    modules = answer['modules']['rows']
    assert any('kg0_test' in m['name'] and m['status'] == 'loaded' for m in modules), modules
    wait = next(w for w in answer['waits']['rows'] if w['name'] == 'kg0-blocked')
    assert len(wait['hops']) == 2 and wait['end'] == 'complete', wait
    assert [h['owner'] for h in wait['hops']] == ['kg0-holder', 'kg0-spinner'], wait
    assert wait['hops'][-1]['owner_cpu'] is not None, wait

def gui(options):
    spec = importlib.util.spec_from_file_location('kernel_input', root / 'tests/helpers/input.py')
    h = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(h)
    h.WORK = str(work)
    h.Display.reply_seconds = 120
    for name in ('tmp', 'cache', 'cache/mesa', 'cache/nvidia'):
        (work / name).mkdir(parents=True, exist_ok=True)
    for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
        subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
        subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
    h.HELPER = str(work / 'vinput')
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root / 'tests/helpers/vinput.c'),
                    str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'),
                    '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
    spec = importlib.util.spec_from_file_location('kernel_shared', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared.TIMEOUT = 120
    class KernelClient(shared.Client):
        # receive's default was bound when shared-sessions was imported;
        # changing its module TIMEOUT only changes connect/socket timeouts.
        # A live KGDB inventory can require many serial target reads.
        def receive(self, ident, timeout=120):
            return super().receive(ident, timeout=timeout)
    endpoint = SimpleNamespace(path=work / 's', clients=[])
    d = h.Display.__new__(h.Display)
    d.procs = []
    def resources():
        stat = Path('/proc', str(d.app.pid), 'stat').read_text().rsplit(')', 1)[1].split()
        return {'cpu_seconds': (int(stat[11]) + int(stat[12])) / os.sysconf('SC_CLK_TCK'),
                'rss_bytes': int(stat[21]) * os.sysconf('SC_PAGE_SIZE'),
                'monotonic': time.monotonic(), 'load': os.getloadavg()}
    costs = {}
    try:
        d.__init__(str(root), ['--session-socket', str(endpoint.path), '--agent-scope', 'observe', *options],
                   binary=str(binary), stdio=False)
        peer = KernelClient(endpoint, 'kernel-observer')
        d.tool, d.session = peer.tool, peer.session
        answer = inventory(d.tool)
        second = KernelClient(endpoint, 'kernel-second-observer')
        observed = inventory(second.tool)
        assert all(observed[s]['rows'] == answer[s]['rows'] for s in sections)
        before = d.session()
        closed = d.tool('get_layout')
        assert not any(r['pane'].startswith('kernel_') for r in closed['rows']), closed
        costs['closed_before'] = resources()
        for _ in range(30):
            d.tool('get_layout')
        costs['closed_after'] = resources()
        d.keys('tap', 65)  # F7, opt-in only
        for section, code in zip(sections, (2, 3, 4, 5)):
            d.keys('tap', code)
            end = time.monotonic() + 30
            while True:
                layout = d.tool('get_layout')
                rows = [r for r in layout['rows'] if r['pane'] == 'kernel_' + section]
                if rows:
                    break
                assert time.monotonic() < end, layout
                time.sleep(.03)
            assert {c['name'] for c in layout['controls']} == {'Tasks', 'CPUs', 'Modules', 'Waits'}, layout
            assert not layout['text_overlaps'], layout
            if section == 'tasks':
                assert all('state=' in r['value'] and 'CPU=' in r['value'] for r in rows), rows
                expected = answer['tasks']['rows'][0]
                assert rows[0]['label'] == str(expected['pid']) + '  ' + expected['name'], rows[0]
            if section == 'modules':
                assert [r['label'] for r in rows] == [m['name'] for m in answer['modules']['rows'][:len(rows)]], rows
            if section == 'waits':
                assert any('kg0-holder' in r['value'] for r in rows), rows
                assert any('kg0-spinner' in r['value'] for r in rows), rows
            (work / (section + '-layout.json')).write_text(json.dumps(layout, indent=2))
            d.shot(section)
        costs['open_before'] = resources()
        for _ in range(30):
            d.tool('get_layout')
        costs['open_after'] = resources()
        (work / 'cpu-rss.json').write_text(json.dumps(costs, indent=2))
        d.keys('tap', 32)  # 'd' must not detach through the overlay
        assert d.session()['generation'] == before['generation']
        for scope in ('control', 'observe'):
            d.keys('tap', 66)  # F8 stays urgent even while the panel is modal
            end = time.monotonic() + 30
            while d.session()['agent_scope'] != scope:
                assert time.monotonic() < end, ('F8 did not change scope', scope)
                time.sleep(.03)
        d.keys('tap', 1)
        end = time.monotonic() + 30
        while True:
            restored = d.tool('get_layout')
            if not any(r['pane'].startswith('kernel_') for r in restored['rows']):
                break
            assert time.monotonic() < end, restored
        assert [p['name'] for p in restored['panes']] == [p['name'] for p in closed['panes']]
        (work / 'gui-inventory.json').write_text(json.dumps(answer, indent=2))
        subprocess.run(['swaymsg', '-q', '[pid=' + str(d.app.pid) + '] kill'], env=d.env, check=True, timeout=10)
        assert d.app.wait(timeout=30) == 0, d.tail()
    finally:
        for peer in endpoint.clients:
            peer.close()
        d.close()

run = None
with (work / 'lease.lock').open('w') as lease:
    fcntl.flock(lease, fcntl.LOCK_EX)
    try:
        launch = kit('kl-run', *(['arm64', '--accel', 'tcg'] if args.arm64 else ['x86_64']), '--run-id', 'target', '--cpus', '4', '--memory', '1024',
                     *(['--kcore', '--xodb', binary] if args.kcore else []),
                     *(['--gdbstub'] if args.gdbstub else []))
        (work / 'launch.log').write_text(launch)
        fields = dict(line.split('=', 1) for line in launch.splitlines() if '=' in line)
        run = Path(fields['KL_RUN_DIR'])
        console = Path(fields['KL_CONSOLE_LOG'])
        marker(console, 'KG0_KCORE_READY' if args.kcore else 'KG0_INIT_READY', boot_seconds)
        if args.kcore:
            path = root / 'examples/kernel-target.jsonl'
            replies = kit('kl-kcore', run, path, '--timeout', '180', timeout=210)
            (work / 'replies.jsonl').write_text(replies)
            answers = [json.loads(line) for line in replies.splitlines()]
            answer = {section: next(r for r in answers if r.get('id') == i + 2)['result']['structuredContent']
                      for i, section in enumerate(sections)}
            assert all(page['next'] is None for page in answer.values()), answer
            verify(answer)
        else:
            kit('kl-console', run, 'send', 'hang')
            marker(console, 'KG0_HANG_CHAIN_READY hops=2', boot_seconds)
            if args.arm64 and not args.gdbstub and not args.core:
                kit('kl-console', run, 'send', 'kgdb')
            elif not args.gdbstub and not args.arm64:
                kit('kl-console', run, 'nmi-kgdb')
            stub = fields['KL_GDBSTUB'] if args.gdbstub else fields['KL_KGDB']
            options = ['--gdb-remote', stub, '--vmlinux', fields['KL_VMLINUX'], '--modules', fields['KL_MODULES']]
            if args.core:
                dump = work / 'owned.core'
                kit('kl-monitor', run, 'dump-guest-memory', '-p', dump, timeout=300)
                options = ['--core', str(dump), *options[2:]]
            if args.gui:
                gui(options)
            else:
                client = Client('observe', executable=None, options=options, reply_seconds=120)
                try:
                    before = client.session()
                    answer = inventory(client.inspect)
                    (work / 'inventory.json').write_text(json.dumps(answer, indent=2))
                    if args.gdbstub or (args.arm64 and args.core):
                        # QEMU stops (or dumps) the spinning vCPU itself: its CPU thread is the spinner.
                        labels = [t['name'] for t in before['thread_labels']]
                        assert any(n.startswith('kg0-spinner ') and 'spins on CPU 3' in n for n in labels), labels
                        spinner = next(t for t in answer['tasks']['rows'] if t['name'] == 'kg0-spinner')
                        assert spinner['tid'] in [t['tid'] for t in before['threads']], spinner
                    refusal = client.tool('get_kernel_target', generation=before['generation'] + 1)
                    assert refusal['result']['content'][0]['text'] == 'StaleSnapshot', refusal
                    assert client.session()['generation'] == before['generation']
                finally:
                    client.close()
        print('PASS owned kernel target inventory:', 'kcore' if args.kcore else 'vmcore' if args.core else 'gdbstub' if args.gdbstub else 'KGDB', 'arm64' if args.arm64 else 'x86_64', 'GUI' if args.gui else 'MCP')
        print('Evidence:', work.relative_to(root))
    finally:
        if run is not None:
            stop_guest(run)
