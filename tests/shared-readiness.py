#!/usr/bin/env python3
"""Startup connection retries preserve refusal and error handling."""
import errno
from importlib.machinery import SourceFileLoader
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

shared = SourceFileLoader('shared_readiness_harness', str(Path(__file__).with_name('shared-sessions.py'))).load_module()


def delayed_listener(missing):
    with tempfile.TemporaryDirectory(prefix='socket-ready-') as directory:
        path = Path(directory) / 's'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener, socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            if not missing:
                listener.bind(str(path))
            calls = []

            class Probe:
                def connect(self, address):
                    calls.append(address)
                    try:
                        client.connect(address)
                    except OSError as error:
                        assert error.errno == (errno.ENOENT if missing else errno.ECONNREFUSED), error
                        # Publish/listen only after the first failed connection,
                        # so the race is reproduced without a scheduling sleep.
                        if missing:
                            listener.bind(address)
                        listener.listen(1)
                        raise

            shared.connect_ready(Probe(), path, lambda: True)
            accepted, _ = listener.accept()
            accepted.close()
            assert len(calls) == 2, calls


def lightweight_owner():
    # FD/GUI suites intentionally provide a path and client registry only.
    with tempfile.TemporaryDirectory(prefix='socket-owner-') as directory:
        path = Path(directory) / 's'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path)); listener.listen(1)
            owner = SimpleNamespace(path=path, clients=[])
            client = shared.Client(owner, 'fixture', handshake=False)
            accepted, _ = listener.accept()
            accepted.close(); client.close()
            assert owner.clients == [client]


def errors():
    calls = []

    class Refused:
        def connect(self, address):
            calls.append(address)
            raise ConnectionRefusedError(errno.ECONNREFUSED, 'fixture not listening')

    with patch.object(shared.time, 'monotonic', side_effect=[0, 6]):
        try:
            shared.connect_ready(Refused(), 'fixture', lambda: True, timeout=5)
            raise RuntimeError('permanent refusal was ignored')
        except AssertionError as error:
            assert 'socket listener readiness' in str(error), error
    assert calls == ['fixture'], calls
    calls.clear()
    try:
        shared.connect_ready(Refused(), 'fixture', lambda: False)
        raise RuntimeError('server exit was ignored')
    except AssertionError as error:
        assert 'server exited' in str(error), error
    assert not calls, calls

    class Denied:
        def connect(self, address):
            calls.append(address)
            raise PermissionError(errno.EACCES, 'fixture permission denied')

    try:
        shared.connect_ready(Denied(), 'fixture', lambda: True)
        raise RuntimeError('permission failure was ignored')
    except PermissionError:
        pass
    assert calls == ['fixture'], calls


lightweight_owner()
delayed_listener(False)
delayed_listener(True)
errors()
print('socket readiness: lightweight owner, real bind/listen and missing-path races, bounded refusal, exit and permission failures passed')
