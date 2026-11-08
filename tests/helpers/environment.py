"""Private application XDG directories, with explicitly shared tool caches."""
import os
from pathlib import Path
import tempfile

_standalone = None


def isolated(inherited, root):
    """Build one run's environment without changing the caller's dictionary."""
    env = dict(inherited)
    root = Path(root).resolve()
    home = Path(env['HOME']) if env.get('HOME') else None
    cache = Path(env.get('XDG_CACHE_HOME', ''))
    if not cache.is_absolute():
        cache = home / '.cache' if home and home.is_absolute() else root / 'tool-cache'
    # Capture these BEFORE replacing XDG_CACHE_HOME. Their content-addressed
    # caches are independent of xodb's debug-image and sidecar caches.
    tool_caches = {
        'ZIG_GLOBAL_CACHE_DIR': cache / 'zig',
        'GOCACHE': cache / 'go-build',
        # Mesa appends mesa_shader_cache (or its backend variant) itself.
        'MESA_SHADER_CACHE_DIR': cache,
    }
    go_path = env.get('GOPATH', '').split(os.pathsep)[0]
    go_root = Path(go_path) if go_path else home / 'go' if home else root / 'go'
    tool_caches['GOMODCACHE'] = go_root / 'pkg/mod'
    for name, path in tool_caches.items():
        if not env.get(name):
            env[name] = str(path)
    for kind in ('CACHE', 'STATE', 'CONFIG'):
        path = root / kind.lower()
        path.mkdir(parents=True, mode=0o755, exist_ok=True)
        env[f'XDG_{kind}_HOME'] = str(path)
    env['XODB_TEST_XDG_ROOT'] = str(root)
    return env


def ensure():
    """Standalone helpers share one private baseline for this test process.

    Import before test-specific overrides. In a gate the run already owns the
    baseline, so imports never replace a test's explicit cache/config cases.
    """
    global _standalone
    if os.environ.get('XODB_TEST_XDG_ROOT'):
        return
    work = Path(os.environ.get('XODB_TEST_TMPDIR', Path(__file__).resolve().parents[2] / '.work'))
    work.mkdir(parents=True, mode=0o755, exist_ok=True)
    _standalone = tempfile.TemporaryDirectory(prefix='test-xdg-', dir=work)
    Path(_standalone.name).chmod(0o755)
    os.environ.update(isolated(os.environ, _standalone.name))
