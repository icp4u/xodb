"""Hold one explicitly armed pthread callback while the owner keeps serving MCP."""
import os
from pathlib import Path
import subprocess
import time


class WorkerGate:
    def __init__(self, root, work):
        self.work = (work / 'worker-gate').resolve()
        self.work.mkdir()
        library = self.work / 'gate.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(root / 'tests/worker-gate.c'), '-ldl', '-pthread', '-o', str(library)],
                       check=True, timeout=60)
        self.env = dict(LD_PRELOAD=str(library), XODB_TEST_WORKER_GATE=str(self.work))
        self.previous = {key:os.environ.get(key) for key in self.env}
        os.environ.update(self.env)
        self.round = None
        self.history = []

    def arm(self, label):
        assert self.round is None
        self.round = self.work / label
        self.round.mkdir()
        (self.work / 'arm').write_text(str(self.round))

    def held(self):
        deadline = time.monotonic() + 30
        while not (self.round / 'entered').exists():
            assert not (self.round / 'spawn-failed').exists(), 'worker spawn failed'
            assert time.monotonic() < deadline, 'armed callback was never intercepted'
            time.sleep(.002)
        self.assert_held()

    def assert_held(self):
        assert self.round is not None
        assert (self.round / 'entered').exists(), 'worker has not entered barrier'
        assert not (self.round / 'timeout').exists(), 'barrier watchdog expired'
        assert not (self.round / 'release').exists(), 'worker was already released'
        assert not (self.round / 'released').exists(), 'worker callback escaped barrier'

    def release(self):
        if self.round is None: return
        self.history.append(self.round.name)
        (self.round / 'release').touch()
        # An unclaimed arm must not leak into a later callback during cleanup.
        (self.work / 'arm').unlink(missing_ok=True)
        self.round = None

    def close(self):
        self.release()
        for key, value in self.previous.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value
