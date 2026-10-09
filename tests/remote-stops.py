#!/usr/bin/env python3
"""Owned many-mapping target, bounded loader traffic and thread-scoped run-to.

Default uses the C agent locally. --ssh-config/--ssh-host can use an explicitly
supplied owned localhost SSH service with a shared filesystem. No SSH keys or
service configuration are created by this test.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--ssh-config')
parser.add_argument('--ssh-host')
parser.add_argument('--perf', action='store_true', help='record latency reference comparisons as measurements, never speed gates')
parser.add_argument('--work', type=Path, help='fresh output directory (including results.json)')
args = parser.parse_args()
assert bool(args.ssh_config) == bool(args.ssh_host)
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
work = args.work.resolve() if args.work else root / '.work' / ('remote-stops-' + str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
maps = work / 'maps'
maps.mkdir(mode=0o755)
fixture = work / 'fixture'
library = work / 'library.c'
library.write_text('__attribute__((noinline)) void remote_library_hit(void) {}\n')
subprocess.run(['cc', '-g', '-O0', '-shared', '-fPIC', str(library), '-o', str(work / 'library.so')], check=True, timeout=30)
# Distinct inodes make dlopen load all 200 actual ELF images.
for i in range(200):
    shutil.copyfile(work / 'library.so', maps / f'lib-{i:03d}.so')
for name in ('big', 'late'):
    source = work / f'{name}.c'
    source.write_text(f'__attribute__((noinline)) void remote_{name}_hit(void) {{}}\n' +
                      ('const char padding[48*1024*1024] = {1};\n' if name == 'big' else ''))
    subprocess.run(['cc', '-g', '-O0', '-shared', '-fPIC', str(source), '-o', str(maps / f'{name}.so')], check=True, timeout=30)
subprocess.run(['cc', '-g', '-O0', '-fno-pie', '-no-pie', '-pthread',
                'tests/fixtures/remote-stops.c', '-ldl', '-o', str(fixture)], check=True, timeout=30)
options = ['--runtime-agent', str(root / 'zig-out/bin/xodb-agent')]
if args.ssh_host:
    options += ['--runtime-ssh', args.ssh_host, '--ssh-config', args.ssh_config]
server = shared.Server(root, work, Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')),
                       fixture, 'control', options=options, fixture_args=[str(maps)])
results = {}
def resource_sample(pids):
    processes = {}
    for name, pid in pids.items():
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        processes[name] = dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                               rss_kib=int(fields[21]) * os.sysconf('SC_PAGE_SIZE') // 1024)
    return dict(processes=processes, load=os.getloadavg(), allowed_cpus=len(os.sched_getaffinity(0)))

try:
    one, two = shared.Client(server, 'owner'), shared.Client(server, 'observer')
    first = shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'exec stop')
    server.remember_target(first)
    measured_pids = {'frontend': server.proc.pid}
    if not args.ssh_host:
        children = Path(f'/proc/{server.proc.pid}/task/{server.proc.pid}/children').read_text().split()
        assert len(children) == 1, children
        measured_pids['agent'] = int(children[0])
    results['resources_before'] = resource_sample(measured_pids)
    one.tool('claim_session_control')
    ready_symbol = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'remote_ready'}})['result']['structuredContent']
    ready = ready_symbol['address']
    address = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'remote_hit'}})['result']['structuredContent']['address']
    one.action('run_to', tid=first['threads'][0]['tid'], address=ready)
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending') and len(s['threads']) == 2, 'fixture ready')
    # Materializing full unwind/debug data preserves the ID already returned
    # by the lightweight remote symbol lookup.
    frame = one.tool('get_stack', tid=first['pid'])['frames'][0]
    assert frame['module_id'] == ready_symbol['module_id'], (frame, ready_symbol)
    results['module_id_preserved'] = True
    start = time.monotonic()
    probe = one.action('set_breakpoint', symbol='remote_hit')['id']
    one.action('continue')
    state = shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'persistent stop')
    results['first_stop_seconds'] = time.monotonic() - start
    bp = one.tool('get_breakpoints')
    results['breakpoints'] = bp
    assert any(t['tid'] == state['pid'] and t['reason'] == 'breakpoint' and
               t['breakpoint_address'] == int(address, 16) for t in state['threads']), state
    assert bp['loader_status'] == 'glibc loader rendezvous', bp
    assert bp['loader_reads']['bytes'] < 16384, bp
    for _ in range(3):
        one.action('continue')
        shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'repeated persistent stop')
    # Missing symbols must not copy dummy mappings. Identity-keyed negative
    # results are exercised on the executable dummy maps, not just path skips.
    missing = one.action('set_breakpoint', symbol='owned_missing_symbol')['id']
    before = one.tool('get_breakpoints')['symbol_transfer']
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'negative symbol retry')
    after = one.tool('get_breakpoints')['symbol_transfer']
    assert before['bytes'] < 8 * 1024 * 1024 and after['bytes'] < 65536, (before, after)
    assert after['negative_hits'] >= 9, after
    assert after['cached_modules'] >= 200, after
    results['negative_first'], results['negative_retry'] = before, after
    assert after['skipped'] >= 1, after
    # A changed inode version must invalidate a remembered non-ELF signature.
    changed = maps / 'map-001'
    def prefix(value):
        previous = changed.stat()
        with changed.open('r+b') as out: out.write(value)
        os.utime(changed, ns=(previous.st_atime_ns, previous.st_mtime_ns + 1000000000))
    prefix(b'\x7fELF')
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'changed file retry')
    changed_stats = one.tool('get_breakpoints')['symbol_transfer']
    assert changed_stats['bytes'] > after['bytes'], changed_stats
    assert changed_stats['bytes'] < 65536, changed_stats
    assert changed_stats['negative_hits'] == after['negative_hits'] - 1, (changed_stats, after)
    results['changed_identity'] = changed_stats
    prefix(b'\0' * 4)
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'restored non-ELF signature')
    restored_stats = one.tool('get_breakpoints')['symbol_transfer']
    assert restored_stats['bytes'] < 65536 and restored_stats['negative_hits'] >= 8, restored_stats
    results['restored_identity'] = restored_stats
    one.action('remove_breakpoint', id=missing)
    one.action('remove_breakpoint', id=probe)
    # A symbol in a >32 MiB library must resolve without copying its padding.
    large = one.action('set_breakpoint', symbol='remote_big_hit')
    assert not large['pending'], large
    one.action('remove_breakpoint', id=large['id'])
    late = one.action('set_breakpoint', symbol='remote_late_hit')
    assert late['pending'], late
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'), 'late dlopen breakpoint', timeout=30)
    late_state = one.tool('get_breakpoints')
    assert not next(p for p in late_state['breakpoints'] if p['id'] == late['id'])['pending'], late_state
    results['late_dlopen'] = late_state['symbol_transfer']
    one.action('remove_breakpoint', id=late['id'])
    state = one.session()
    worker = next(t['tid'] for t in state['threads'] if t['tid'] != state['pid'])
    counter_address = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'hits'}})['result']['structuredContent']['address']
    byteorder = {1: 'little', 2: 'big'}[fixture.read_bytes()[5]]
    def counter():
        return int.from_bytes(bytes.fromhex(one.tool('read_memory', address=counter_address, length=8)['hex']), byteorder)
    results['hits_before'] = counter()
    start = time.monotonic()
    one.action('run_to', tid=worker, address=address)
    one.tool('release_session_control')
    # Deliberately stale, and then absent: neither may starve a lease claim.
    time.sleep(.02)
    two.tool('claim_session_control', generation=first['generation'])
    two.tool('release_session_control')
    one.tool('claim_session_control')
    final = shared.eventually(one.session, lambda s: s['running_to'] is None and s['state'] == 'stopped', 'bounded wrong-thread run-to', timeout=30)
    results['wrong_thread_seconds'] = time.monotonic() - start
    results['wrong_thread_diagnostic'] = final['step_diagnostic']
    results['hits_after'] = counter()
    # Each foreign trap occurs before remote_hit increments this counter.
    # The final (64th) hit stays stopped, so exactly 63 increments complete.
    assert results['hits_after'] - results['hits_before'] == 63, results
    assert final['step_diagnostic'] == 'RunToNoProgress', final
    assert not [p for p in one.tool('get_breakpoints')['breakpoints'] if not p['internal']]
    shared.expect_error(one.raw('continue', generation=first['generation']), 'StaleSnapshot')
    results['resources_after'] = resource_sample(measured_pids)
    if args.perf:
        overloaded = any(max(results[k]['load']) > results[k]['allowed_cpus']
                         for k in ('resources_before', 'resources_after'))
        results['performance'] = dict(status='not-measurable' if overloaded else 'measured',
            reason='host load exceeds allowed CPU count' if overloaded else None,
            phase='exec stop through completed owned discovery and wrong-thread exercise; fixture CPU excluded',
            remote_agent='excluded for SSH' if args.ssh_host else 'included',
            legacy_latency_references_seconds=dict(first_stop=3, wrong_thread=6),
            within_legacy_latency_references=None if overloaded else dict(
                first_stop=results['first_stop_seconds'] < 3,
                wrong_thread=results['wrong_thread_seconds'] < 6))
    server.stop_and_check()
finally:
    server.close()
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Real ELF discovery, large/late library symbols, negative caching and wrong-thread stop cap passed:', work)
