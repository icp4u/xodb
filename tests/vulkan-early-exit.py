#!/usr/bin/env python3
"""Fast GUI lane: early Vulkan workers are joined on every normal exit path.

The preload barrier proves the worker is inside instance creation or device
probing before the owner can parse an invalid overview argument. Exits must
join but abandon the unused logical device setup. No sleeps or timing thresholds
decide correctness. The subprocess timeout is only a deadlock ceiling.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time

os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', default='zig-out/bin/xodb')
args = parser.parse_args()
binary = str(Path(args.binary).resolve())
spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
display.WORK = str(root / '.work' / ('vke-' + str(time.time_ns())[-9:]))
d = display.Display('exit')
results = []
started = time.monotonic()
try:
    shim = Path(d.dir) / 'early.so'
    accounting = Path(d.dir) / 'fault.so'
    for source, output in (('tests/vulkan-early-exit.c', shim), ('tests/vulkan-fault.c', accounting)):
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        source, '-ldl', '-pthread', '-o', str(output)], check=True, timeout=30)
    # name, arguments, return code, exact error, worker expected, faults,
    # barrier phase, whether the normal renderer should adopt preparation
    cases = [
        ('overview-bad-panel', ['--overview', '--panel', 'test-invalid-panel'], 1, 'UnknownOverviewPanel', True, '', 'instance', False),
        ('overview-help', ['--overview', '--help'], 0, None, True, '', 'instance', False),
        ('overview-bad-panel-probe', ['--overview', '--panel', 'test-invalid-panel'], 1, 'UnknownOverviewPanel', True, '', 'probe', False),
        ('overview-help-probe', ['--overview', '--help'], 0, None, True, '', 'probe', False),
        ('overview-replay-missing', ['--overview', '--replay', str(Path(d.dir) / 'missing.json')], 1, 'ReplayOpenFailed', True, '', 'instance', False),
        ('debugger-core-missing', ['--core', str(Path(d.dir) / 'missing.core')], 1,
         'CoreFileUnavailable' if platform.machine() == 'x86_64' else 'UnsupportedCoreArchitecture', True, '', 'instance', False),
        ('prepare-instance-failed', ['--overview', '--panel', 'test-invalid-panel'], 1, 'UnknownOverviewPanel', True, 'fail=vkCreateInstance@1x*:oodm', 'instance', False),
        # An abandoned help request must not reach this late phase at all.
        # Preserve the failed-prepare cleanup oracle on adoption, then recover.
        ('prepare-pass-failed', ['--overview', '--frames', '1'], 0, None, True, 'fail=vkCreateRenderPass@1:oodm', 'instance', True),
        ('adopt-debugger', ['--frames', '1'], 0, None, True, '', 'instance', True),
        ('adopt-overview', ['--overview', '--frames', '1'], 0, None, True, '', 'probe', True),
        # The separate headless parser rejects the GUI-only option itself.
        ('headless-bad-panel', ['--overview', '--headless', '--panel', 'test-invalid-panel'], 1, 'OverviewOptionConflict', False, '', 'instance', False),
        ('debugger-help', ['--help'], 0, None, False, '', 'instance', False),
        ('debugger-bad-arg', ['--test-invalid-option'], 1, 'UnknownArgument', False, '', 'instance', False),
        # --version is not a supported option; it must fail before spawning.
        ('debugger-version', ['--version'], 1, 'UnknownArgument', False, '', 'instance', False),
    ]
    for name, argv, code, error, worker, faults, phase, adopt in cases:
        env = dict(d.env, LD_PRELOAD=f'{shim}:{accounting}', XODB_TEST_EARLY_EXIT='1',
                   XODB_TEST_EARLY_PHASE=phase, XODB_VKFAULT=faults)
        before = time.monotonic()
        proc = subprocess.run([binary, *argv], env=env, capture_output=True, timeout=30)
        text = (proc.stdout + proc.stderr).decode(errors='replace')
        (Path(d.dir) / f'{name}.log').write_text(text)
        rows = re.findall(r'^vkearly: (.*)$', text, re.M)
        early = json.loads(rows[0]) if len(rows) == 1 else None
        rows = re.findall(r'^vkfault: summary (.*)$', text, re.M)
        counts = json.loads(rows[0]) if len(rows) == 1 else None
        result = dict(name=name, seconds=time.monotonic()-before, returncode=proc.returncode,
                      worker=early, phase=phase, adopt=adopt, accounting=counts)
        results.append(result)
        print(json.dumps(result), flush=True)
        assert proc.returncode == code, (name, code, proc.returncode, text)
        assert early == dict.fromkeys(('claimed', 'entered', 'finished', 'joined'), int(worker)), (name, early)
        assert not re.search(r'Segmentation fault|panic|reached unreachable', text), (name, text)
        if error:
            assert f'error: {error}' in text.splitlines(), (name, text)
        assert counts is not None, (name, 'missing lifetime summary', text)
        assert counts['live_at_exit'] == counts['leaks'] == counts['violations'] == counts['dirty_retirements'] == 0, (name, counts)
        assert counts['created'] == counts['destroyed'], (name, counts)
        allocation = counts['allocations']
        assert allocation['live_bytes'] == allocation['leaked_bytes'] == 0, (name, allocation)
        assert allocation['allocated_bytes'] == allocation['freed_bytes'], (name, allocation)
        if worker and not faults:
            assert counts['created']['instance'] > 0, (name, counts)
        if worker:
            if adopt:
                assert counts['created']['device'] > 0, (name, counts)
            else:
                assert counts['created']['device'] == 0, (name, 'unused device setup was not abandoned', counts)
        if faults:
            function = faults.split('=')[1].split('@')[0]
            assert counts['calls'][function][1] > 0, (name, 'fault was not reached', counts)
        if not worker:
            assert not any(counts['created'].values()), (name, counts)
finally:
    (Path(d.dir) / 'results.json').write_text(json.dumps(dict(seconds=time.monotonic()-started, cases=results), indent=2)+'\n')
    d.close()
    print(d.dir, flush=True)
