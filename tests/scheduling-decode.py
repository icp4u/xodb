#!/usr/bin/env python3
from datetime import datetime
from pathlib import Path
import os, subprocess
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('scheduling-decode-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
source = (root/'tests/fixtures/scheduling-decode.zig').read_text()
(run/'decode.zig').write_text(source)
(run/'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(run/'tmp'), ZIG_LOCAL_CACHE_DIR=str(run/'cache'), ZIG_GLOBAL_CACHE_DIR=str(root/'.cache/zig-global'))
result = subprocess.run(['zig','test','--dep','records','-Mroot='+str(run/'decode.zig'),'-Mrecords='+str(root/'src/profile/records.zig')], env=env, capture_output=True, text=True)
(run/'result.log').write_text(result.stdout+result.stderr)
print(result.stdout+result.stderr)
print(run)
raise SystemExit(result.returncode)
