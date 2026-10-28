"""Read xodb's kernel-selected MCP listen port without losing diagnostics."""
import os
from pathlib import Path
import re
import select
import time


_REPORT = re.compile(
    rb'^xodb: listening on 127\.0\.0\.1:([0-9]+); '
    rb'one client, plaintext TCP without authentication\n$'
)
_MAX_STARTUP_BYTES = 64 * 1024


def listen_and_report(process, log=None, timeout=5):
    """Return (port, bytes_seen) after an exact post-listen report.

    With the default pipe source, read the descriptor directly: mixing
    select() with BufferedReader.readline() can strand a second line in
    Python's buffer while select() waits on an empty kernel pipe. A path in
    ``log`` supports tests that send stdout and stderr to one file.
    """
    deadline = time.monotonic() + timeout
    startup = bytearray()
    checked = 0
    owned = None
    if log is None:
        assert process.stderr is not None, 'listener has no stderr pipe'
        descriptor = process.stderr.fileno()
    else:
        path = Path(log)
        while owned is None:
            try:
                owned = path.open('rb', buffering=0)
            except FileNotFoundError:
                remaining = deadline - time.monotonic()
                assert remaining > 0, 'listener did not create its log file'
                assert process.poll() is None, 'listener exited before creating its log file'
                time.sleep(min(0.01, remaining))
        descriptor = owned.fileno()
    try:
        while True:
            end = startup.find(b'\n', checked)
            while end >= 0:
                line = bytes(startup[checked:end + 1])
                checked = end + 1
                match = _REPORT.fullmatch(line)
                if match is not None:
                    port = int(match.group(1))
                    assert 0 < port <= 65535, line
                    return port, bytes(startup)
                end = startup.find(b'\n', checked)

            assert len(startup) <= _MAX_STARTUP_BYTES, (
                f'listener startup exceeded {_MAX_STARTUP_BYTES} bytes: '
                f'{startup.decode(errors="replace")}'
            )
            remaining = deadline - time.monotonic()
            assert remaining > 0, (
                'listener did not report its bound port: '
                + startup.decode(errors='replace')
            )
            if log is None:
                ready, _, _ = select.select([descriptor], [], [], remaining)
                assert ready, (
                    'listener did not report its bound port: '
                    + startup.decode(errors='replace')
                )
                chunk = os.read(descriptor, 4096)
                assert chunk, (
                    'listener exited before reporting its bound port: '
                    + startup.decode(errors='replace')
                )
            else:
                chunk = os.read(descriptor, 4096)
                if not chunk:
                    assert process.poll() is None, (
                        'listener exited before reporting its bound port: '
                        + startup.decode(errors='replace')
                    )
                    time.sleep(min(0.01, remaining))
                    continue
            startup += chunk
    finally:
        if owned is not None:
            owned.close()
