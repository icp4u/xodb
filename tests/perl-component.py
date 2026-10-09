#!/usr/bin/env python3
"""Check the read-only Perl reader against an explicitly supplied debug SDK and
PadWalker oracle. PadWalker is a test-only dependency; nothing is installed.
"""
import argparse
import hashlib
import json
import os
import re
import resource
from pathlib import Path
import shlex
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl', required=True)
p.add_argument('--padwalker', required=True, type=Path, help='built PadWalker tree containing blib/lib and blib/arch')
p.add_argument('--work', required=True, type=Path)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args()
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
a.work = a.work.resolve()
a.work.mkdir(parents=True, mode=0o755)
a.padwalker = a.padwalker.resolve()
config = json.loads(subprocess.check_output([a.perl, '-MConfig', '-MJSON::PP', '-e',
    'print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(version archlib cc ccflags useithreads usemultiplicity)})'], timeout=30))
assert config['version'] == '5.44.0' and config['useithreads'] == 'define' and config['usemultiplicity'] == 'define', config
(a.work/'config.json').write_text(json.dumps(config, indent=2)+'\n')
cc = shlex.split(config['cc'])
sanitize = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else []
source = ['src/language/perl.c', 'src/language/perl_layout.c']

def run(name, argv, env=None):
    r = subprocess.run([str(x) for x in argv], env=env, capture_output=True, text=True, timeout=90)
    (a.work/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    return r

exe = a.work/'reader'
run('reader-build', [*cc, '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror', *sanitize,
    *source, 'tests/perl-reader.c', '-ldw', '-lelf', '-o', exe])
r = run('reader', [exe])
assert '2000 corrupt objects passed' in r.stdout
shared = a.work/'named.so'
run('oracle-build', [*cc, *shlex.split(config['ccflags']), '-U_FORTIFY_SOURCE', '-DNDEBUG', '-shared', '-fPIC',
    '-g3', '-O0', *sanitize, '-DXODB_PERL_ORACLE', '-I'+config['archlib']+'/CORE',
    'tests/fixtures/perl/named.c', *source, '-ldw', '-lelf', '-o', shared])
image = Path(config['archlib'])/'CORE/libperl.so'
env = dict(os.environ, PERL5LIB=str(a.padwalker/'blib/lib')+':'+str(a.padwalker/'blib/arch'),
    XODB_PERL_ORACLE_IMAGE=str(image))
if a.sanitize:
    asan = subprocess.check_output([*cc, '-print-file-name=libasan.so'], text=True, timeout=30).strip()
    env['LD_PRELOAD'] = asan
    # The host interpreter retains globals at exit; the standalone C suite above
    # still runs leak detection. Address and UB checks cover both processes.
    env['ASAN_OPTIONS'] = 'detect_leaks=0:abort_on_error=1'
run('oracle-version', [a.perl, '-MPadWalker', '-e', 'print "$PadWalker::VERSION\n"'], env)
r = run('oracle', [a.perl, 'tests/fixtures/perl/named.pl', shared], env)
assert '81 bindings, 20 frames, 9 snapshots passed' in r.stdout, r.stdout
named_result = r.stdout.splitlines()[-1]
watch = a.work/'watches.so'
run('watch-oracle-build', [*cc, *shlex.split(config['ccflags']), '-U_FORTIFY_SOURCE', '-DNDEBUG', '-shared', '-fPIC',
    '-g3', '-O0', *sanitize, '-DXODB_PERL_WATCH_ORACLE', '-I'+config['archlib']+'/CORE',
    'tests/fixtures/perl/watches.c', *source, '-ldw', '-lelf', '-o', watch])
# The cooperating program's own macros produce expected bytes; its separately
# linked C reader asserts every complete/refused result before the stopped hook.
watch_run = subprocess.run([a.perl,'tests/fixtures/perl/watches.pl',str(watch)], input='go\n',
    env=env, capture_output=True, text=True, timeout=90)
(a.work/'watch-oracle.log').write_text(watch_run.stdout+watch_run.stderr)
assert watch_run.returncode == 0, (watch_run.returncode, watch_run.stderr)
oracles = [json.loads(line) for line in watch_run.stdout.splitlines() if line.startswith('{')]
samples = sum(len(frame) for oracle in oracles for frame in oracle['frames'])
assert int(re.findall(r'verified (\d+) scalar samples',watch_run.stderr)[-1]) == samples and samples > 0
first = oracles[0]
assert first['label'] == 'initial'
assert any(row['name'] == '$élan' for frame in first['frames'] for row in frame), 'Unicode oracle binding missing'
deep = next(row for row in oracles if row['label'] == 'deep')
assert first['context_array'] != deep['context_array'], 'oracle must observe actual context-array relocation'
# Deliberate mismatches must fail even when the SDK or command defines NDEBUG.
negative_controls = {}
for name, define, condition in [
    ('named', 'XODB_PERL_ORACLE', 'locals->total == HvTOTALKEYS(bindings)'),
    ('watches', 'XODB_PERL_WATCH_ORACLE', 'observed.kind == kind'),
]:
    bad = a.work/(name+'-negative.so')
    run(name+'-negative-build', [*cc, *shlex.split(config['ccflags']), '-U_FORTIFY_SOURCE',
        '-DNDEBUG', '-shared', '-fPIC', '-g3', '-O0', *sanitize, '-D'+define,
        '-DXODB_PERL_ORACLE_NEGATIVE', '-I'+config['archlib']+'/CORE',
        'tests/fixtures/perl/'+name+'.c', *source, '-ldw', '-lelf', '-o', bad])
    control = subprocess.run([a.perl, 'tests/fixtures/perl/'+name+'.pl', str(bad)],
        input='go\n', env=env, capture_output=True, text=True, timeout=90)
    (a.work/(name+'-negative.log')).write_text(control.stdout+control.stderr)
    assert control.returncode != 0 and 'CHECK failed: '+condition in control.stderr, (
        'wrong oracle result was not rejected', name, control.returncode, control.stderr)
    negative_controls[name] = {'status':'rejected', 'returncode':control.returncode, 'condition':condition}
inputs = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in [image, a.padwalker/'blib/lib/PadWalker.pm', a.padwalker/'blib/arch/auto/PadWalker/PadWalker.so',
                 *sorted((image.parent).glob('*.h'))]}
(a.work/'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
(a.work/'results.json').write_text(json.dumps({'reader': 'pass', 'padwalker_oracle': 'pass',
    'bindings': 81, 'frames': 20, 'snapshots': 9, 'malformed_cases': 2000, 'sanitizers': a.sanitize, 'scalar_oracle_samples':samples, 'context_array_relocated':True, 'negative_controls':negative_controls}, indent=2)+'\n')
print(named_result)
print(f'Perl stopped scalar bytes: {samples} public-macro oracle samples and context relocation passed')
