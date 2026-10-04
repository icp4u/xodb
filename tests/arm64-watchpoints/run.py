#!/usr/bin/env python3
"""Run only owned watchpoint fixtures in a fresh Jetty ~/Work directory."""
from pathlib import Path
from datetime import datetime
import argparse
import hashlib
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', default='jetty')
args = parser.parse_args()
if args.host.startswith('-'):
    parser.error('host must be an SSH alias or hostname')
root = Path(__file__).resolve().parents[2]
source = (root / 'tests/fixtures/arm64-watchpoints.c').read_bytes()
run = root / '.work' / 'arm64-watchpoints' / datetime.now().strftime('%Y%m%dT%H%M%S%f')
run.mkdir(parents=True)
(run / 'source.sha256').write_text(hashlib.sha256(source).hexdigest() + '  probe.c\n')
remote = r'''import os,sys,subprocess,pathlib,hashlib
from datetime import datetime
if os.uname().machine != 'aarch64': raise RuntimeError('native ARM64 required')
root=pathlib.Path.home()/'Work'/('xodb-arm64-watch-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'))
root.mkdir()
source=sys.stdin.buffer.read()
(root/'probe.c').write_bytes(source)
print('RUN '+str(root),flush=True)
print('SOURCE_SHA256 '+hashlib.sha256(source).hexdigest(),flush=True)
subprocess.check_call(['uname','-srmo'])
subprocess.check_call(['gcc','--version'])
subprocess.check_call(['gcc','-std=c11','-O0','-g','-pthread','-Wall','-Wextra','-Werror','probe.c','-o','probe'],cwd=str(root))
result=subprocess.run(['./probe'],cwd=str(root),timeout=100)
sys.exit(result.returncode)
'''
command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o',
           'StrictHostKeyChecking=yes', '-o', 'ForwardAgent=no', args.host,
           'python3 -c ' + shlex.quote(remote)]
with (run / 'native.log').open('xb') as out:
    result = subprocess.run(command, input=source, stdout=out,
                            stderr=subprocess.STDOUT, timeout=120)
print(run)
print((run / 'native.log').read_text())
raise SystemExit(result.returncode)
