#!/usr/bin/env python3
"""Build a fresh owned Bionic APK test bundle locally. No ADB or device changes."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import zipfile
ROOT = Path(__file__).resolve().parents[2]
NAMES = ('xodb', 'loader', 'libraries.apk', 'left.debug', 'right.debug', 'tick.c')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ndk', required=True, type=Path)
    parser.add_argument('--server', required=True, type=Path)
    args = parser.parse_args()
    tool = args.ndk.resolve() / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
    run = ROOT / '.work' / ('bionic-apk-bundle-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
    run.mkdir(parents=True)
    env = dict(os.environ, TMPDIR=str(run))
    commands = []
    def command(argv):
        commands.append(list(map(str, argv)))
        done = subprocess.run(argv, capture_output=True, env=env, text=True)
        if done.returncode: raise RuntimeError(done.stderr)
    source = ROOT / 'tests/fixtures/apk/tick.c'
    clang = tool / 'aarch64-linux-android29-clang'
    common = ['-g', '-gdwarf-4', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror', '-Wl,--build-id=sha1', '-Wl,-z,max-page-size=16384']
    for name, initial in [('left', 7), ('right', 100)]:
        command([clang, *common, '-shared', '-nostdlib', '-fPIC', '-fno-stack-protector', '-Wl,-Bsymbolic',
                 '-DTICK=apk_' + name + '_tick', '-DINITIAL=' + str(initial), source, '-o', run / (name + '.so')])
        command([tool / 'llvm-strip', '--strip-all', '-o', run / (name + '.stripped.so'), run / (name + '.so')])
        command([tool / 'llvm-objcopy', '--only-keep-debug', run / (name + '.so'), run / (name + '.debug')])
    command([clang, *common, '-fPIE', '-pie', ROOT / 'tests/fixtures/apk/bionic-loader.c', '-ldl', '-o', run / 'loader'])
    offsets = {}
    with zipfile.ZipFile(run / 'libraries.apk', 'x', allowZip64=False) as archive:
        for name in ('left', 'right'):
            entry = zipfile.ZipInfo('lib/arm64-v8a/' + name + '.so')
            pad = (-(archive.fp.tell() + 30 + len(entry.filename) + 4)) % 16384
            entry.extra = struct.pack('<HH', 0xcafe, pad) + bytes(pad)
            archive.writestr(entry, (run / (name + '.stripped.so')).read_bytes())
            offsets[name] = entry.header_offset + 30 + len(entry.filename) + len(entry.extra)
            assert offsets[name] % 16384 == 0
    shutil.copy2(args.server.resolve(), run / 'xodb')
    shutil.copy2(source, run / 'tick.c')
    for name in ('xodb', 'loader', 'left.debug', 'right.debug'):
        data = (run / name).read_bytes()
        assert data[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<H', data, 18)[0] == 183, name
    with (run / 'elf-metadata.txt').open('x') as out:
        for name in ('loader', 'left.so', 'left.stripped.so', 'left.debug', 'right.so', 'right.debug'):
            out.write('\n' + name + '\n'); out.flush()
            subprocess.run([tool / 'llvm-readelf', '-hlSn', run / name], check=True, stdout=out)
    manifest = dict(kind='xodb-bionic-apk-test-v1', ndk=str(args.ndk.resolve()), commands=commands,
                    offsets=offsets, files={name: dict(bytes=(run / name).stat().st_size, sha256=hashlib.sha256((run / name).read_bytes()).hexdigest()) for name in NAMES})
    (run / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(run)
    print(json.dumps(dict(offsets=offsets, upload_bytes=sum(x['bytes'] for x in manifest['files'].values())), indent=2))
if __name__ == '__main__': main()
