#!/usr/bin/env python3
"""File and loaded-image checks for ranged V8 metadata, without target calls."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
p.add_argument('--image', type=Path, help='Optional real image for a libelf comparison')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=True)
exe = w / 'image'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
                '-Wall', '-Wextra', '-Werror', 'tests/javascript-image.c',
                'src/language/javascript_image.c', 'src/language/javascript.c',
                'src/binary/symbol_query.c', 'src/binary/object.c', '-lelf', '-lm',
                '-o', str(exe)], check=True, timeout=60)
rows = []


def run(name, image, mode='plain', status='ok', reason='-'):
    r = subprocess.run([str(exe), str(image), mode, status, reason], capture_output=True, text=True, timeout=60)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    rows.append({'name': name, 'status': 'pass', 'stdout': r.stdout, 'stderr': r.stderr})


names = dict(re.findall(r'XJS_FIELD\((\w+), "([^"]+)"\)', (root / 'src/language/javascript_fields.inc').read_text()))
values = dict(re.findall(r'META\((\w+), (-?\d+)\)', (root / 'tests/fixtures/javascript/metadata.inc').read_text()))
source = '\n'.join(f'int f_{key} __asm__("{names[key]}") = {value};' for key, value in values.items())
for name, value in zip(('major', 'minor', 'build', 'patch'), (14, 6, 202, 34)):
    source += f'\nint version_{name} __asm__("_ZN2v88internal7Version{len(name) + 1}{name}_E") = {value};'
source += '''
const char version_text[64] = "14.6.202.34-node.28";
const char *version_pointer __asm__("_ZN2v88internal7Version15version_string_E") = version_text;
int main(void) { return 0; }
'''
fixture = w / 'fixture.c'
fixture.write_text(source)
for pie in (False, True):
    image = w / ('pie' if pie else 'exec')
    subprocess.run(['cc', '-g', '-O0', '-fPIE' if pie else '-fno-pie', '-pie' if pie else '-no-pie',
                    '-Wl,--build-id=sha1', str(fixture), '-o', str(image)], check=True, timeout=30)
    run(image.name, image)
    for mode, status, reason in [
        ('slow', 'ok', '-'),
        ('constant', 'malformed', 'JavaScriptMetadataMismatch'),
        ('note', 'malformed', 'JavaScriptBuildIdMismatch'),
        ('version', 'malformed', 'JavaScriptVersionMismatch'),
        ('pointer', 'malformed', 'JavaScriptMetadataUnavailable'),
        ('memory', 'io', 'JavaScriptMemoryUnavailable'),
        ('change', 'changed', 'JavaScriptMetadataFileChanged'),
        ('cancel', 'cancelled', 'JavaScriptMetadataCancelled'),
        ('deadline', 'pending', 'JavaScriptMetadataPending'),
        ('budget', 'pending', 'JavaScriptMetadataPending'),
    ]:
        run(image.name + '-' + mode, image, mode, status, reason)
for name, replace, status, reason in [
    ('unsupported-version', ('version_major __asm__("_ZN2v88internal7Version6major_E") = 14', 'version_major __asm__("_ZN2v88internal7Version6major_E") = 15'), 'malformed', 'JavaScriptVersionUnsupported'),
    ('negative-version', ('version_patch __asm__("_ZN2v88internal7Version6patch_E") = 34', 'version_patch __asm__("_ZN2v88internal7Version6patch_E") = -1'), 'malformed', 'JavaScriptVersionUnsupported'),
    ('bad-pointer-size', ('f_POINTER_SIZE __asm__("v8dbg_SystemPointerSize") = 8', 'f_POINTER_SIZE __asm__("v8dbg_SystemPointerSize") = 4'), 'malformed', 'JavaScriptCompressedPointersUnsupported'),
    ('missing-required', ('v8dbg_SystemPointerSize', 'missing_SystemPointerSize'), 'malformed', 'JavaScriptMetadataUnavailable'),
    ('missing-version', ('_ZN2v88internal7Version6patch_E', 'missing_version_patch'), 'not-found', 'JavaScriptVersionUnavailable'),
    ('missing-runtime', ('_ZN2v88internal7Version15version_string_E', 'missing_runtime_pointer'), 'not-found', 'JavaScriptRuntimeUnavailable'),
    ('wrong-constant-size', ('int f_POINTER_SIZE', 'long f_POINTER_SIZE'), 'malformed', 'JavaScriptMetadataInconsistent'),
]:
    assert replace[0] in source
    path = w / (name + '.c')
    path.write_text(source.replace(*replace))
    image = w / name
    subprocess.run(['cc', '-g', '-O0', '-fno-pie', '-no-pie', '-Wl,--build-id=sha1',
                    str(path), '-o', str(image)], check=True, timeout=30)
    run(name, image, status=status, reason=reason)
# Preserve loadable bytes while moving only the symbol/string tables beyond
# 5 GiB. The metadata path must never copy that whole sparse extent.
image = w / 'sparse-large'
data = bytearray((w / 'exec').read_bytes())
header = struct.unpack_from('<Q', data, 40)[0]
count = struct.unpack_from('<H', data, 60)[0]
far = 5 * 1024 ** 3
payloads = []
for i in range(count):
    at = header + i * 64
    kind = struct.unpack_from('<I', data, at + 4)[0]
    if kind != 2:
        continue
    linked = struct.unpack_from('<I', data, at + 40)[0]
    for index in (i, linked):
        pos = header + index * 64
        offset, size = struct.unpack_from('<QQ', data, pos + 24)
        payloads.append((far, data[offset:offset + size]))
        struct.pack_into('<Q', data, pos + 24, far)
        far += size + 4096
with image.open('wb') as f:
    f.write(data)
    for offset, payload in payloads:
        f.seek(offset)
        f.write(payload)
run('sparse-large', image)
if a.image:
    run('real-image', a.image)
(w / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Ranged JavaScript image checks passed:', len(rows))
