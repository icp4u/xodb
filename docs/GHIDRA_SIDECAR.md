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
| `XODB_GHIDRA_MAX_IMAGES` | `64` | persistent project image limit |
| `XODB_GHIDRA_MAX_DOCUMENTS` | `1024` | in-memory function document limit |
| `XODB_GHIDRA_START_TIMEOUT` | `45` | starter wait in seconds |

Set `decompiler.prestart` to `false` in preferences, or pass
`--no-ghidra-prestart`, to keep the JVM idle until the first pseudo-C request.
`XODB_GHIDRA_SIDECAR=off` still disables the sidecar completely. Once a target
architecture is known, xodb sends `prime` before opening an image. It then
imports the executable and newly seen executable mappings in a bounded,
smallest-first background queue. Resume and an interactive analysis cancel
this work before it can delay the debugger. A cancelled import starts again
from nothing, so a library whose import was twice cancelled after seconds of
work is left to an explicit request. Background imports stop at half of
`XODB_GHIDRA_MAX_IMAGES`; the other half is kept for images you ask about.

The cache is private, bounded by image and document counts, and safe to delete
while the sidecar is stopped. Reaching a limit returns `cache_full`; raise the
matching limit, restart for the in-memory document cache, or delete the
stopped private cache. stdout and stderr go to `sidecar.log` under the state
directory; when xodb starts the sidecar, the starter's own errors (no Ghidra,
no JDK, a compile failure) go there too, and the pane's failure text names
the file. `status` reports heap use, heap ceiling, open images, queued jobs,
the configured limits, and pid. The native Ghidra `decompile` child is outside
the Java heap.

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

The server accepts multiple requests on a connection. The current xodb client
uses a fresh connection per request so a failed client cannot desynchronise a
later exchange.

## Verbs

`hello` has no verb-specific fields. A usable reply is `ready` and contains
protocol `1`, schema `1`, producer `ghidra-jvm-sidecar-0.1.2`, Ghidra version,
uid, `healthy: true`, log path, and these required capabilities:
`open_image`, `decompile`, `cancel`, `status`, `shutdown`, `xsg`, and
`pseudocode`. It also advertises `prime`, variables, types, function index, and the
reserved hints direction.

`prime` carries one of xodb's architecture names. It loads that processor
language and decompiles a tiny scratch function without opening a target
image. `open_image` carries `path` and lowercase `sha256`. It hashes the file before
import. The operation is idempotent by SHA-256 and returns progress through
`hashing`, `importing`, and `analyzing`. Format loaders also find adjacent
owned debug companions such as a PDB or dSYM. Analysis keeps format/debug,
function, reference, string, switch, stack, and demangling work; analyzers
unrelated to the exported function document are disabled.

`decompile` carries the same `path` and `sha256`, canonical hexadecimal
`entry` and `size`, optional GNU `build_id`, and `options` (`default` today).
The entry may be the start or an address inside the Ghidra function. Every
address in a request or a document is a link address: the runtime address
minus the module's load bias. The sidecar imports an ELF at its linked base,
not at Ghidra's default base for position-independent code, so a
position-independent executable or a shared library answers exactly as a
fixed-address build does. A cached import found at another base (written
before producer 0.1.1) is replaced on its next `open_image`. Documents
are immutable and cached by image SHA-256, resolved function entry, options,
and producer version.

`status` without `job` returns process health and resource counts. With `job`
it returns that operation's `pending`, `ready`, or `failed` state and progress;
a ready decompile status carries its framed document.

`cancel` carries `job`. It cancels the analyzer/decompiler monitor and the
queued future. Cancellation is reported as code `cancelled`. `shutdown`
acknowledges first and then closes the listener and project. xodb never sends
shutdown merely because an xodb session exits.

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
- variables with name, type, register/stack/temp storage, and PC range;
- referenced types, function prototype, and calling convention;
- function bounds, direct callees, callers, and referenced strings.

xodb admits a document only when its image SHA-256, optional GNU build-id, and
function entry exactly match the stopped session request. The sidecar and
native worker use separate producer cache keys. The D pane and
`decompile_function` name the selected producer; `get_decomp_mapping` reads
the same retained artifact.
