#!/usr/bin/env python3
"""Privacy gate: no tracked file is a packet capture.

Captured traffic is the user's private data; fixtures are generated at run
time by owned programs (tests/network-evidence.py). A tracked file starting
with a pcap or pcapng magic number fails, whatever its name.
"""
import os, re, subprocess, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
MAGIC = {bytes.fromhex(h) for h in ('a1b2c3d4', 'd4c3b2a1', 'a1b23c4d', '4d3cb2a1', '0a0d0d0a')}
CAPTURE_NAME = re.compile(r'\.(pcap|pcapng|cap|ntar|erf|snoop)(\.(gz|xz|zst|bz2|lz4))?$', re.I)
SKIP = {'.git', '.work', '.zig-cache', '.cache', 'zig-out'}

def tracked():
    try:
        out = subprocess.run(['git', 'ls-files', '-z'], cwd=root, capture_output=True, check=True).stdout
        return [root / n for n in out.decode().split('\0') if n]
    except (OSError, subprocess.CalledProcessError):
        # Release snapshots hold tracked files only and no repository.
        files = []
        for base, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP]
            files += [Path(base) / n for n in names]
        return files

def check(paths):
    bad = []
    for path in paths:
        if path.is_symlink() or not path.is_file(): continue
        with open(path, 'rb') as f: head = f.read(4)
        # Compressed captures hide the magic; their names do not.
        if head in MAGIC or CAPTURE_NAME.search(path.name): bad.append(str(path.relative_to(root)))
    return bad

# Self-test: the check must see each magic in both byte orders.
import tempfile
with tempfile.TemporaryDirectory() as scratch:
    probes = []
    for i, magic in enumerate(sorted(MAGIC)):
        p = Path(scratch) / f'probe{i}.bin'; p.write_bytes(magic + b'\0' * 20); probes.append(p)
    saved, root = root, Path(scratch)
    assert len(check(probes)) == len(MAGIC)
    root = saved

files = tracked()
bad = check(files)
if bad:
    print('tracked packet captures (private data must not enter git):', *bad, sep='\n  ')
    sys.exit(1)
print(f'pcap-magic: {len(files)} tracked files, none is a pcap/pcapng capture')
