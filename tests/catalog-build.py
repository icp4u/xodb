#!/usr/bin/env python3
"""Periodic: ordinary builds reject malformed MCP catalogs before compiling xodb."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
from helpers.input import load_scale
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wrong-result', action='store_true')
p.add_argument('--wrong-assembly-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
tree = w/'source'
tree.mkdir()
scale = load_scale()
started = time.monotonic()
rows = []
manifest = {}
# Copy only source roots, never a running gate's caches, sockets or artifacts.
# Some compiler fixtures create an out/ directory during build-tests.
for base in ('src', 'tests', 'scripts', 'tools', 'examples', 'packaging', 'docs', 'config'):
    for directory, dirs, files in os.walk(root/base, followlinks=False):
        dirs[:] = [name for name in dirs if name not in ('out', '.work', '.cache', '.zig-cache', 'zig-out', '__pycache__', '.git')
                   and not (Path(directory)/name).is_symlink()]
        for name in files:
            source = Path(directory)/name
            if not stat.S_ISREG(source.lstat().st_mode):
                continue
            relative = source.relative_to(root)
            dest = tree/relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, dest)
            manifest[str(relative)] = hashlib.sha256(source.read_bytes()).hexdigest()
# Every top-level build script: build.zig @imports its per-OS siblings.
for name in sorted({path.name for path in root.glob('build*.zig')} | {'build.zig.zon', 'README.md', 'LICENSE', 'SETUP.md'}):
    if (root/name).is_file():
        shutil.copy2(root/name, tree/name)
        manifest[name] = hashlib.sha256((root/name).read_bytes()).hexdigest()
(w/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
env = dict(os.environ)
for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
    env.pop(key, None)

def build(label, target, expected, diagnostic=None):
    argv = ['scripts/build', *([target] if target else []), '-Dgui=false', '-Doptimize=ReleaseSafe', '-j2', '--summary', 'all']
    begin = time.monotonic()
    r = subprocess.run(argv, cwd=tree, env=env, capture_output=True, text=True, timeout=300*scale)
    text = r.stdout+r.stderr
    (w/(label+'.log')).write_text(text)
    row = dict(case=label, exit=r.returncode, expected=expected, seconds=time.monotonic()-begin)
    rows.append(row)
    (w/'results.json').write_text(json.dumps(dict(checks=rows, seconds=time.monotonic()-started), indent=2)+'\n')
    assert (r.returncode == 0) == (expected == 0), (label, r.returncode, expected, text[-2000:])
    if diagnostic:
        assert diagnostic in text and 'MCP catalog src/mcp/' in text, (label, text[-2000:])

build('valid', 'check-catalog', 0)
catalogs = sorted((tree/'src/mcp').glob('*_tools.json'))
assert len(catalogs) == 11, 'update the catalog coverage when adding a publication fragment'
for index, path in enumerate(catalogs):
    original = path.read_bytes()
    try:
        # Preserve the outer brackets so the old embed/concatenate expressions
        # still compile; only an actual JSON validator can reject this text.
        path.write_bytes(b'[ { invalid catalog } ]\n')
        build(path.stem+'-syntax', None if index == 0 else 'check-catalog',
              0 if a.wrong_result else 1, 'SyntaxError')
    finally:
        path.write_bytes(original)

base = tree/'src/mcp/base_tools.json'
original = base.read_bytes()
definitions = json.loads(original)
cases = [
    ('top-level', {}, 'InvalidToolCatalog'),
    ('entry-kind', [None], 'InvalidToolDefinition'),
    ('missing-name', [dict(annotations=definitions[0]['annotations'])], 'MissingToolName'),
    ('empty-name', [dict(definitions[0], name='')], 'InvalidToolName'),
    ('duplicate-name', [definitions[0], definitions[0]], 'DuplicateToolName'),
]
for label, annotation in (
    ('missing-access', dict(readOnlyHint=True)),
    ('bad-access', dict(readOnlyHint=True, xodbSessionAccess='unknown')),
    ('observer-write', dict(readOnlyHint=False, xodbSessionAccess='observer')),
    ('invalid-read-only', dict(readOnlyHint='true', xodbSessionAccess='controller')),
    ('lease-outside-session', dict(readOnlyHint=False, xodbSessionAccess='lease')),
):
    cases.append((label, [dict(definitions[0], annotations=annotation)],
                  'MissingToolSessionAccess' if label == 'missing-access' else 'InvalidToolSessionAccess'))
# Separate fragments of one advertised list must share their duplicate table.
static = json.loads((tree/'src/mcp/static_tools.json').read_text())
cases.append(('cross-fragment-duplicate', [dict(definitions[0], name=static[0]['name'])], 'DuplicateToolName'))
for label, value, diagnostic in cases:
    try:
        base.write_text(json.dumps(value)+'\n')
        build(label, 'app', 1, diagnostic)
    finally:
        base.write_bytes(original)
# Valid JSON formatting must also produce valid *assembled* publication lists.
# Mutate every fragment: the same joiner backs native and overview-only modes.
for path in catalogs:
    original = path.read_bytes()
    try:
        path.write_bytes(b' \t\r\n'+original+b'\t\r\n')
        build(path.stem+'-whitespace', 'check-catalog', 0)
        path.write_bytes(b' \t[ \r\n ]\n')
        build(path.stem+'-empty', 'check-catalog', 0)
    finally:
        path.write_bytes(original)
# Exercise the actual publication path with all fragments surrounded by JSON
# whitespace and one native fragment empty. The former literal slices compiled
# this input but served SyntaxError; checking each fragment alone missed it.
saved = {path: path.read_bytes() for path in catalogs}
try:
    for path, data in saved.items():
        path.write_bytes(b' \t\r\n'+data+b'\t\r\n')
    (tree/'src/mcp/static_tools.json').write_bytes(b' \n[]\t\r\n')
    build('assembled-publication', 'app', 0)
    expected = []
    # Native publication order: tool_catalog.inputs[0..9].
    for name in ('base', 'static', 'runtime_type', 'macho', 'overview', 'fd', 'memstat', 'redot', 'evidence'):
        expected.extend(json.loads((tree/'src/mcp'/(name+'_tools.json')).read_bytes()))
    os.environ['XODB_BIN'] = str(tree/'zig-out/bin/xodb')
    client = Client('mutate', executable=None, reply_seconds=10*scale)
    try:
        reply = client.call('tools/list')
        (w/'publication.rpc.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        actual = reply.get('result', {}).get('tools')
        assert actual == ([] if a.wrong_assembly_result else expected), ('assembled publication mismatch', reply.get('error'))
    finally:
        client.close()
        (w/'publication.stderr').write_bytes(client.p.stderr.read())
    rows.append(dict(case='assembled-tools-list', exit=0, expected=0, tools=len(actual)))
finally:
    for path, data in saved.items():
        path.write_bytes(data)
build('restored', 'check-catalog', 0)
print(json.dumps(dict(status='pass', checks=len(rows), seconds=time.monotonic()-started)))
