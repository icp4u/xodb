#!/usr/bin/env python3
"""Bounded sanitizer runs of the LLDB parsers and production Mach-O worker."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time
from helpers import orphans

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT/'tests/fixtures/macos-names'


def main():
    os.chdir(ROOT)
    os.umask(0o022)
    orphans.adopt()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--wrong-result', action='store_true')
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True)
    result = dict(status='running', rows=[])
    start = time.monotonic()

    def run(name, command, env=None, timeout=60):
        child = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env)
        (work/(name+'.log')).write_text(child.stdout+child.stderr)
        assert child.returncode == 0, (name, child.returncode, child.stderr[-4000:])
        return child.stdout+child.stderr

    try:
        binary = work/'check'
        compiler = ['clang', '-std=c11', '-O1', '-g', '-DNDEBUG', '-fno-sanitize-recover=all']
        if args.worker:
            # The runtime archive comes from src/runtime/runtime_sources.list, built with the same sanitizers.
            sanitize = ['-fsanitize=address,undefined', '-ffunction-sections', '-fdata-sections']
            library = work/'runtime/libxrt.a'
            run('runtime', ['make', '-C', 'src/runtime', 'BUILD='+str(library.parent), '-j4', str(library)],
                env=dict(os.environ, CC='clang', CFLAGS=' '.join(compiler[1:]+sanitize)), timeout=300)
            run('compile', compiler+sanitize+[
                'tests/macho-job.c', 'src/binary/macho.c', 'src/binary/macho_job.c',
                'src/debug/macho_dwarf.c', 'src/debug/macho_object.c', 'src/debug/macho_unwind.c',
                str(library), '-Isrc/runtime', '-pthread', '-ldl', '-latomic', '-Wl,--gc-sections', '-o', str(binary)])
            original = FIXTURES/'corpus/out/c/arm64-O2/cprog'
            data = original.read_bytes()
            at = 32
            uuid = None
            for _ in range(struct.unpack_from('<I', data, 16)[0]):
                cmd, size = struct.unpack_from('<II', data, at)
                if cmd == 0x1b:
                    uuid = data[at+8:at+24].hex()
                at += size
            assert uuid
            cpu, sub = struct.unpack_from('<II', data, 4)
            identity = [uuid, str(cpu), str(sub)]
            # This symbol is independently recorded by nm and LLDB.
            output = run('oracle', [str(binary), 'one', str(original), *identity, '0x1000006d8'])
            assert 'state=1 ' in output and '-> ok _tick value=0x1000006d8' in output, output
            assert ('_wrong_tick' if args.wrong_result else '_tick') in output, output
            result['rows'].append(dict(case='symbol-oracle', status='pass'))
            # Mutate each file class while keeping its companions intact. The
            # worker reads the production file identity, not a test substitute.
            for kind in ('image', 'dsym', 'object'):
                directory = work/kind
                directory.mkdir()
                local = directory/'cprog'
                shutil.copyfile(original, local)
                env = dict(os.environ)
                if kind == 'image':
                    seed, target = original, local
                elif kind == 'dsym':
                    seed = original.with_name('cprog.dSYM')/'Contents/Resources/DWARF/cprog'
                    target = local.with_name('cprog.dSYM')/'Contents/Resources/DWARF/cprog'
                    target.parent.mkdir(parents=True)
                    env['XMO_FIXED_EXE'] = str(local)
                else:
                    for obj in original.parent.glob('*.o'):
                        shutil.copyfile(obj, directory/obj.name)
                    seed, target = original.parent/'main.o', directory/'main.o'
                    env['XMO_FIXED_EXE'] = str(local)
                # Thirty seconds per file class: three found nothing in a defect this
                # harness reaches in under thirty (a symbol whose n_sect names no section).
                output = run(kind, [str(binary), 'mut', str(seed), *identity, '30', str(target), '771'], env)
                counts = re.search(r'runs=(\d+) ready=(\d+) names=(\d+)', output)
                assert counts and int(counts[1]) > 0 and int(counts[2]) > 0, output
                result['rows'].append(dict(case=kind, status='pass', runs=int(counts[1]), ready=int(counts[2]), names=int(counts[3])))
        else:
            run('compile', compiler+['-fsanitize=fuzzer,address,undefined', '-Isrc/runtime',
                'tests/fuzz-gdb-lldb.c', 'src/runtime/gdb_lldb.c', '-o', str(binary)])
            corpus = work/'corpus'
            corpus.mkdir()
            values = set()
            for path in sorted((FIXTURES/'transcripts').glob('*.json')):
                recording = json.loads(path.read_text())
                for query, replies in recording['exchanges']:
                    if query.startswith(('qHostInfo', 'qProcessInfo', 'qMemoryRegionInfo:', 'jGetLoadedDynamicLibrariesInfos:')):
                        values.update(replies)
            assert any('images' in value for value in values) and len(values) > 10
            for i, value in enumerate(sorted(values)):
                (corpus/str(i)).write_bytes(value.encode())
            env = dict(os.environ)
            if args.wrong_result:
                env['XRT_FUZZ_WRONG_RESULT'] = '1'
            output = run('fuzz', [str(binary), str(corpus), '-max_total_time=10', '-timeout=5',
                                 '-max_len=1048576', '-seed=771', '-artifact_prefix='+str(work)+'/'], env, 45)
            assert 'DONE' in output and 'Done ' in output, output[-3000:]
            result['rows'].append(dict(case='lldb-parsers', status='pass', seeds=len(values)))
        result['status'] = 'pass'
    finally:
        assert orphans.reap(), 'a child process is still running'
        if result['status'] == 'running':
            result['status'] = 'fail'
        result['seconds'] = time.monotonic()-start
        (work/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
