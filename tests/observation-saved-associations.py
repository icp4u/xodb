#!/usr/bin/env python3
"""Offline CLI/MCP archive-v2 test using owned fixtures exported by unit tests.

Set XODB_ASSOCIATION_FIXTURE and XODB_ASSOCIATION_REMOTE_FIXTURE to fresh paths
when running the unit suite, then pass both paths here. No live process needed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from client import Client


def wait(client, tool, **args):
    deadline = time.monotonic() + 10
    while True:
        value = client.inspect(tool, **args)
        if value['state'] != 'running': return value
        assert time.monotonic() < deadline, value
        time.sleep(.002)


def main():
    os.umask(0o022)
    p = argparse.ArgumentParser()
    p.add_argument('--native-fixture', required=True, type=Path)
    p.add_argument('--agent-fixture', required=True, type=Path)
    p.add_argument('--work-root', default=os.environ.get('XODB_TEST_TMPDIR'))
    args = p.parse_args()
    work = Path(tempfile.mkdtemp(prefix='saved-associations-', dir=args.work_root)).resolve()
    work.chmod(0o755)
    binary = str(Path(os.environ.get('XODB_BIN', './zig-out/bin/xodb')).resolve())
    os.environ['XODB_BIN'] = binary
    for remote, original in ((False, args.native_fixture), (True, args.agent_fixture)):
        # There are no target/input files at all; even the source archive is gone
        # when the relocated evidence is opened.
        source = work / ('agent-original.xoi' if remote else 'native-original.xoi')
        shutil.copyfile(original, source)
        archive = source.with_name(source.stem+'-relocated.xoi')
        source.rename(archive)
        output = subprocess.run([binary, '--open-observation', str(archive)], capture_output=True, timeout=20)
        assert output.returncode == 0, output.stderr
        cli = json.loads(output.stdout)
        expected = cli['association_result']
        assert cli['observation']['offline'] and cli['associations']['coverage_incomplete']
        assert expected['counts']['records'] == 7
        assert expected['counts']['exactly_one_call'] == (4 if remote else 5)
        assert expected['counts']['crosses_boundary'] == int(remote)
        observer = Client('observe', None, options=['--open-observation', str(archive)])
        try:
            status = observer.inspect('get_observation')
            key = {k: status['identity'][k] for k in ('session_id', 'capture_id')}
            job_id = status['association_id']
            result = observer.inspect('get_observation_associations', id=job_id)
            assert result['counts'] == expected['counts']
            for key_ in ('rows','calls','streams'):
                assert result['result'][key_] == expected[key_], key_
            for stream in (1,2,3):
                page = observer.inspect('get_observation_associations', id=job_id, stream_id=stream, limit=1)
                records = page['source_records']
                assert records['origin']['process_id'] == 3
                assert ('correlated' in records['clock']) == remote
                if remote: assert int(records['clock']['correlated']['uncertainty_ns']) == 2
                if stream == 3: assert records['points'][0]['ordinal'] == 1
            tools = {tool['name']: tool for tool in observer.call('tools/list')['result']['tools']}
            assert tools['associate_observation']['annotations']['xodbSessionAccess'] == 'controller'
            assert tools['get_observation_associations']['annotations']['xodbSessionAccess'] == 'observer'
            # Stdio scope permits analysis of retained evidence; shared sessions
            # separately require the controller lease for replacing the job.
            changed = observer.inspect('associate_observation', **key, threshold_ns=11)
            assert wait(observer, 'get_observation_associations', id=changed['id'])['state'] == 'completed'
        finally: observer.close()
        controller = Client('control', None, options=['--open-observation', str(archive)])
        try:
            status = controller.inspect('get_observation')
            key = {k: status['identity'][k] for k in ('session_id', 'capture_id')}
            old = controller.inspect('get_observation_associations', id=status['association_id'], stream_id=3)['source_records']
            changed = controller.inspect('associate_observation', **key, threshold_ns=11)
            result = wait(controller, 'get_observation_associations', id=changed['id'])
            assert result['state'] == 'completed', result
            assert result['counts']['fast'] == (4 if remote else 5) and result['counts']['slow'] == 0
            assert controller.inspect('get_observation_associations', id=changed['id'], stream_id=3)['source_records'] == old
            stale = controller.tool('associate_observation', **key, threshold_ns=11, profile_id=7, profile_revision=1)
            assert 'error' in stale or stale['result']['isError'], stale
            target = archive.with_name(archive.stem+'-resaved.xoi')
            saved = controller.action('save_observation', **key, path=str(target))
            # Immutable source reads are allowed during save, then same inputs/result replay.
            controller.inspect('get_observation_associations', id=changed['id'], stream_id=3)
            final = wait(controller, 'get_observation_archive', id=saved['id'])
            assert final['state'] == 'completed', final
            first = target.read_bytes()
            denied = controller.action('save_observation', **key, path=str(target))
            final = wait(controller, 'get_observation_archive', id=denied['id'])
            assert final['state'] == 'failed' and target.read_bytes() == first, final
        finally: controller.close()
        again = subprocess.run([binary, '--open-observation', str(target)], capture_output=True, timeout=20)
        assert again.returncode == 0, again.stderr
        assert json.loads(again.stdout)['association_result']['counts'] == result['counts']
        (work / ('agent.json' if remote else 'native.json')).write_text(json.dumps(cli, indent=2))
    print(json.dumps({'status':'pass','work':str(work),'cases':['native provenance','agent uncertainty','CLI replay','MCP citations','unchanged access categories','offline reanalysis','source immutability','resave','no overwrite','assets absent']}))


if __name__ == '__main__': main()
