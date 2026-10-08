#!/usr/bin/env python3
"""Deterministic slow-sensor policy regression; no sleeps or host sensors."""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
with tempfile.TemporaryDirectory(prefix='xodb-sensors-', dir=os.environ.get('TMPDIR')) as tmp:
    work = Path(tmp); work.chmod(0o755)
    binary = work / 'test'
    subprocess.run(['cc', '-O2', '-g', '-std=c11', '-UNDEBUG', '-Wall', '-Wextra', '-Werror',
                    '-Isrc/runtime', 'tests/runtime-sysstat-sensors.c', 'src/runtime/sysstat.c',
                    'src/runtime/sysstat_nvml.c', '-Wl,--wrap=clock_gettime', '-Wl,--wrap=read',
                    '-pthread', '-ldl', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], env=dict(os.environ, TMPDIR=str(work)), check=True, timeout=10)
