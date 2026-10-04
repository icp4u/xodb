#!/usr/bin/env python3
"""Oversized and changing Vulkan enumeration counts on a private compositor."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
os.chdir(root)
binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/xodb').resolve())
spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
display.WORK = tempfile.mkdtemp(prefix='vulkan-enumeration-', dir=root / '.work')
private = display.Display('counts')
try:
    library = Path(private.dir) / 'enumeration.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', 'tests/vulkan-enumeration.c', '-ldl', '-o', str(library)], check=True)
    log = Path(private.dir) / 'xodb.log'
    with log.open('xb') as stream:
        result = subprocess.run([binary, '--frames', '3'], env=dict(private.env, LD_PRELOAD=str(library)), stdout=stream, stderr=stream, timeout=20)
    text = log.read_text()
    assert result.returncode == 0, text
    for expected in ('formats=80 incomplete', 'formats=96 complete', 'images=24', 'first window frame submitted', 'reason=frame_limit'):
        assert expected in text, (expected, text)
    assert 'Renderer initialization failed' not in text, text
    print('PASS changing format count, >64 formats, >16 images, first paint and clean shutdown:', private.dir)
finally:
    private.close()
