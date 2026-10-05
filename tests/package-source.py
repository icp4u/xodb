#!/usr/bin/env python3
"""Dirty/new source retention, backup exclusion and reproducible package inputs."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='xodb-package-source-') as temporary:
    work = Path(temporary)
    repo = work / 'repo'
    repo.mkdir()
    for name in ('scripts/package-source', 'packaging/debian/changelog', 'packaging/debian/rules',
                 'packaging/arch/PKGBUILD.in', 'packaging/rpm/xodb.spec'):
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
    (repo / 'src').mkdir()
    (repo / 'src/main.zig').write_text('old\n')
    (repo / '.gitignore').write_text('.work/\n')
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    subprocess.run(['git', 'add', '.'], cwd=repo, check=True)
    (repo / 'src/main.zig').write_text('working tree\n')
    (repo / 'src/new.zig').write_text('untracked repair\n')
    (repo / 'src/new.zig').chmod(0o755)
    (repo / 'examples').mkdir()
    (repo / 'examples/observation.recipe.json').write_text('{"version":1}\n')
    for name in ('src/main.zig~', 'src/notes.bak', 'src/.private', 'src/AGENTS.md', 'README.md~'):
        (repo / name).write_text('must not ship\n')
    (repo / '.work').mkdir()
    (repo / '.work/artifact').write_text('must not ship\n')
    env = dict(os.environ, SOURCE_DATE_EPOCH='1', PYTHONDONTWRITEBYTECODE='1')
    archives = []
    for name in ('one', 'two'):
        output = work / name
        subprocess.run([sys.executable, '-B', str(repo / 'scripts/package-source'), str(output)],
                       env=env, check=True, capture_output=True)
        archive = next(output.glob('*.tar.gz'))
        archives.append(archive.read_bytes())
        digest = hashlib.sha256(archives[-1]).hexdigest()
        assert f"sha256sums=('{digest}')" in (output / 'PKGBUILD').read_text()
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            assert all(m.uid == m.gid == 0 and not m.uname and not m.gname and m.mtime == 1 for m in members)
            assert all('must not ship' not in tar.extractfile(m).read().decode() for m in members)
            prefix = archive.name.removesuffix('.tar.gz') + '/'
            assert tar.extractfile(prefix + 'src/main.zig').read() == b'working tree\n'
            assert tar.extractfile(prefix + 'src/new.zig').read() == b'untracked repair\n'
            assert tar.getmember(prefix + 'src/new.zig').mode == 0o755
            assert tar.extractfile(prefix + 'examples/observation.recipe.json').read() == b'{"version":1}\n'
            for name in ('changelog', 'rules'):
                expected = (repo / 'packaging/debian' / name).read_bytes()
                assert tar.extractfile(prefix + 'packaging/debian/' + name).read() == expected
                assert tar.extractfile(prefix + 'debian/' + name).read() == expected
            assert tar.getmember(prefix + 'debian/rules').mode == 0o755
        # Changed filesystem timestamps do not alter the next source snapshot.
        os.utime(repo / 'src/main.zig', (12345, 12345))
    assert archives[0] == archives[1]
    refused = subprocess.run([sys.executable, '-B', str(repo / 'scripts/package-source'), str(work / 'one')],
                             env=env, capture_output=True)
    assert refused.returncode != 0
    assert next((work / 'one').glob('*.tar.gz')).read_bytes() == archives[0]
    (repo / 'src/link.zig').symlink_to(work / 'outside')
    refused = subprocess.run([sys.executable, '-B', str(repo / 'scripts/package-source'), str(work / 'three')],
                             env=env, capture_output=True)
    assert refused.returncode != 0 and not (work / 'three').exists()
print('PASS dirty/new sources, Debian layout, backup exclusion, ownership/modes, reproducibility, overwrite and symlink rejection')
