"""Owned default-filter core with a live Python frame at the abort."""
import os


def core_marker():
    # Limit this fixture only: anonymous memory and ELF header pages, not all
    # file-backed pages. No machine-wide core policy is changed.
    with open('/proc/self/coredump_filter', 'w') as stream:
        stream.write('0x33')
    os.abort()


core_marker()
