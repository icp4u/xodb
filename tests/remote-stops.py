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
args = parser.parse_args()
assert bool(args.ssh_config) == bool(args.ssh_host)
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
work = root / '.work' / ('remote-stops-' + str(time.time_ns()))
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
try:
    one, two = shared.Client(server, 'owner'), shared.Client(server, 'observer')
    first = shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'exec stop')
    server.remember_target(first)
    one.tool('claim_session_control')
    ready_symbol = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'remote_ready'}})['result']['structuredContent']
    ready = ready_symbol['address']
    address = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'remote_hit'}})['result']['structuredContent']['address']
    one.action('run_to', tid=first['threads'][0]['tid'], address=ready)
    shared.eventually(one.session, lambda s: s['state'] == 'stopped' and len(s['threads']) == 2, 'fixture ready')
    # Materializing full unwind/debug data preserves the ID already returned
    # by the lightweight remote symbol lookup.
    frame = one.tool('get_stack', tid=first['pid'])['frames'][0]
    assert frame['module_id'] == ready_symbol['module_id'], (frame, ready_symbol)
    results['module_id_preserved'] = True
    start = time.monotonic()
    probe = one.action('set_breakpoint', symbol='remote_hit')['id']
    one.action('continue')
    state = shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'persistent stop')
    results['first_stop_seconds'] = time.monotonic() - start
    bp = one.tool('get_breakpoints')
    results['breakpoints'] = bp
    assert results['first_stop_seconds'] < 3, results
    assert bp['loader_status'] == 'glibc loader rendezvous', bp
    assert bp['loader_reads']['bytes'] < 16384, bp
    for _ in range(3):
        one.action('continue')
        shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'repeated persistent stop')
    # Missing symbols must not copy dummy mappings. Identity-keyed negative
    # results are exercised on the executable dummy maps, not just path skips.
    missing = one.action('set_breakpoint', symbol='owned_missing_symbol')['id']
    before = one.tool('get_breakpoints')['symbol_transfer']
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'negative symbol retry')
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
    shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'changed file retry')
    changed_stats = one.tool('get_breakpoints')['symbol_transfer']
    assert changed_stats['bytes'] > after['bytes'], changed_stats
    assert changed_stats['bytes'] < 65536, changed_stats
    assert changed_stats['negative_hits'] == after['negative_hits'] - 1, (changed_stats, after)
    results['changed_identity'] = changed_stats
    prefix(b'\0' * 4)
    one.action('continue')
    shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'restored non-ELF signature')
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
    shared.eventually(one.session, lambda s: s['state'] == 'stopped', 'late dlopen breakpoint', timeout=30)
    late_state = one.tool('get_breakpoints')
    assert not next(p for p in late_state['breakpoints'] if p['id'] == late['id'])['pending'], late_state
    results['late_dlopen'] = late_state['symbol_transfer']
    one.action('remove_breakpoint', id=late['id'])
    state = one.session()
    worker = next(t['tid'] for t in state['threads'] if t['tid'] != state['pid'])
    start = time.monotonic()
    one.action('run_to', tid=worker, address=address)
    one.tool('release_session_control')
    # Deliberately stale, and then absent: neither may starve a lease claim.
    time.sleep(.02)
    two.tool('claim_session_control', generation=first['generation'])
    two.tool('release_session_control')
    one.tool('claim_session_control')
    final = shared.eventually(one.session, lambda s: s['running_to'] is None and s['state'] == 'stopped', 'bounded wrong-thread run-to', timeout=8)
    results['wrong_thread_seconds'] = time.monotonic() - start
    results['wrong_thread_diagnostic'] = final['step_diagnostic']
    assert final['step_diagnostic'] == 'RunToNoProgress', final
    assert results['wrong_thread_seconds'] < 6, results
    assert not [p for p in one.tool('get_breakpoints')['breakpoints'] if not p['internal']]
    shared.expect_error(one.raw('continue', generation=first['generation']), 'StaleSnapshot')
    server.stop_and_check()
finally:
    server.close()
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Real ELF discovery, large/late library symbols, negative caching and wrong-thread stop cap passed:', work)
