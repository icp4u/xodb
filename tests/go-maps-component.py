#!/usr/bin/env python3
"""Fast C map-reader checks, NDEBUG negative control and sanitizer run."""
import argparse
import os
from pathlib import Path
import resource
import subprocess
import time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w=a.work.resolve(); w.mkdir(parents=True,exist_ok=True); w.chmod(0o755)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
start=time.monotonic()
for compiler,flags in ((os.environ.get('CC','cc'),['-O2']),('clang',['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'])):
    exe=w/('check-san' if compiler=='clang' else 'check')
    subprocess.run([compiler,'-std=c11','-g','-DNDEBUG','-DXGM_TEST_MAIN','-Wall','-Wextra','-Werror',*flags,'src/language/go_value.c','src/language/go_map.c','tests/go-maps.c','-o',str(exe)],check=True,timeout=30)
    subprocess.run([str(exe)],check=True,timeout=5,env=dict(os.environ,ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',UBSAN_OPTIONS='halt_on_error=1'))
    wrong=subprocess.run([str(exe),'wrong'],capture_output=True,text=True,timeout=5)
    if wrong.returncode==0 or 'p.total==4' not in wrong.stderr:
        raise SystemExit('planted wrong value must fail CHECK even with NDEBUG')
    (w/(exe.name+'-wrong.log')).write_text(wrong.stdout+wrong.stderr)
print(f'go-maps-component: normal, sanitizer and planted-wrong cases pass in {time.monotonic()-start:.2f}s')
