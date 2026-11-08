"""Bounded private-display OCR evidence beside the release step's log.

The runner gives each attempt its own directory. Keep the latest pair before
the caller can assert, and freeze the first explicit failure even if the test
continues. Neither test work-dir cleanup nor a retry can remove that pair.
"""
import os
from pathlib import Path
import shutil
import sys


def record(frame, text):
    directory = os.environ.get('XODB_TEST_LOG_DIR')
    if not directory:
        return
    try:
        latest = Path(directory) / 'ocr-latest'
        latest.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(frame, latest / 'frame.png')
        (latest / 'ocr.txt').write_text(text)
        (latest / 'source.txt').write_text(Path(frame).name + '\n')
    except OSError as exc:
        print(f'GUI evidence capture failed: {exc}', file=sys.stderr, flush=True)


def first_failure():
    directory = os.environ.get('XODB_TEST_LOG_DIR')
    if not directory:
        return
    latest = Path(directory) / 'ocr-latest'
    first = Path(directory) / 'ocr-first-failure'
    if not latest.is_dir() or first.exists():
        return
    try:
        shutil.copytree(latest, first)
    except OSError as exc:
        print(f'GUI first-failure capture failed: {exc}', file=sys.stderr, flush=True)
