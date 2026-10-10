# Owned CPython fixture for tests/python-image-budget.py. Loads the shared
# objects named on the command line, prints the address of one function in
# each, then waits in a named frame for a line on stdin.
import ctypes
import json
import sys

LIBRARIES = [ctypes.CDLL(path) for path in sys.argv[1:]]


def leaf(token):
    held = token * 2
    sys.stdin.readline()
    return held


print(json.dumps([ctypes.cast(library.xodb_pad, ctypes.c_void_p).value for library in LIBRARIES]), flush=True)
leaf(21)
