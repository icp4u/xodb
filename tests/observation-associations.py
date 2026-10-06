#!/usr/bin/env python3
"""Real simultaneous invocation/CPU/syscall/allocation temporal associations."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from client import Client


def wait(client, tool, predicate, **args):
    deadline = time.monotonic() + 20
    while True:
        value = client.inspect(tool, **args)
        if predicate(value):
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.003)


def conserved(counts):
    classes = ('exactly_one_call', 'overlap_multiple', 'outside_calls', 'unusable_time_or_identity', 'crosses_boundary')
    assert counts['records'] == sum(counts[key] for key in classes), counts
    assert counts['fast'] + counts['slow'] == counts['exactly_one_call'], counts


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    work = Path(tempfile.mkdtemp(prefix='xodb-observation-associations-', dir=os.environ.get('XODB_TEST_TMPDIR')))
    work.chmod(0o755)
    source = (root/'tests/fixtures/observations.c').read_text()
    source = source.replace('#include <stdint.h>', '#include <stdint.h>\n#include <stdlib.h>')
    source = source.replace('i < 100;', 'i < 2000000;')
    source = source.replace('    if (slow)', '    for (unsigned i = 0; i < 2000000; ++i) sink = sink * 1664525 + i;\n    if (slow)')
    source = source.replace('    return slow ^ b', '    char *p = malloc(32 + slow); if (p) { p[0] = 1; sink += (unsigned char)p[0]; free(p); }\n    for (unsigned i = 0; i < 2000000; ++i) sink = sink * 1664525 + i;\n    return slow ^ b')
    (work/'fixture.c').write_text(source)
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls',
                    '-Wall', '-Wextra', '-Werror', str(work/'fixture.c'), '-o', str(work/'fixture')], check=True)
    client = Client('control', str(work/'fixture'), options=['--allocation-helper', args.helper] if args.helper else [])
    try:
        ready = client.action('set_breakpoint', symbol='observation_ready')['id']
        client.action('set_breakpoint', symbol='observation_done')
        client.action('continue')
        stopped = client.stopped('breakpoint')
        tid = stopped['pid']
        client.action('remove_breakpoint', id=ready)
        # Complete each asynchronous setup before another generation-changing
        # command; all three collectors then observe the same execution window.
        pending = client.action('start_allocations', tids=[tid], duration_ms=10000, record_limit=32768)
        allocation_id = pending['preparation_id']
        allocations = wait(client, 'get_allocation_capture', lambda v: not v['preparing'])
        assert allocations['collecting'] and allocations['error'] is None, allocations
        profile = client.action('start_profile', tids=[tid], frequency_hz=999, duration_ms=10000, syscall_timing=True)['capture']
        assert profile['status'] == 'collecting', profile
        pc = client.inspect('get_registers', tid=tid)['registers']['rip']
        pending = client.action('start_observation', tids=[tid], mapping_address=pc, functions=['observed_work'], duration_ms=10000)
        key = {k: pending['preparation'][k] for k in ('session_id', 'capture_id')}
        observation = wait(client, 'get_observation', lambda v: v['state'] != 'preparing')
        assert observation['state'] == 'collecting' and observation['error_name'] is None, observation
        client.action('continue')
        client.stopped('breakpoint')
        client.action('stop_observation', **key)
        observation = wait(client, 'get_observation', lambda v: v['state'] == 'completed' and not v['cleanup_pending'])
        client.action('stop_profile', capture_id=profile['id'])
        profile = client.inspect('get_profile')['capture']
        syscall_rows = client.inspect('get_profile_syscalls', capture_id=profile['id'], revision=profile['revision'], limit=128)['rows']
        client.action('stop_allocations', session_id=stopped['session_id'], capture_id=allocation_id)
        allocations = wait(client, 'get_allocation_capture', lambda v: not v['collecting'] and v['state'] not in ('finalized', 'analyzing'))
        assert observation['calls'] == 16 and observation['first_gap'] is None, observation
        arguments = dict(**key, threshold_ns=10_000_000,
                         profile_id=profile['id'], profile_revision=profile['revision'], include_cpu=True, include_syscalls=True,
                         allocation_id=allocation_id, allocation_revision=allocations['key']['revision'])
        job = client.inspect('associate_observation', **arguments)
        result = wait(client, 'get_observation_associations', lambda v: v['state'] != 'running', id=job['id'])
        assert result['state'] == 'completed', result
        conserved(result['counts'])
        streams = {row['kind']: row for row in result['result']['streams']}
        assert set(streams) == {'cpu', 'syscall', 'allocation'}, streams
        for stream in streams.values():
            conserved(stream['counts'])
        assert streams['cpu']['counts']['records'] > 0, streams
        assert streams['syscall']['counts']['exactly_one_call'] >= 8, streams
        assert streams['allocation']['counts']['exactly_one_call'] >= 64, streams
        if not client.runtime_agent:
            assert result['counts']['overlap_multiple'] == 0, result
        else:
            assert result['invocation_producer'] is not None, result
            for stream in streams.values():
                proof = stream['clock']['correlated']
                assert proof['offset_ns'] == 0 and proof['uncertainty_ns'] > 0, proof
        sources = {source['kind']: source for source in result['sources']}
        assert streams['cpu']['counts']['unusable_time_or_identity'] == 0, streams
        assert streams['allocation']['counts']['unusable_time_or_identity'] == 0, streams
        assert streams['syscall']['counts']['unusable_time_or_identity'] == sources['syscall']['incomplete_records'], result
        assert sources['cpu']['included_records'] == profile['stored_samples']
        assert sources['cpu']['lost_records'] == profile['lost_records']
        assert sources['cpu']['lost_samples'] == profile['lost_samples']
        assert result['source_coverage_incomplete'] == bool(sources['syscall']['incomplete_records'])
        assert result['coverage_incomplete'] == result['source_coverage_incomplete']
        assert result['invocation_coverage_incomplete'] is False
        assert sources['allocation']['included_records'] + sources['allocation']['excluded_metadata_records'] == sources['allocation']['stored_records']
        saved = client.inspect('get_observation_associations', id=job['id'], stream_id=1, limit=64)['source_records']
        assert saved['points'], saved
        assert saved['points'][0]['thread_id'] == stopped['threads'][0]['id'], saved
        # Replacing an ended source capture cannot alter the job's copied input.
        replacement = client.action('start_profile', tids=[tid], frequency_hz=99, duration_ms=10000)['capture']
        client.action('stop_profile', capture_id=replacement['id'])
        assert replacement['id'] != profile['id']
        assert client.inspect('get_observation_associations', id=job['id'], stream_id=1, limit=64)['source_records'] == saved
        stale = client.tool('associate_observation', **arguments)
        assert stale['result']['isError'] and stale['result']['content'][0]['text'] == 'StaleProfileView', stale
        assert client.inspect('get_observation_associations', id=job['id'])['counts'] == result['counts']
        # Completed cancellation is harmless and cannot rewrite results.
        assert client.inspect('cancel_observation_associations', id=job['id'])['state'] == 'completed'
        archive = work/'associated.xoi'
        saved_archive = client.action('save_observation', **key, path=str(archive))
        saved_archive = wait(client, 'get_observation_archive', lambda v: v['state'] != 'running', id=saved_archive['id'])
        assert saved_archive['state'] == 'completed', saved_archive
        retained_pages = [client.inspect('get_observation_associations', id=job['id'], stream_id=s, limit=64)['source_records'] for s in (1, 2, 3)]
        summary = {'archive': str(archive), 'runtime_agent': client.runtime_agent, 'counts': result['counts'], 'streams': streams,
                   'sources': result['sources'], 'syscall_reasons': dict(Counter(row['reason'] for row in syscall_rows)), 'checks': 'real three-source joins, exact denominators, raw citations, source replacement, stale revision, no double attribution', 'artifact': str(work)}
        (work/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        (work/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
        print(json.dumps(summary))
    finally:
        (work/'transcript.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        client.close()
    # Saved evidence is sufficient after the owned target and input are deleted.
    (work/'fixture').unlink()
    (work/'fixture.c').unlink()
    offline = Client('observe', None, options=['--open-observation', str(archive)])
    try:
        restored_id = offline.inspect('get_observation')['association_id']
        restored = offline.inspect('get_observation_associations', id=restored_id)
        for field in ('counts', 'sources', 'selection', 'result'):
            assert restored[field] == result[field], field
        for stream, original in enumerate(retained_pages, 1):
            assert offline.inspect('get_observation_associations', id=restored_id, stream_id=stream, limit=64)['source_records'] == original
        print('saved association replay matches after deleting executable and input')
    finally:
        offline.close()


if __name__ == '__main__':
    main()
