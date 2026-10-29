#!/usr/bin/env python3
"""Optional periodic live kernel-census oracle in an owned kernel-lab guest.

Set XODB_KERNEL_LAB to the lab root. This uses its kernel and launcher read-only,
and builds a private initramfs whose init is the static census probe. No host
privilege, other guest, KGDB stop or host kernel setting is involved.
"""
import fcntl
import gzip
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
lab_setting = os.environ.get('XODB_KERNEL_LAB')
if not lab_setting:
    print('SKIP kernel-census-lab: XODB_KERNEL_LAB is not configured')
    sys.exit(0)
lab = Path(lab_setting).resolve()
kernel = lab / 'out/x86_64-orc'
if not (kernel / 'arch/x86/boot/bzImage').is_file():
    raise RuntimeError('configured kernel lab has no x86_64 ORC image')
work = Path(tempfile.mkdtemp(prefix='kc-lab-', dir=root / '.work'))
work.chmod(0o755)
(work / 'out').mkdir()
(work / 'out/x86_64-orc').symlink_to(kernel, target_is_directory=True)
(work / 'initramfs').mkdir()
probe = work / 'probe'
subprocess.run(['zig', 'build-exe', '-OReleaseSafe', '-lc', '-target', 'x86_64-linux-musl',
                '--dep', 'census', '-Mroot=tests/kernel-census-probe.zig',
                '-Mcensus=src/model/kernel_census.zig', '-femit-bin=' + str(probe)],
               check=True, timeout=120)
manifest = work / 'initramfs.list'
manifest.write_text('dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\n'
                    'dir /proc 0555 0 0\nfile /init ' + str(probe) + ' 0755 0 0\n')
cpio = subprocess.check_output([str(kernel / 'usr/gen_init_cpio'), str(manifest)], timeout=10)
with gzip.open(work / 'initramfs/x86_64-orc.cpio.gz', 'wb') as stream:
    stream.write(cpio)
run = None
with (work / 'lease.lock').open('w') as lease:
    fcntl.flock(lease, fcntl.LOCK_EX)
    try:
        env = dict(os.environ, KL_ROOT=str(work))
        started = subprocess.check_output([str(lab / 'kit/kl-run'), 'x86_64', '--run-id', 'census',
                                            '--memory', '512', '--cpus', '2'], env=env,
                                           text=True, timeout=20)
        (work / 'launch.log').write_text(started)
        fields = dict(line.split('=', 1) for line in started.splitlines() if '=' in line)
        run = Path(fields['KL_RUN_DIR'])
        console = Path(fields['KL_CONSOLE_LOG'])
        deadline = time.monotonic() + 90
        result = None
        while result is None:
            text = console.read_text(errors='replace') if console.exists() else ''
            for line in text.splitlines():
                if line.startswith('{"tasks":'):
                    result = json.loads(line)
                    break
            if result is not None:
                break
            if time.monotonic() > deadline:
                raise AssertionError('owned guest census did not finish; see private console log')
            time.sleep(.05)
        assert not result['denied'] and not result['unreadable'] and not result['truncated']
        assert result['failure'] is None
        assert all(task['pid'] == 1 for task in result['tasks'])
        assert any(g['status'] == 'ready' and g['count'] >= 2 and 'pipe_read' in g['stack']
                   for g in result['groups'])
        (work / 'result.json').write_text(json.dumps(result, indent=2))
        print('PASS owned kernel-lab guest: symbolized identical blocking-thread stacks, complete scoped census')
        print('Evidence:', work.relative_to(root))
    finally:
        if run is not None:
            subprocess.run([str(lab / 'kit/kl-stop'), str(run)], check=True, timeout=15)
