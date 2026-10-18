#!/usr/bin/env python3
"""Fast GUI: a lost Vulkan surface preserves Wayland scale and UI override.

The second present fails once on a private display. Wait for renderer recreation
and a successful frame, not just a layout published before the failed present.
--expect-backing-scale 1 plants a wrong oracle; it must fail on the 2x output.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time
from unittest.mock import patch

parser = argparse.ArgumentParser()
parser.add_argument('--binary')
parser.add_argument('--expect-backing-scale', type=float, default=2)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('scale-recovery-' + str(time.time_ns())[-8:])
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('scale_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
shim = work / 'vkfault.so'
subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                'tests/vulkan-fault.c', '-ldl', '-lpthread', '-o', str(shim)], check=True)
started = time.monotonic()
with patch.dict(os.environ, LD_PRELOAD=str(shim), XODB_VKFAULT='fail=vkQueuePresentKHR@2:surface_lost'):
    d = h.Display(str(root), ['--ui-scale', '3', *h.M1], output_size=(1600, 1000),
                  output_scale=2, binary=args.binary, wayland_debug=True)
try:
    deadline = time.monotonic() + 10 * h.load_scale()
    while True:
        layout = d.tool('get_layout')
        text = Path(d.log).read_text(errors='replace')
        frames = [int(n) for n in re.findall(r'xodb: remote frame=(\d+)', text)]
        if ('Frame failed:' in text and text.count('Vulkan device:') >= 2 and
                frames and frames[-1] >= 2 and layout['available'] and
                layout['window']['width'] == 1066 and layout['window']['height'] == 666):
            break
        if time.monotonic() >= deadline:
            raise AssertionError(('no frame after renderer recreation', layout, d.tail()))
        time.sleep(.015)
    # Preserve the pre-cleanup wire: destroying the compositor at the same time
    # as the client can itself produce SURFACE_LOST in an in-flight present.
    (work / 'before-close.log').write_text(text)
    (work / 'layout.json').write_text(json.dumps(layout, indent=2))
    assert 'Vulkan result: -1000000000' in text, text[-2000:]
    assert 'vkfault: inject vkQueuePresentKHR call 2 -> -1000000000' in text, text[-2000:]
    assert text.count('Frame failed:') == 1, text[-2000:]
    window = layout['window']
    assert window['backing_scale'] == args.expect_backing_scale, window
    assert window['ui_scale'] == 3 and window['buffer_width'] == 3200 and window['buffer_height'] == 2000, window
    assert d.stopped(), 'renderer recovery must retain the stopped target'
finally:
    # Keep the compositor alive until the client finishes normal cleanup.
    d.app.terminate()
    try:
        d.app.wait(timeout=5 * h.load_scale())
    finally:
        d.close()
text = Path(d.log).read_text(errors='replace')
assert d.app.returncode == 0, text[-2000:]
summaries = [json.loads(line.removeprefix('vkfault: summary ')) for line in text.splitlines()
             if line.startswith('vkfault: summary ')]
assert len(summaries) == 1, text[-2000:]
summary = summaries[0]
assert not summary['leaks'] and not summary['violations'] and not summary['live_at_exit'], summary
assert summary['created'] == summary['destroyed'], summary
print(json.dumps({'status': 'pass', 'seconds': round(time.monotonic() - started, 3), 'work': str(work)}))
