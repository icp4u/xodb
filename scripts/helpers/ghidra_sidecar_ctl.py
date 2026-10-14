#!/usr/bin/env python3
"""Small control client for scripts/ghidra-sidecar.

The data plane lives in xodb.  This helper exists so the shell starter can
perform the same hello/status/shutdown exchange without another JVM command
line or a dependency on socat.
"""
import argparse
import json
import os
import socket
import sys
import time

PROTOCOL = 1
SCHEMA = 1
PRODUCER = "ghidra-jvm-sidecar-0.1.5"
# "prime" is advertised but not required, so an older running sidecar is kept.
CAPABILITIES = {"open_image", "decompile", "cancel", "status", "shutdown", "xsg", "pseudocode"}


def exchange(path, request, timeout):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(path)
        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        line = client.makefile("rb").readline(1024 * 1024 + 1)
    if not line or len(line) > 1024 * 1024:
        raise RuntimeError("missing or oversized sidecar reply")
    reply = json.loads(line)
    if not isinstance(reply, dict):
        raise RuntimeError("sidecar reply is not an object")
    return reply


def expected(reply):
    return (
        reply.get("state") == "ready"
        and reply.get("protocol") == PROTOCOL
        and reply.get("schema") == SCHEMA
        and reply.get("producer") == PRODUCER
        and reply.get("uid") == os.getuid()
        and reply.get("healthy") is True
        and CAPABILITIES <= set(reply.get("capabilities", ()))
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("hello", "status", "shutdown", "wait"))
    parser.add_argument("socket")
    parser.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()
    deadline = time.monotonic() + args.timeout
    while True:
        try:
            hello = exchange(args.socket, {"id": "starter-hello", "verb": "hello", "deadline_ms": 2000}, min(2.0, args.timeout))
            if args.action == "hello":
                print(json.dumps(hello, separators=(",", ":")))
                return 0 if expected(hello) else 3
            if args.action == "wait":
                if expected(hello):
                    print(json.dumps(hello, separators=(",", ":")))
                    return 0
            elif args.action == "status":
                if not expected(hello):
                    print(json.dumps(hello, separators=(",", ":")))
                    return 3
                status = exchange(args.socket, {"id": "starter-status", "verb": "status", "deadline_ms": 2000}, args.timeout)
                print(json.dumps(status, separators=(",", ":")))
                return 0 if status.get("state") == "ready" and status.get("healthy") is True else 3
            else:
                # Shutdown may replace an older protocol, but never a peer
                # claiming another uid.
                if hello.get("uid") != os.getuid():
                    print(json.dumps(hello, separators=(",", ":")))
                    return 3
                reply = exchange(args.socket, {"id": "starter-shutdown", "verb": "shutdown", "deadline_ms": 2000}, args.timeout)
                print(json.dumps(reply, separators=(",", ":")))
                return 0 if reply.get("state") == "ready" else 3
        except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
            if args.action != "wait" or time.monotonic() >= deadline:
                print(f"ghidra-sidecar: {error}", file=sys.stderr)
                return 2
        if time.monotonic() >= deadline:
            print("ghidra-sidecar: timed out waiting for the expected hello", file=sys.stderr)
            return 2
        time.sleep(0.05)


if __name__ == "__main__":
    raise SystemExit(main())
