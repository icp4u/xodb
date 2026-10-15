# Persistent Ghidra sidecar protocol

The Ghidra producer is one headless JVM per user. It imports images into a
private Ghidra project, keeps that project across xodb sessions, and returns
immutable function documents. xodb holds no Ghidra objects. The native
no-JVM x86-64 ELF producer remains available when the sidecar is not selected.

## Starting it

Set `GHIDRA_HOME` to an installed Ghidra directory and put a JDK (`java` and
`javac`) on `PATH`, or set `JAVA_HOME`. By default xodb starts the sidecar in
a background session during its own startup, through the same script used manually:

```sh
scripts/ghidra-sidecar start
scripts/ghidra-sidecar status
scripts/ghidra-sidecar stop
```

The socket is `$XDG_RUNTIME_DIR/.xodb.ghidra.s`. If `XDG_RUNTIME_DIR` is
unset, it is `${TMPDIR:-/tmp}/xodb-UID/.xodb.ghidra.s`. Every xodb owned by
the user shares it. The JVM outlives the xodb that starts it.

Start takes a lock beside the socket. An expected, healthy `hello` makes start
idempotent. A stale socket is replaced. An answering incompatible sidecar is
asked to shut down and replaced once. xodb checks the replacement once and
then reports the expected and observed protocol in the pseudo-C pane and MCP
job failure. A recorded JVM is signalled only when its process belongs to the
current uid and its command line names `XodbGhidraSidecar`.

Configuration:

| Variable | Default | Meaning |
|---|---:|---|
| `XODB_GHIDRA_HOME` | `GHIDRA_HOME` | Ghidra installation used by the starter |
| `XODB_GHIDRA_SIDECAR` | repository `scripts/ghidra-sidecar` | starter path used by xodb; `off` keeps xodb on the native worker even when a sidecar is running |
| `XODB_GHIDRA_SOCKET` | runtime path above | socket override, useful for tests |
| `XODB_GHIDRA_CACHE` | `$XDG_CACHE_HOME/xodb/ghidra-sidecar` | classes and private Ghidra project |
| `XODB_GHIDRA_STATE` | `$XDG_STATE_HOME/xodb/ghidra-sidecar` | log and recorded pid |
| `XODB_GHIDRA_XMS` | `128m` | initial Java heap |
| `XODB_GHIDRA_XMX` | `4g` | Java heap ceiling |
| `XODB_GHIDRA_SOFT_MAX` | `768m` | ZGC soft heap target |
| `XODB_GHIDRA_JAVA_OPTS` | empty | extra JVM options, split on spaces, placed after the defaults (`-XX:+UseZGC -XX:+ZGenerational -XX:ZCollectionInterval=60 -XX:ZUncommitDelay=60`) |
| `XODB_GHIDRA_MAX_IMAGES` | `64` | persistent project image safety limit; foreground imports evict the least-recently-used image |
| `XODB_GHIDRA_MAX_DOCUMENTS` | `1024` | in-memory function document limit |
| `XODB_GHIDRA_MAX_OPEN_PROGRAMS` | `8` | open-program/decompiler pool bound |
| `XODB_GHIDRA_CACHE_BYTES` | `2147483648` | persistent project byte limit; least-recently-used images are evicted |
| `XODB_GHIDRA_IDLE` | `30` | idle-exit minutes; fractional values are accepted and `0` disables idle exit |
| `XODB_GHIDRA_START_TIMEOUT` | `45` | starter wait in seconds |

Set `decompiler.prestart` to `false` in preferences, or pass
`--no-ghidra-prestart`, to keep the JVM idle until the first pseudo-C request.
`XODB_GHIDRA_SIDECAR=off` still disables the sidecar completely. Once a target
architecture is known, xodb imports the executable and newly seen executable
mappings in a bounded, smallest-first background queue. At each stop it warms
stack functions, then their direct callees, then user breakpoint functions,
with a hard 16-function bound. This real-program warm-ahead replaces the old
throwaway `prime` request, which measured no faster after decompiler reuse. Resume and an interactive analysis cancel
this work before it can delay the debugger. A cancelled import starts again
from nothing, so its path waits at least 30 seconds before another eager
attempt; an explicit request remains immediate. Background imports stop at half of
`XODB_GHIDRA_MAX_IMAGES`; the other half is kept for images you ask about.

The cache is private and safe to delete while the sidecar is stopped. The
project is bounded by `XODB_GHIDRA_CACHE_BYTES` and the image safety limit;
foreground imports evict least-recently-used project images, close their pooled
decompilers, and drop their documents. In-memory documents retain their own
count bound. The main executable is always eligible for eager import; libraries
over `decompiler.eager_library_bytes` (1 MiB by default, so libc is imported when you first stop in it or ask for pseudo-C there) wait for an explicit
stop or pseudo-C request. stdout and stderr go to `sidecar.log` under the state
directory; when xodb starts the sidecar, the starter's own errors (no Ghidra,
no JDK, a compile failure) go there too, and the pane's failure text names
the file. `status` reports heap use, heap ceiling, open images, queued jobs, open pooled
programs, project bytes, idle time, connected clients, the configured limits,
and pid. One `DecompInterface` is retained per pooled program, so uncached
functions do not spawn a fresh native decompiler. Foreground open/decompile
requests pre-empt background imports and warm decompiles across clients.

## Transport and trust boundary

The socket is a Unix stream socket with exact mode `0600`. xodb checks the
socket owner and `SO_PEERCRED` uid before sending an image path. `hello.uid`
must also equal the current uid. The starter refuses to remove or stop an
endpoint owned by another uid. File permissions are the access check.

Each request is one UTF-8 JSON object followed by `\n`, at most 1 MiB. It has
an `id`, a `verb`, and `deadline_ms`. Replies repeat `id` and have one of:

```json
{"id":"r1","state":"pending","job":"open:SHA256","progress":"analyzing"}
{"id":"r1","state":"ready"}
{"id":"r1","state":"failed","code":"image_unreadable","detail":"..."}
```

A ready document reply adds `payload_length`. The JSON line is followed by an
unsigned 8-byte big-endian length and exactly that many binary payload bytes.
The two lengths must agree. Lines are capped at 1 MiB and documents at 64 MiB.
A closed or truncated connection is a typed `sidecar_died` or
`sidecar_io_failed` job failure; xodb and the debugger remain usable.

The server accepts multiple requests on a connection. Each xodb session owns
one validated idle connection for its lifetime, while requests use independent
connections so a failed exchange cannot desynchronise later work. The held
connection carries no requests; it records that a live xodb session owns use
of the shared JVM and prevents idle exit.

## Verbs

`hello` has no verb-specific fields. A usable reply is `ready` and contains
protocol `1`, schema `1`, producer `ghidra-jvm-sidecar-0.1.6`, Ghidra version,
uid, `healthy: true`, log path, and these required capabilities:
`open_image`, `decompile`, `cancel`, `status`, `shutdown`, `xsg`, and
`pseudocode`. It also advertises `prime`, variables, types, function index, and the
reserved hints direction.

`prime` remains as a compatibility verb for older clients. Current xodb warms
real functions after the target architecture and stack are known, because the
throwaway-program prime did not improve first-use latency once decompilers were
pooled. `open_image` carries `path` and lowercase `sha256`. It hashes the file before
import. The operation is idempotent by SHA-256 and returns progress through
`hashing`, `importing`, and `analyzing`. A caller may also supply a debug
companion path and SHA-256; the sidecar verifies both files and keys that
analysis cache entry by both identities. Analysis keeps format/debug,
function, reference, string, switch, stack, and demangling work; analyzers
unrelated to the exported function document are disabled.

`decompile` carries the same `path` and `sha256`, canonical hexadecimal
`entry` and `size`, optional GNU `build_id`, and `options` (`default` today).
An image-only request uses `symbol` in place of `entry` and `size`; Ghidra
resolves that name in the imported project and refuses an absent or ambiguous
function.
The entry may be the start or an address inside the Ghidra function. Every
address in a request or a document is a link address: the runtime address
minus the module's load bias. The sidecar imports an ELF at its linked base,
not at Ghidra's default base for position-independent code, so a
position-independent executable or a shared library answers exactly as a
fixed-address build does. A cached import found at another base (written
before producer 0.1.1) is replaced on its next `open_image`. Documents
are immutable and cached by image SHA-256, requested entry or symbol, options,
and producer version; the document and artifact identity carry the resolved
function entry.

`status` without `job` returns process health and resource counts. With `job`
it returns that operation's `pending`, `ready`, or `failed` state and progress;
a ready decompile status carries its framed document.

`cancel` carries `job`. It cancels the analyzer/decompiler monitor and the
queued future. Cancellation is reported as code `cancelled`. `shutdown`
acknowledges first and then closes the listener and project. xodb never sends
shutdown merely because an xodb session exits.

## Lifetime

The JVM exits cleanly after 30 minutes with no connected client and no request.
Set `XODB_GHIDRA_IDLE` to a number of minutes; fractional values are accepted
for short-lived private runs, and `0` disables idle exit. An open connection
keeps the sidecar alive regardless of request traffic. Every xodb session
opens and validates one idle hold connection and closes it during session
teardown; a stopped or running session therefore keeps the shared JVM warm.
`status` reports `idle_seconds`, `idle_limit_seconds`, and
`clients_connected`, and the log records why the JVM stopped
(`lifetime: stopping: idle`, `endpoint_replaced` or `shutdown`).

The sidecar also checks its Unix endpoint periodically. If the path disappears
or its inode is replaced, the JVM closes its project and exits. Shutdown only
unlinks the inode the process originally bound, so a replacement endpoint is
left alone. These rules cover abandoned test/runtime directories without
changing the persistent project cache; a later start reuses the imported
programs.

`hints` is reserved and currently returns code `reserved`. A later schema may
carry debugger-observed indirect targets, runtime/DWARF/PDB types and bounds,
and user renames into Ghidra. No such facts flow into this milestone.

## Function document

The framed payload is `xodb.ghidra.function_graph` schema `0.4.1`. It contains
the graph consumed by xsg and the pseudo-C document consumed by the D pane:

- final high-p-code SSA, blocks, edges, calls, and exact token-to-op/PC links;
- decoded instruction bytes, mnemonics, raw p-code, and high-op links used to
  account for no-effect landing pads that high p-code omits;
- pseudo-C text and positioned syntax tokens;
- variables with name, type and an ordered list of register/stack/temp pieces,
  each with its value bit offset, register/subregister location or signed CFA
  offset, and a common PC range. For a register the range is a proof
  that a stop PC inside it finds the value in that register: straight-line
  code from the function entry (a parameter) or from just after the
  instruction that wrote the register (a local), ending at the first write to
  the register, call, branch, user-defined p-code op or jump target. An
  unproven register variable has an empty range. Stack parameters are proven
  from entry; a stack local starts only at an exact address-tied defining store,
  and its range ends at the first call, branch, join, opaque instruction or
  memory write. Every piece must be proven or the variable has an empty range;
- referenced types, function prototype, and calling convention;
- function bounds, direct callees, callers, and referenced strings.

xodb admits a document only when its image SHA-256, optional GNU build-id, and
function entry exactly match the stopped session request. The sidecar and
native worker use separate producer cache keys. The D pane and
`decompile_function` name the selected producer; `get_decomp_mapping` reads
the same retained artifact. When the adapter proves that a short entry gap is
entirely made of an exact whitelisted landing pad, its bytes map to the first
exported code line in both directions and are labelled `entry_pad: true`.
Other gaps remain unmapped.


## Pseudo-C behavior

The D pane keeps pseudo-C text even when graph admission fails and shows the
one-line graph reason; graph-only queries return `graph_unavailable`. If a
selected sidecar cannot start on x86-64, the same request falls back to the
configured native worker and the pane names that producer. Register-backed
sidecar variables and CFA-relative stack pieces are overlaid from the stopped
frame only inside their exported PC range; stack pieces only in the innermost
frame. A value split over several pieces shows no live value yet: the 0.1.6
export orders x86-64 aggregate pieces wrongly. `[` and `]` scroll
long pseudo-C lines horizontally.

## Image-only sessions

`xodb --decompile FILE [--function NAME]` prints pseudo-C without launching or
attaching to a process. xodb copies the regular input into a private bounded
snapshot, hashes that exact copy, and removes it after the sidecar has imported
and decompiled the requested function. An adjacent same-stem PDB is copied into
the private snapshot under its original name and a 64 MiB bound; its hash is
verified by the sidecar and forms part of the cached-analysis identity. With no function name, the sidecar
chooses `main` or `entry`; ambiguous or absent names are typed failures. This
path supports every format Ghidra can import and is gated with owned x86-64 PE
and arm64 Mach-O fixtures. It has no target generation, runtime bias, frame,
register or live-value overlay.
