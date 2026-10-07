#!/usr/bin/env python3
"""Actionable startup failures from owned crashing/exiting agent fixtures."""
import argparse
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--ssh-config')
parser.add_argument('--ssh-host')
args = parser.parse_args()
assert bool(args.ssh_config) == bool(args.ssh_host)
work = root / '.work' / ('agent-startup-' + str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
source, crash = work / 'fixture.c', work / 'fixture'
source.write_text('#include <signal.h>\n#include <sys/resource.h>\n'
                  'int main(void) { struct rlimit r = {0,0}; setrlimit(RLIMIT_CORE,&r); '
                  'raise(SIGILL); return 0; }\n')
subprocess.run(['cc', str(source), '-o', str(crash)], check=True, timeout=15)
options = []
if args.ssh_host:
    options = ['--runtime-ssh', args.ssh_host, '--ssh-config', args.ssh_config]
result = subprocess.run([os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp',
                         '--runtime-agent', str(crash), *options, '--', '/bin/true'],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
(work / 'stderr.log').write_text(result.stderr)
assert result.returncode != 0, result
assert 'SIGILL' in result.stderr and 'agent built for a different CPU?' in result.stderr, result.stderr
assert 'exit status' in result.stderr if args.ssh_host else 'signal 4' in result.stderr, result.stderr
print('Agent startup SIGILL diagnostic passed:', work)
