#!/usr/bin/env python3
"""Owned source-fetch/parser fixtures, optionally through a supplied localhost SSH service."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--agent', default='zig-out/bin/xodb-agent')
p.add_argument('--old-agent')
p.add_argument('--ssh-config')
p.add_argument('--ssh-host')
p.add_argument('--cc', default=os.environ.get('CC', 'gcc'))
p.add_argument('--work', type=Path)
a = p.parse_args()
assert bool(a.ssh_config) == bool(a.ssh_host)
work = (a.work or root / '.work' / ('source-fetch-' + str(time.time_ns()))).resolve()
work.mkdir(parents=True, exist_ok=True, mode=0o755)
build = work / 'c'
subprocess.run(['make', '-C', 'src/runtime', '-j1', 'CC=' + a.cc, 'BUILD=' + str(build),
                str(build / 'test-source')], check=True, timeout=120)
parser = build / 'source-paths'
subprocess.run([a.cc, '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                'tests/source-paths.c', 'src/debug/source_paths.c',
                'src/debug/dwarf_cursor.c', 'src/binary/object.c', '-o', str(parser)], check=True, timeout=60)
subprocess.run(['python3', 'tests/source-paths.py', '--check', str(parser), '--work', str(work / 'parser')], check=True, timeout=90)
results = {'parser': 'pass', 'live': 'not_run'}
agent = str(Path(a.agent).resolve())
if a.ssh_host:
    assert not a.ssh_host.startswith('-')
    wrapper = work / 'agent-ssh'
    argv = ['ssh', '-T', '-F', str(Path(a.ssh_config).resolve()), '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'ForwardAgent=no', a.ssh_host,
            'exec ' + shlex.quote(agent) + ' --stdio']
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(argv) + '\n')
    wrapper.chmod(0o755)
    agent = str(wrapper)
if os.environ.get('XODB_TEST_NO_LIVE'):
    results['live'] = 'skip: XODB_TEST_NO_LIVE'
    print('SKIP source transfer live test: XODB_TEST_NO_LIVE')
else:
    subprocess.run([str(build / 'test-source'), agent, str(work / 'parser/gcc-5'),
                    str(work / 'parser/fixture.c')], check=True, timeout=60)
    results['live'] = 'pass'
    confinement = ['python3', 'tests/source-confinement.py', '--agent', agent,
                   '--library', str(build / 'libxrt.a'), '--work', str(work / 'confinement')]
    if a.ssh_host:
        confinement.append('--skip-kernel-filter')
    subprocess.run(confinement, check=True, timeout=90)
    results['source_confinement'] = 'pass'
    subprocess.run(['python3', 'tests/runtime-agent.py', agent], check=True, timeout=60)
    results['legacy_host_handshake'] = 'pass'
    if a.old_agent:
        subprocess.run([str(build / 'test-source'), str(Path(a.old_agent).resolve()), 'old-agent'], check=True, timeout=30)
        results['old_agent_diagnostic'] = 'pass'
(work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Source fetch checks:', results, work)
