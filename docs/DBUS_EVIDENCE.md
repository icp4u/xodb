# Offline D-Bus evidence

`--open-pcap FILE` reads `dbus-monitor --pcap` output with
`LINKTYPE_DBUS` (231). xodb never joins or monitors a live bus. The pcap source
remains stream 1 and decoded messages appear as a derived `dbus` stream from
`list_streams`.

The decoder reports method calls, method returns, errors and signals; flags and
serials; sender, destination, object path, interface and member; and bounded
typed body arguments. It supports D-Bus basic values, arrays, structures,
dictionary entries and variants with explicit limits on message records,
pending calls, body-array bytes, argument nodes and nesting depth. A malformed
message remains addressable with an `undecoded` reason.

Calls and replies are paired by the caller's unique name plus serial and the
reply's destination plus `reply_serial`. Both records report their peer and
observed latency. Unmatched and capacity-dropped calls and orphan replies are
separate counters; pcap loss remains separate. A paired bus-daemon
`GetConnectionUnixProcessID` result establishes a unique-name-to-PID mapping.
`correlate` reports the process only from that captured authority; it does not
guess from a well-known name or current host state.

Bus names, object paths, all argument values (strings and numbers: byte
arrays carry file contents and Secret Service secrets) and raw messages are
private evidence. They are returned only to the direct observe-scope MCP connection
that opened the file; raw bytes additionally require `include_raw=true`.
Shared-session peers, controllers and network transports receive null private
fields and cannot request raw bytes. `--redact` applies the same refusal plus
the common output scrubber. The source stream applies this gate too, so it
cannot bypass the derived stream policy. Interface/member/error identifiers,
signatures and argument types/structure remain available for structural
analysis. Only a paired call to the bus daemon (`org.freedesktop.DBus`)
answered by the bus daemon establishes a PID; the same method answered by any
other peer is ignored.

To make a file explicitly, run `dbus-monitor --pcap` against the intended bus
and redirect its binary stdout to a new pcap file. D-Bus traffic can include
credentials, file paths, document contents and secrets; choose match rules and
retention accordingly. xodb provides no bus policy changes or privilege
helper.

The integration test starts its own private `dbus-daemon`, starts its own
`dbus-monitor --pcap`, and uses a scripted client on that bus. It checks known
calls, replies, errors, a signal, typed values and the client's known PID. No
desktop or system bus is contacted.
