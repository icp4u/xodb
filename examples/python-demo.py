#!/usr/bin/env python3
# Demo workload for scripts/demo-python: nested functions that keep storing
# a fresh list into a dict. `table[key] = items` is a dict store
# (STORE_SUBSCR_DICT), which calls _PyDict_SetItem_Take2 on every iteration.
import os


def record(table, key, items):
    table[key] = items


def tick(table, round):
    items = [round, 2**70 + round, 3.25, "héllo", b"raw\x00bytes", None, True, ("t", 1)]
    record(table, "answer", items)


table = {"greeting": "hi"}
print(os.getpid(), flush=True)
round = 0
while True:
    tick(table, round)
    round += 1
