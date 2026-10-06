#!/usr/bin/env python3
"""Archive ownership, cancellation and version regressions on owned evidence.

Run the unit suite with XODB_ASSOCIATION_LARGE_FIXTURE set to a fresh path,
then pass that path here. No live collector or privileged process is needed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from client import Client

MAGIC = b'XODBINVOC\x01\r\n'


def wait(client, tool, **args):
    deadline = time.monotonic() + 60
    while True:
        value = client.inspect(tool, **args)
        if value['state'] != 'running':
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.002)


def observation(client):
    deadline = time.monotonic() + 60
    while True:
        value = client.inspect('get_observation')
        if value.get('association_id') is not None:
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.01)


def expect_error(client, tool, error, **args):
    start = time.monotonic()
    value = client.tool(tool, **args)
    elapsed = time.monotonic() - start
    assert value['result']['isError'], value
    assert value['result']['content'][0]['text'] == error, value
    # A denial must not wait for the archive worker to finish.
    assert elapsed < 1, elapsed
    return elapsed


def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser()
    parser.add_argument('--large-fixture', required=True, type=Path)
    parser.add_argument('--parent-bin', type=Path)
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='association-lifecycle-', dir=os.environ.get('XODB_TEST_TMPDIR'))).resolve()
    work.chmod(0o755)
    binary = os.environ.get('XODB_BIN', './zig-out/bin/xodb')
    client = Client('control', None, options=['--open-observation', str(args.large_fixture)])
    try:
        observed = observation(client)
        key = {k: observed['identity'][k] for k in ('session_id', 'capture_id')}
        first_id = observed['association_id']
        original = client.inspect('get_observation_associations', id=first_id)
        assert original['analysis_origin'] == 'restored' and original['payload_version'] == 2
        assert original['rows_truncated'] and original['omitted_rows'] > 0
        assert original['association_algorithm'] == 'xodb-temporal-association-v1'
        saved = client.action('save_observation', **key, path=str(work / 'pinned.xoi'))
        busy_save = expect_error(client, 'associate_observation', 'ObservationArchiveBusy', **key, threshold_ns=11)
        assert client.inspect('get_observation_associations', id=first_id, stream_id=2, limit=1)['source_records']['total'] == 262144
        assert wait(client, 'get_observation_archive', id=saved['id'])['associations_saved']
        second = client.inspect('associate_observation', **key, threshold_ns=12)
        busy_analysis = expect_error(client, 'save_observation', 'ObservationAssociationsBusy', generation=client.session()['generation'], **key, path=str(work / 'refused.xoi'))
        assert not (work / 'refused.xoi').exists()
        assert wait(client, 'get_observation_associations', id=second['id'])['analysis_origin'] == 'reanalysed'
        for paging in ({}, {'stream_id': 2}):
            expect_error(client, 'get_observation_associations', 'StaleObservationAssociations', id=first_id, **paging)
        third = client.inspect('associate_observation', **key, threshold_ns=13)
        client.inspect('cancel_observation_associations', id=third['id'])
        assert wait(client, 'get_observation_associations', id=third['id'])['state'] == 'cancelled'
        cancelled_path = work / 'after-cancel.xoi'
        saved = client.action('save_observation', **key, path=str(cancelled_path))
        final = wait(client, 'get_observation_archive', id=saved['id'])
        assert final['state'] == 'completed' and not final['associations_saved'], final
        assert final['associations_omitted_reason'] == 'ObservationAnalysisCancelled'
        payload = json.loads(cancelled_path.read_bytes()[len(MAGIC) + 32:])
        assert payload['version'] == 1 and 'associations' not in payload['evidence']
        for reader in [binary, *([str(args.parent_bin)] if args.parent_bin else [])]:
            proc = subprocess.run([reader, '--open-observation', str(cancelled_path)], capture_output=True, timeout=30)
            assert proc.returncode == 0, proc.stderr
            assert json.loads(proc.stdout)['observation']['offline']
    finally:
        client.close()
    # The same raw evidence under an unknown algorithm opens without accepting
    # old classifications. Reanalysis is explicit and gets a fresh job ID.
    payload = json.loads(args.large_fixture.read_bytes()[len(MAGIC) + 32:])
    payload['evidence']['associations']['association_algorithm'] = 'historical-association-v0'
    body = json.dumps(payload, separators=(',', ':')).encode()
    unknown = work / 'older-algorithm.xoi'
    unknown.write_bytes(MAGIC + hashlib.sha256(body).digest() + body)
    proc = subprocess.run([binary, '--open-observation', str(unknown)], capture_output=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    cli = json.loads(proc.stdout)
    assert cli['associations']['state'] == 'unsupported_algorithm'
    assert cli.get('association_result') is None
    client = Client('control', None, options=['--open-observation', str(unknown)])
    try:
        observed = observation(client)
        key = {k: observed['identity'][k] for k in ('session_id', 'capture_id')}
        old = client.inspect('get_observation_associations', id=observed['association_id'], stream_id=2, limit=1)
        assert old['state'] == 'unsupported_algorithm' and not old['algorithm_supported']
        assert old['association_algorithm'] == 'historical-association-v0'
        assert old['source_records']['intervals'][0]['ordinal'] == 0
        saved = client.action('save_observation', **key, path=str(work / 'older-resaved.xoi'))
        assert wait(client, 'get_observation_archive', id=saved['id'])['associations_saved']
        second = client.inspect('associate_observation', **key, threshold_ns=10)
        analysed = wait(client, 'get_observation_associations', id=second['id'])
        assert analysed['state'] == 'completed' and analysed['algorithm_supported']
        assert analysed['analysis_origin'] == 'reanalysed' and analysed['counts'] == original['counts']
    finally:
        client.close()
    print(json.dumps({'status': 'pass', 'work': str(work), 'busy_save_seconds': busy_save,
                      'busy_analysis_seconds': busy_analysis, 'parent_reader': bool(args.parent_bin),
                      'cases': ['save pins source', 'running analysis denies save', 'stale IDs',
                                'cancel then save v1', 'unknown algorithm opens', 'explicit reanalysis']}))


if __name__ == '__main__':
    main()
