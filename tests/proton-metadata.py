#!/usr/bin/env python3
"""Fast bounded metadata checks using explicitly synthetic mapped path evidence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path)
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
exe = w/'fixture'
subprocess.run(['cc', '-g', '-O0', '-DNDEBUG', '-Wall', '-Wextra', '-Werror', 'tests/fixtures/proton-metadata.c', '-o', str(exe)], check=True, timeout=30)
started = time.monotonic()
results = []
for case in (('remote',) if a.agent else ('version', 'missing', 'symlink', 'fifo', 'oversized', 'native')):
    folder = w/case/'Proton Synthetic'
    unix = folder/'files/lib/wine'/('ordinary.so' if case == 'native' else 'ntdll.so')
    pe = folder/('ordinary.dll' if case == 'native' else 'ntdll.dll')
    unix.parent.mkdir(parents=True)
    unix.write_bytes(bytes(4096))
    pe.write_bytes(bytes(4096))
    version = folder/'version'
    if case in ('version', 'remote'):
        version.write_text('proton-owned-build\n')
    elif case == 'symlink':
        outside = w/case/'outside-version'
        outside.write_text('proton-must-not-read\n')
        version.symlink_to(outside)
    elif case == 'fifo':
        os.mkfifo(version, 0o600)
    elif case == 'oversized':
        version.write_text('proton-'+'x'*4096)
    client = Client('control', str(exe), args=[str(unix), str(pe)], options=['--break', 'metadata_ready', *(['--runtime-agent', str(a.agent.resolve())] if a.agent else [])])
    try:
        client.stopped(seconds=15)
        client.continue_initial_stop()
        state = client.stopped('breakpoint', seconds=15)
        expected = 'unavailable' if a.agent else 'not_detected' if case == 'native' else 'wine'
        deadline = time.monotonic() + 10
        while state.get('compatibility', {}).get('kind') != expected:
            assert time.monotonic() < deadline, (case, state)
            state = client.session()
        info = state['compatibility']
        wanted = 'planted-wrong-build' if a.wrong_result else 'proton-owned-build' if case == 'version' else ''
        assert info['proton_build'] == wanted, (case, info, wanted)
        assert info['proton'] == (not a.agent and case != 'native'), (case, info)
        if a.agent or case == 'native':
            assert not state['thread_labels'], state['thread_labels']
        results.append(dict(case=case, status='pass', compatibility=info))
    finally:
        client.close()
report = dict(status='pass', seconds=time.monotonic()-started, cases=results)
(w/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
