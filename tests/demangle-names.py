#!/usr/bin/env python3
"""Fast component lane: bounded C++ name parser under ASan/UBSan."""
import os
from pathlib import Path
import subprocess
import time
root=Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w=root/'.work/demangle-names';w.mkdir(parents=True,exist_ok=True)
start=time.monotonic()
subprocess.run(['cc','-std=c++17','-fno-exceptions','-fno-rtti','-Wall','-Wextra','-Werror',
                '-g','-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer',
                'src/debug/demangle.cc','tests/demangle-names.cc','-o',str(w/'check')],check=True,timeout=30)
subprocess.run([str(w/'check')],check=True,timeout=20)
print(f'compile and checks: {time.monotonic()-start:.3f}s')
