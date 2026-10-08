# Shared debugger sessions

`--session-socket` lets several local MCP clients inspect one running xodb session.
One client at a time may hold a controller lease. The GUI and its human controls
remain available. Disconnecting a client leaves the xodb session and retained
inspection/capture evidence alive so another connection can read it.

## Start xodb once

From the checkout, after building:

```sh
SESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xodb-session.XXXXXX")"
chmod 700 "$SESSION_DIR"
export XODB_SESSION_SOCKET="$SESSION_DIR/session.sock"
printf 'Session socket: %s\n' "$XODB_SESSION_SOCKET"

./zig-out/bin/xodb --session-socket "$XODB_SESSION_SOCKET" \
  --agent-scope control --break change_value -- ./zig-out/bin/xodb-m1-fixture
```

This starts the GUI with the fixture stopped. Press **Space** to run to
`change_value`; **F8** changes agent scope and revokes any current lease. Clients
must claim again after scope changes, even if the new scope permits control.
Human controls do not need a lease. The GUI shows the controller and client
count; the action audit records the responsible `client_id`.

For a headless session, add `--headless` to the same command. A client can claim
control, obtain the current generation with `get_session`, then call `continue` with that generation to reach the breakpoint. Keep xodb running while clients connect and disconnect.
The socket is the MCP endpoint; do not add `--mcp`.

The socket path must be absolute, in a private directory. xodb creates a mode 0600
Unix socket and accepts clients with the same effective UID, up to eight
connections. Keep the directory mode 0700. These permissions grant access to the
shared debugger state; the controller lease coordinates clients within that
access. The bridge does not add a separate authentication protocol.

`--session-socket` conflicts with `--mcp`, `--listen`, `--connect` and `--ssh`.
`--runtime-agent` is allowed: it selects the C target backend while the local
socket still belongs to this xodb session. Scope is the upper bound set by
`--agent-scope observe|control|mutate`; a claim cannot raise it. Use `mutate` only
when the intended client needs register or memory writes.

Tool visibility and call authorization use the declared policy. Calling a hidden
state-changing tool directly is also refused: observe scope denies every
`readOnlyHint=false` tool, including watch creation/removal and metadata job
cancel/retry; control scope still denies memory/register mutations. This applies
to stdio MCP as well as shared sessions, including after the human presses F8.
Shared clients additionally need the controller lease for tools marked
`xodbSessionAccess=controller` or `mutator`, even when those tools only create
read-only inspection jobs. Only private headless stdio sessions keep the
read-only job exception. A GUI, session socket, or human scope change removes
that exception, including after F8 returns control to the human.

## Connect an MCP client

Use the stdio bridge as the MCP client's executable:

```sh
./scripts/session-client "$XODB_SESSION_SOCKET"
```

In another terminal, set `XODB_SESSION_SOCKET` to the exact path printed by the
server. Configure an MCP host with the absolute path to `scripts/session-client`
as its command and that socket path as its sole argument. Launch one bridge per
client connection; reconnecting creates a new client ID.

The bridge forwards newline-delimited MCP bytes unchanged. It does not parse
JSON, add framing, claim control or start another debugger. Buffers are bounded
to 256 KiB in each direction, with backpressure. Closing its stdin flushes queued
input and half-closes the socket; responses continue until the server closes.
A server disconnect drains received output and ends the bridge. Transport errors
go to stderr with a nonzero exit status; stdout contains only forwarded bytes.

## Inspect, claim and retain evidence

The following example uses the same MCP methods and result shape as
`tests/client.py`. Run it in a second terminal while the fixture is stopped. It
initializes a connection, claims control, retains registers and a stack, releases
control, reconnects, reads the same job, and then explicitly releases the job.
All debugger operations stay in the original xodb process.

```sh
python3 - <<'PYTHON'
import json, os, select, subprocess, time

socket_path = os.environ["XODB_SESSION_SOCKET"]
bridge = os.path.abspath("scripts/session-client")

class Peer:
    def __init__(self):
        self.p = subprocess.Popen([bridge, socket_path], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, bufsize=0)
        self.id = 0
        self.call("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "shared-session-example", "version": "1"}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def call(self, method, params):
        self.id += 1
        self.p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.id,
            "method": method, "params": params}) + "\n").encode())
        deadline = time.monotonic() + 5
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.p.stdout], [], [], remaining)[0], "MCP response timeout"
            line = self.p.stdout.readline()
            assert line, "MCP connection closed"
            reply = json.loads(line)
            if "id" not in reply:  # e.g. notifications/tools/list_changed
                continue
            assert reply.get("id") == self.id and "error" not in reply, reply
            return reply["result"]
    def tool(self, name, **arguments):
        result = self.call("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return result["structuredContent"]
    def claim(self):
        return self.tool("claim_session_control",
                         ttl_ms=30000)
    def close(self):
        self.p.stdin.close()
        assert self.p.wait(timeout=5) == 0

first = Peer()
try:
    state = first.tool("get_session")
    assert state["state"] == "stopped", state
    tid = next(t["tid"] for t in state["threads"] if t["state"] == "stopped")
    print("Connected:", first.tool("get_session_clients"))
    print("Claim:", first.claim())
    state = first.tool("get_session")
    job = first.tool("start_inspection", generation=state["generation"], tid=tid,
                     registers=True, stack=True)
    job_id = job["id"]
    deadline = time.monotonic() + 10
    while True:
        saved = first.tool("get_inspection", id=job_id, start=0, limit=2)
        if saved["state"] not in ("pending", "running"):
            break
        assert time.monotonic() < deadline, saved
        time.sleep(.02)
    assert saved["state"] == "completed", saved
    print("Retained job:", saved)
    first.tool("release_session_control")
finally:
    first.close()

second = Peer()
try:
    print("Reconnected:", second.tool("get_session_clients"))
    again = second.tool("get_inspection", id=job_id, start=0, limit=2)
    assert again["items"] == saved["items"]
    print("Same retained items:", again["items"])
    print("Policy events:", second.tool("get_session_events", after=0, limit=32))
    second.claim()
    second.tool("release_inspection", id=job_id)
    second.tool("release_session_control")
finally:
    second.close()
PYTHON
```

Expect a different `client_id` on reconnect and the same job ID and retained
items. Job creation/cancellation/release and other host-work operations require
the controller lease even where an MCP read-only hint describes their effect on
the target. Passive completed-evidence queries do not require control (derived-view limits are listed below). Completed evidence
is immutable; pending inspections still require held threads and may fail if the
target generation changes. Reconnection does not restart a cancelled or failed
job. Evidence lasts until explicit release or session close, subject to existing
job/capture limits.

The existing `get_registers` and `read_memory` tools read live stopped state;
use `start_inspection` / `get_inspection` when the bytes and context must survive
a later resume. Actions such as `continue` still take the latest target
`generation`. A lease does not bypass stale-generation or stopped-state checks.

## Controller and event tools

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `get_session_clients` | none | Returns your client ID, connected IDs, controller ID or null, remaining lease milliseconds, scope, journal sequence bounds and transient accept-error diagnostics. |
| `claim_session_control` | optional `ttl_ms` | Claim when free, or renew the same connection's claim. TTL 100–60000 ms; default 30000 ms. Independent of target generations, with no `process_id`. The legacy optional `generation` is validated but ignored. |
| `release_session_control` | none | Release your claim without stopping the debugger or deleting evidence. |
| `get_session_events` | `after` default 0; `limit` default 32, range 1–128 | Poll connection/lease policy events with a cursor. No push subscription. |

Only one connection owns control. A competing claim returns `ControllerBusy`;
an operation requiring an unheld lease returns `ControlLeaseRequired`. Expiry,
controller disconnect, release, or any GUI scope change revokes the claim.
Renew before expiry by calling `claim_session_control` again; there is no transferable lease token. A reconnect
must claim afresh. Revocation blocks new actions; it does not cancel accepted
execution commands or jobs, and does not automatically interrupt a running target.
Scope `observe` permits observation but does not grant a
controller lease; scope `control` still cannot perform mutate-only operations.

The journal retains 128 events. Rows contain `sequence`, `time_ns`, `client_id`
and `kind`: `connected`, `disconnected`, `acquired`, `released`, `expired` or
`scope_changed` or `revoked` (explicit human revocation, including two queued F8 toggles). The response includes `gap`, `oldest_available`,
`latest_sequence` and `next`. Set the next request's `after` to `next`. If `gap`
is true, history was overwritten: resynchronize with `get_session_clients`
and `get_session` rather than inferring missing lease transitions. A cursor in
the future is invalid. Policy events are polled; standard MCP notifications such as
`notifications/tools/list_changed` may still arrive between responses. The
journal reports policy events; use `query_events`
for target/debugger events. Journal cursors belong to this running service, so
reset them when connecting to a newly started xodb instance.

## Checks and shutdown

```sh
python3 tests/shared-sessions.py
```

That suite exercises the shared endpoint; ordinary stdio MCP remains a separate
mode. Closing a bridge releases that connection, not the shared session. Quit
xodb normally when done, then remove its empty private directory with
`rmdir "$SESSION_DIR"`. Do not unlink another session's active socket.

Some existing query tools also build or replace retained derived views. In a
shared session, `get_flamegraph`, `get_profile_frame`, `get_profile_stack`,
`get_imported_flamegraph`, `get_allocation_lifetimes` and
`get_allocation_flamegraph` therefore require the controller lease. Pure retained
evidence queries such as `get_inspection`, `get_observation_calls` and
`get_profile_samples` remain available to observers. Separating view creation
from passive paging is a follow-up; an MCP read-only hint does not grant control.

Each advertised tool carries an explicit `annotations.xodbSessionAccess` value:
`observer` for passive access, `controller` for lease-owned operations, `mutator`
for lease-owned operations requiring mutate scope, or `lease` for claim/release
operations with their own checks. Shared-session authorization uses this value;
an MCP `readOnlyHint` alone does not grant access. Missing classifications are
errors, and the tool-table test checks all definitions.

Temporary accept failures (`EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`, `EPROTO`) leave
the session and existing clients alive. `get_session_clients` reports
`accept_error_count` and `last_accept_errno`; the count saturates at the maximum
JSON-safe integer and the last errno remains available after recovery. These
failures do not add journal entries or emit repeated logs. A later pump retries
accepting connections after resources become available.

## Retained job ownership

`readOnlyHint` describes target effects, not authority over the human's retained
work. A GUI's observe-scope MCP client cannot capture/replace memory snapshots,
start/cancel searches, replace observation comparisons/associations, or occupy
profile/allocation view jobs. This includes direct calls to tools omitted from
`tools/list`, before and after F8 revokes control. Pure evidence/status reads
remain available. The controller can still perform those workflows.

Memory snapshots, searches, inspections, observation jobs and profile/allocation
work retain the identity that created them: human, private stdio client, or a
shared client ID. Replacement, eviction, cancellation and release require that
owner, the human, or current controller authority. A null stdio client ID never
means the human. Authority is checked at the action; a job does not retain an
expired controller grant. Shared-session dispatch still requires its lease.

A private headless stdio session has one client and retains its existing
read-only inspection workflow. Adding a session socket or GUI removes that
exception. Scope changes through the human controls latch shared-job protection;
returning to observe does not restore the private-session exception. Child
process sessions inherit the same policy. Frontends that queue calls must route
them through `Server.tool()` and carry this session policy to the owner.

When a reconstructed-stack view cannot replace an existing job because its
archive slot is busy or the requester lacks ownership, that request is
unavailable. It does not cache a reconstruction failure for the capture/filter;
a later permitted request can try again once the slot is available. Failures
from actually starting or running reconstruction still remain recorded for that
capture/filter. This does not bypass the controller policy for derived-view tools.

The static-analysis starter tools are declared controller operations because
they may launch bounded external work; cached/status/export observer tools keep
their classifications. This does not change the worker's implementation.
