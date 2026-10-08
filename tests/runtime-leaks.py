#!/usr/bin/env python3
"""Prove that launch-failure cleanup still reports an intentionally planted leak."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
work = a.work.resolve()
work.mkdir(parents=True, mode=0o755)
build = work/'clean'
flags = ['-std=c11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
         '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
env = {**os.environ, 'ASAN_OPTIONS':'detect_leaks=1:halt_on_error=1',
       'UBSAN_OPTIONS':'halt_on_error=1'}
env.pop('XODB_TEST_NO_LIVE', None)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
with (work/'build.log').open('w') as log:
    subprocess.run(['make', '-C', str(root/'src/runtime'), '-j1', 'CC=clang',
                    'BUILD='+str(build), 'CFLAGS='+' '.join(flags), str(build/'test-process')],
                   env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)

def run(exe, name):
    with (work/(name+'.log')).open('w') as log:
        result = subprocess.run([str(exe)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=45)
    return result.returncode, (work/(name+'.log')).read_text()

clean, text = run(build/'test-process', 'clean')
assert clean == 0 and 'LeakSanitizer' not in text, (clean, text)
# Mutate an owned source copy only. Keep this out of the production runtime.
source = (root/'src/runtime/process.c').read_text()
needle = '    if (result != XRT_OK)\n        abort_launch(child);'
assert source.count(needle) == 1, 'launch-cleanup fixture needs updating'
planted = source.replace(needle, '''    if (result != XRT_OK) {
        char *volatile leak = malloc(55);
        if (!leak) abort();
        leak[0] = 1;
        leak = NULL;
        abort_launch(child);
    }''')
(work/'process-planted.c').write_text(planted)
with (work/'plant-build.log').open('w') as log:
    subprocess.run(['clang', *flags, '-I'+str(root/'src/runtime'), '-c',
                    str(work/'process-planted.c'), '-o', str(work/'process-planted.o')],
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    objects = [str(p) for p in sorted(build.glob('*.o')) if p.name != 'process.o']
    assert objects and (build/'process.o').exists()
    subprocess.run(['clang', *flags, '-UNDEBUG', '-I'+str(root/'src/runtime'),
                    str(root/'tests/runtime-process.c'), *objects, str(work/'process-planted.o'),
                    '-latomic', '-pthread', '-o', str(work/'test-planted')],
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
code, text = run(work/'test-planted', 'planted')
assert code != 0, 'planted launch-failure leak did not fail the process test'
assert 'LeakSanitizer: detected memory leaks' in text and '55 byte(s)' in text, text
assert 'xrt_process_launch' in text or 'process-planted.c' in text, text
(work/'results.json').write_text(json.dumps({'status':'pass', 'clean_exit':clean,
    'planted_exit':code, 'leak_bytes':55, 'launch_failure_leak_detected':True}, indent=2)+'\n')
print('Clean process test passes; planted launch-cleanup leak fails with LeakSanitizer')
