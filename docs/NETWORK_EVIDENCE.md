# Network evidence (X1/X3): packets, TLS and mitmproxy flows

Status: slices X1 and X3 of the external-evidence design, 2026-10-14. Offline
only: xodb reads capture files you already have; it does not capture traffic,
needs no privilege and adds no helper.

## Try it

| Command | What you get |
|---|---|
| `xodb --open-pcap trace.pcapng` | The stream in the profile view's timeline as a `net` lane on the file's own clock; MCP tools below. |
| `xodb --open-pcap trace.pcapng --open-capture run.xoc` | The lane on the capture's clock (when the archive has clock pairs), and `correlate` joins packets to the captured process. |
| `xodb --open-pcap trace.pcapng --tls-key-log ssl.keys` | A second, derived evidence stream containing authenticated TLS 1.2/1.3 records. Plaintext is returned only on an explicit raw query by the direct observer that opened the files. |
| `xodb --open-mitmproxy flows.mitm` | HTTP request/response metadata and content references from a mitmproxy flow dump. Other flow types remain visible as `unsupported_flow`. |
| `xodb --headless --mcp --open-pcap trace.pcap --open-capture run.xoc` | The same for an agent: `list_streams`, `query_stream`, `correlate`. |
| `python3 -B tests/network-evidence.py [--gui]` | The end-to-end demo: two owned loopback peers, a real capture archive, a synthetic pcapng of their traffic, correlation with basis `exact` for the exchange inside the capture and `sampled` for the one before it. |
| `python3 -B tests/private-network-evidence.py` | Runtime-only owned TLS 1.2/1.3 loopback sessions and a synthetic mitmproxy flow; checks authentication, import, access control, redaction and log privacy. |

`--open-pcap` combines only with `--open-capture` (no live target, core, imported
profile or remote session).

`--tls-key-log` requires `--open-pcap`. `--open-mitmproxy` opens its own offline
stream and does not combine with another target or evidence file.

## TLS key-log decryption

The key log uses the NSS `SSLKEYLOGFILE` text format. xodb consumes it while
opening the capture, wipes the input and parsed secrets, and retains only
authenticated plaintext records plus their hashes and packet provenance. It
does not store the key log in an archive or print its path, secrets or
plaintext.

| Version | Key-log labels | Cipher suites |
|---|---|---|
| TLS 1.3 | `CLIENT_HANDSHAKE_TRAFFIC_SECRET`, `SERVER_HANDSHAKE_TRAFFIC_SECRET`, `CLIENT_TRAFFIC_SECRET_0`, `SERVER_TRAFFIC_SECRET_0` | AES-128-GCM/SHA-256, AES-256-GCM/SHA-384, ChaCha20-Poly1305/SHA-256 |
| TLS 1.2 | `CLIENT_RANDOM` | RSA/ECDHE AES-128-GCM/SHA-256, RSA/ECDHE AES-256-GCM/SHA-384, ECDHE/DHE ChaCha20-Poly1305/SHA-256 |

TCP is reassembled independently in each direction. Each derived record names
its flow, direction, TLS version, cipher, epoch, sequence number, source packet
and source timestamp. AEAD authentication failure is retained as
`authentication_failed`; missing secrets, unsupported suites, incomplete
handshakes and reassembly gaps are explicit session states.

The capture must contain the ClientHello and ServerHello and contiguous TCP
bytes from the beginning of each TLS direction. This slice does not decrypt
TLS 1.3 0-RTT data, post-`KeyUpdate` traffic, CBC suites, DTLS, QUIC or
mid-stream captures. Reassembly and retained plaintext are each capped at 64
MiB; a TLS record is capped at 18,432 bytes and a key log at 16 MiB/16,384
recognized entries. Plaintext beyond the retention cap keeps its authenticated
length and SHA-256 with `retained=false`.

## mitmproxy flow import

The reader accepts mitmproxy's concatenated tnetstring flow records, including
the current version-21 HTTP field layout. It exposes request/response timing,
method, URL components, status, headers, content length and SHA-256. HTTP body
bytes are borrowed from the owned file buffer and erased with that buffer at
shutdown. TCP, WebSocket, DNS and other flow types remain in the stream as
typed `unsupported_flow` records.

The parser stops safely after earlier complete flows on a truncated or corrupt
tail. It caps the file at the common 256 MiB input limit, one million flows,
64 levels of nesting, 65,536 tnetstring nodes per flow and 256 retained headers
per message. It does not decompress HTTP content or migrate older mitmproxy
layouts whose field names differ.

## What is read

| Format | Read | Notes |
|---|---|---|
| pcap | both byte orders; microsecond (`a1b2c3d4`) and nanosecond (`a1b23c4d`) magic; `thiszone` | one interface, link type from the header |
| pcapng SHB | both byte orders, several sections | a new section resets interface numbering |
| pcapng IDB | link type, snaplen, `if_name`, `if_tsresol` (10^-n and 2^-n), `if_tsoffset` | up to 1,024 interfaces |
| pcapng EPB | interface, timestamp, captured/original length, `epb_dropcount` | |
| pcapng SPB | original length, data | no timestamp: such records stay off any time axis |
| pcapng ISB | `isb_ifrecv`, `isb_ifdrop`, `isb_osdrop` (latest wins) | loss counters per interface |
| pcapng PB (obsolete) | as EPB, with its 16-bit drop count | |
| other blocks (NRB, DSB, custom) | counted as `unknown_blocks`, skipped | names and secrets are not interpreted |

Records keep their packet bytes in place: each record is an offset and length
into the file, returned with `query_stream` (`raw`, and `raw_hex` with
`include_raw`). Nothing is copied or rewritten.

| Fault | Result |
|---|---|
| file ends inside a header or block | `file.stop = truncated` with the byte offset; earlier records kept |
| bad block length, trailer, byte-order magic, version, captured length past the block | `file.stop = corrupt` with the offset; earlier records kept |
| packet block naming a missing interface | counted in `orphan_records`, skipped |
| option running past its block | counted in `bad_options`; rest of that block's options ignored |
| more than 4,194,304 records | `file.stop = limit` |
| bytes that are not pcap/pcapng | the open fails: `NotACapture` |

Files are read whole, up to 256 MiB (the archive reader's limit). Memory per
record is fixed (record, summary, flow id); there is no per-packet allocation,
but it adds up: a 200 MiB file of tiny packets (stopped at the record limit)
peaks near 850 MiB resident; 200 MiB of 1400-byte frames near 250 MiB.

## What is decoded

Decoder `xodb-net-summary` version 1, pure functions over captured bytes. No
reassembly, no checksum verification, no payload parsing.

| Layer | Decoded | Typed reasons when it stops |
|---|---|---|
| Link | Ethernet (1), up to two 802.1Q/802.1ad tags; Linux cooked SLL (113) and SLL2 (276); BSD loopback (0); raw IP (101, 228, 229) | `unknown_link_type`, `truncated_link`, `unsupported_ethertype` (ARP and others), `vlan_depth` |
| IPv4 | addresses, protocol, TTL, total length, fragment flags; Ethernet padding excluded | `truncated_network`, `bad_ip_version`, `bad_ip_header`, `non_first_fragment` |
| IPv6 | addresses, hop limit, payload length; hop-by-hop, routing, fragment, destination options, AH, mobility headers, at most 8 | `extension_header_limit`, `truncated_network`, `non_first_fragment` |
| TCP | ports, flags, seq/ack, window, payload length declared and captured | `truncated_transport`, `bad_transport_header` |
| UDP | ports, payload length | same |
| ICMP / ICMPv6 | type, code | `truncated_transport` |
| other IP protocols | protocol number | `unsupported_protocol` |

A record whose reason is not `none` is **undecoded**: it stays in the stream,
is listed by `query_stream undecoded=true`, and is drawn as an amber cap in the
lane. Each record with a TCP/UDP/ICMP 5-tuple gets a `flow_id`; both directions
share one flow (65,536 flows at most; more are counted in `flows_dropped`).

## Clocks

| Stream | Declared clock | Shown as |
|---|---|---|
| pcap / pcapng | CLOCK_REALTIME of the host that wrote the file (ns since the Unix epoch, after `if_tsresol`/`if_tsoffset`) | `time.stream_ns` |
| capture archive | CLOCK_MONOTONIC of the recording host | `time.capture_ns` (since capture start), `time.monotonic_ns` |

The mapping between them comes only from evidence: the archive's ECTX section
holds bracketed pairs (monotonic, realtime, monotonic) read by the collector at
capture start and stop.

| Mapping | When | Uncertainty |
|---|---|---|
| `aligned` | the archive has at least one pair | half the narrowest bracket, plus the largest disagreement between the pairs (a realtime step or slew during the capture widens it) |
| `unaligned` | no `--open-capture`, or an archive without ECTX | records keep only their stream time; they are never placed on the capture's axis and are counted as `off_axis` in the lane |

The pcap writer's realtime must be the same host's clock as the capture's. A
file from another host, or one whose clock stepped between the pairs and the
packets in a way the pairs do not show, is not detected. With one pair (a
capture still collecting when saved), drift is not measured.

## What is correlated

The collector step (`src/profile/net_context.zig`) runs for local targets at
capture start and stop. It reads `/proc/PID/fd` for `socket:[inode]` links and
the target's network namespace tables `/proc/PID/net/{tcp,tcp6,udp,udp6}`, and
keeps the rows whose inode the target holds: pid, fd, inode, protocol, local and
remote address and port, state, plus the process `comm`. Remote targets
(`--runtime-agent`/`--runtime-ssh`) record nothing: their `/proc` is elsewhere.

`correlate(record)` joins the record's 5-tuple to those rows:

| Basis | Means |
|---|---|
| `exact` | protocol and both endpoints equal a connected socket the process held, and the packet's aligned time is bracketed by the nearest tables before and after it that both show that same socket (same inode and tuple), or lies within the clock uncertainty of a table that does |
| `sampled` | the same 5-tuple match, but no tables holding that socket bracket the packet: it was seen only at start or only at stop (opened or closed during the capture), the packet is outside the tables, or the stream is unaligned. Another socket or process may have held the tuple then |
| `inferred` | only the local endpoint matched a listening or unconnected socket (wildcard addresses match any local address); the remote end is not part of its identity |
| `none` | no row matches, the record has no TCP/UDP 5-tuple, or there is no capture context; `reason` says which |

The reply names the process (pid, comm), the socket (fd, inode, endpoints,
state), which table matched (`start` or `stop`, with its monotonic time), and
the direction (`outbound` when the packet's source is the socket's local end).
`thread` is always null in X1: socket tables name processes, not threads.

## MCP

| Tool | Arguments | Returns |
|---|---|---|
| `list_streams` | none | every opened or derived stream, its decoder/version, format, bounds and stop state; network interfaces/clock/context, TLS sessions or mitmproxy flow counts as applicable |
| `query_stream` | common: `stream_id`, time bounds, `include_raw`, `start`, `limit` (1–256); network: clock/flow/interface/protocol/port/undecoded/flows; TLS: flow/direction/content type/state; mitmproxy: method/status/undecoded | records in source order and `next` to continue; metadata and content SHA-256 by default, explicit bytes only when access permits |
| `correlate` | `stream_id`, `record` | network records as above; a TLS record maps through its source packet; mitmproxy files have no packet/socket correlation |

All three tools are read-only and callable in every agent scope. Decrypted TLS
bytes and mitmproxy headers, URLs and body bytes are private evidence: only the
direct `observe`-scope MCP connection of the xodb process that opened the file
can receive them. A controller, shared-session peer or `--listen` TCP client
receives counts, public protocol metadata and content hashes; an explicit
private-payload request, or a mitmproxy `method` filter, is refused. `--redact` also refuses every `include_raw` request, including packet
bytes and decrypted content, and withholds mitmproxy headers and URL fields.

## Archive storage (format 2.9)

Local captures write an optional, ignorable `ECTX` section after the others and
set minor version 9; captures without it keep their previous minor. Older
readers skip the section and stay correct. See
[M2_ARCHIVE_FORMAT.md](M2_ARCHIVE_FORMAT.md#evidence-context-ectx-29). The pcap
file itself is not copied into the archive in X1: keep it beside the `.xoc`.

## Limits

| Limit | Why / next |
|---|---|
| Socket tables are sampled at start and stop only | a connection opened and closed between them is not seen; `sampled`/`none` say so. Exact per-I/O attribution (thread, syscall) needs the fd-flow/syscall join (X2). |
| Only the captured process | children and other local peers are not in the tables. |
| The base network stream has no general-purpose TCP reassembly, request/response, HTTP or DNS decoder | X3 reassembles only TLS flows for record decryption; the general decoders belong to X2. |
| No live capture | X2: an owned dumpcap/tcpdump child. |
| Streams are not stored inside the archive | a later slice can attach them as an optional section the way FRAM is attached. |
| GUI: one lane in the profile view's timeline, no packet table | records are queried through MCP. Selecting a time range in the timeline does not filter the stream. |

## Privacy

Captured traffic is private. Test fixtures are synthetic: `tests/network-evidence.py`
writes its pcapng from the endpoints of two owned loopback peers at run time,
and the `pcap-magic` gate step fails if any tracked file starts with a pcap or
pcapng magic number. Socket tables in an archive name the target's endpoints,
including remote addresses and ports, for every local capture; share archives
with that in mind, or save them with `--redact`: addresses outside loopback and
the documentation ranges are then stored as tags under a per-archive key that
is not stored (ECTX schema 2), process names are masked, and those sockets
match no packet. Under `--redact`, MCP `correlate`, `query_stream` and
`list_streams` show such addresses as per-session tags (`ip-` and 8 hex
digits), and `include_raw` is refused (`RawPayloadRedacted`). See
[GUIDE.md](GUIDE.md#redaction).

The X3 test generates its certificate, private key, TLS key
log, random plaintext, packet capture and mitmproxy dump only in its runtime
work directory. None is a source fixture or gate artifact.

## Layout

| File | Layer | Role |
|---|---|---|
| `src/evidence/pcap.zig` | evidence | reader |
| `src/evidence/decode.zig` | evidence | link/network/transport summaries, flow keys |
| `src/evidence/clock.zig` | evidence | clock domains, mapping with uncertainty |
| `src/evidence/sockets.zig` | evidence | `/proc/net` parser, ECTX encoding, the join |
| `src/evidence/stream.zig` | evidence | the stream: records, summaries, flows, loss, queries |
| `src/evidence/tls.zig` | evidence | bounded TCP reassembly, key-log parsing, TLS 1.2/1.3 authenticated record derivation |
| `src/evidence/mitm.zig` | evidence | bounded mitmproxy tnetstring flow reader |
| `src/profile/net_context.zig` | profile | the collector step (reads `/proc`) |
| `src/mcp/evidence.zig`, `evidence_tools.json` | mcp | the three tools |
| `src/model/profile_timeline.zig`, `src/ui/timeline.zig` | model, ui | the lane |

`tools/deps/rules` has `only evidence-leaf evidence -> common`: the evidence
layer imports nothing of xodb's (no session, frontends or engine C).
