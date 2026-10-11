"""Children of a process, whichever of its threads started them."""
from pathlib import Path


def children(pid):
    """Linux lists a child under the task that spawned it. A remote session's
    transport is started by the owner thread, not by the process leader."""
    found = set()
    try:
        tasks = list(Path(f'/proc/{pid}/task').iterdir())
    except OSError:
        return []
    for task in tasks:
        try:
            found.update(int(value) for value in (task/'children').read_text().split())
        except OSError:
            pass
    return sorted(found)
