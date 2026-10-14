# xodb protocol analysis and external observability roadmap

## objective

xodb should observe not only program state, but also the external protocols, buses, and operating-system interfaces that surround a running system.

the goal is to build a broad set of low-cost “eyes and ears” for software and hardware analysis, then correlate those observations with xodb’s debugger, profiler, trace, runtime, and agent models.

guiding principle:

> prefer cheap commodity capture hardware and open protocols, then add the intelligence in xodb.

a $20–$100 device that becomes substantially more useful through xodb is often preferable to requiring a $500–$2,000 commercial analyzer. commercial analyzers may still be supported where convenient, especially when they expose standard capture formats or APIs, but they should not define the architecture.

## architectural model

```text
network capture
usb sniffer
logic analyzer
can adapter
wayland/x11 proxy
tls key log
dbus/binder trace
kernel tracepoints
gpu api hooks
serial/jtag/swd
        │
        ▼
normalized protocol/event layer
        │
        ▼
xodb semantic model
        │
        ├─ process/thread
        ├─ stack/function/source
        ├─ timeline
        ├─ allocation/object
        ├─ syscall/io
        ├─ runtime state
        └─ agent evidence
```

the product value is not simply decoding packets. the value is correlation: this usb request happened while thread 7 was inside `device_write()`, 42 µs after an allocation and immediately before an interrupt.

## network

baseline:

- libpcap
- tcpdump
- wireshark-compatible pcap/pcapng
- raw packet capture
- interface metadata
- timestamps
- process/socket correlation where possible

xodb should correlate packets with owning process, fd/socket identity, thread, syscall, stack, source function, protocol decoder, and timeline events.

future features may include schema inference, field-level annotations, request/response matching, latency attribution, malformed packet diagnosis, and application/runtime correlation.

## tls and encrypted traffic

support two paths.

### key-log decryption

prefer session-key logging when the application is under user control.

examples:

- `SSLKEYLOGFILE`
- browser session secrets
- curl/libssl-compatible key logging
- wireshark-style tls decryption

advantages:

- preserves original network topology
- avoids mitm modification
- works with modern ephemeral key exchange
- easy to correlate with original pcap data

### active proxying

support tools such as mitmproxy where active interception is useful.

use cases:

- http/http2/websocket inspection
- request modification
- replay
- debugging clients that can trust a local ca

xodb should ingest structured proxy output rather than reimplementing a complete tls proxy unless needed.

## usb

### preferred low-cost path

alex taradov’s open-source usb sniffer is a strong initial target.

characteristics:

- low-cost hardware
- open design
- usb traffic capture
- pcapng output
- natural wireshark compatibility

initial integration:

```text
usb sniffer
    ↓
pcapng
    ↓
xodb usb decoder
    ↓
device/class/protocol timeline
```

later correlate usb transfers with endpoint, request type, device class, kernel driver activity, process/syscall, thread/stack/source, and device enumeration lifecycle.

### commercial usb analyzers

total phase beagle analyzers are useful compatibility targets, but should remain optional because of cost.

## logic analyzers and low-speed buses

sigrok/pulseview-compatible hardware is one of the highest-leverage opportunities.

useful protocols include:

- i²c
- spi
- uart
- rs-232
- rs-485
- can
- lin
- jtag
- ejtag
- arm itm
- arm etm
- arm tpiu
- hdmi-cec
- hdcp control traffic
- gpib
- miscellaneous embedded buses

hardware tiers:

- generic fx2-style analyzer: approximately $10–$25
- dslogic-class analyzer: approximately $60–$100
- saleae-class devices: higher cost, useful reference target

xodb should aim to make low-cost devices useful enough that high-end hardware is optional.

## hdmi

split into two classes.

### control-plane analysis

relatively inexpensive:

- ddc
- i²c
- edid
- cec
- hdcp control messages

these can often be observed with commodity logic-analysis hardware.

### high-speed video-link analysis

substantially harder:

- tmds
- frl
- raw high-speed lane capture
- video reconstruction

this quickly enters expensive analyzer territory. initial work should target the control plane.

## x11

`xscope` is the canonical reference:

```text
x11 client
    ↓
xscope proxy
    ↓
x server
```

xodb should capture requests, replies, events, resource/window ids, timestamps, and client/process identity in structured form.

## wayland

initial sources:

- `WAYLAND_DEBUG=1`
- compositor debug output
- weston protocol tracing/debug scopes

longer-term, use a structured wayland proxy/logger:

```text
wayland client
    ↓
xodb protocol proxy
    ↓
compositor
```

capture object ids, interface names, requests, events, fd passing, shared-memory buffers, timing, and client/process identity.

avoid relying on parsing human-readable debug strings as the long-term architecture.

## can and automotive

a low-cost usb-can adapter plus socketcan provides substantial value.

targets:

- can
- can-fd
- lin
- diagnostic traffic
- application-level protocol decoders

correlate bus message, process, socket, syscall, thread, source, timing, and firmware activity.

## uart / rs-232 / rs-485

very low-cost hardware with broad relevance.

use cases:

- serial consoles
- embedded firmware
- bootloaders
- industrial devices
- debug monitors
- custom binary protocols

support raw byte capture, framing, timestamps, baud/config metadata, protocol decoding, request/response grouping, and terminal/log correlation.

## jtag / swd / hardware trace

cover both control and observation.

debug control:

- halt/resume
- registers
- memory
- breakpoints
- watchpoints

trace:

- etm
- itm
- swo
- tpiu
- architecture-specific trace streams

xodb should correlate hardware trace with source, disassembly, runtime events, kernel events, and external bus activity.

## spi / i²c and firmware buses

strong targets include flash access, boot firmware, sensors, power controllers, secure elements, embedded controllers, and bios/uefi-related traffic.

## lpc / spi flash / pc firmware

possible areas:

- bios/uefi flash transactions
- embedded-controller communication
- firmware boot flows
- platform-management traffic

especially useful when paired with kernel tracing, serial console, jtag, and static firmware analysis.

## bluetooth

software-first path:

- `btmon`
- hci snoop
- wireshark-compatible capture

correlate controller traffic, host process, socket, runtime, device state, and timing.

## wifi

use monitor-mode adapters where supported.

capture radiotap, 802.11 management/control/data frames, association/authentication activity, retransmissions, and signal/channel metadata.

application-layer decryption requires keys or session material.

## input systems

software-side:

- evdev
- libinput
- wayland input events
- x11 input events

hardware-side:

- usb hid
- bluetooth hid

potential questions:

- which device generated this input?
- when did the kernel receive it?
- which compositor/client consumed it?
- which thread acted on it?
- what source code handled it?

## audio

software-side:

- alsa
- pipewire graph/state
- stream creation/destruction
- device routing
- xruns
- latency

hardware-side:

- i²s via logic analyzer
- embedded audio buses where practical

## filesystem and block io

sources:

- ebpf
- tracepoints
- perf
- vfs hooks
- block layer
- nvme events

correlate process, fd, syscall, block request, latency, filesystem path, and source stack.

## dbus

capture service, object path, interface, method, arguments, reply, signal, sender/receiver, and timing.

correlate with process/thread/source.

## android binder

binder should be treated as a major system protocol bus.

potential data:

- transaction sender
- transaction receiver
- interface
- code
- latency
- process/thread
- native and managed stacks

## unix sockets and application ipc

targets:

- unix-domain sockets
- custom binary protocols
- protobuf
- grpc
- json-rpc
- language runtime ipc

capture at the syscall/socket layer first. add schema-aware decoding where schemas are available and explore protocol inference later.

## gpu api streams

software-side interception can provide strong value without physical bus analysis.

targets:

- vulkan layers
- opengl interception
- dxvk
- vkd3d
- proton
- gamescope
- engine-level frame markers

correlate frame, draw/dispatch, shader activity, cpu thread, profiler samples, allocator events, and scheduler stalls.

# hardware strategy

## tier 0: software-only

cost: effectively zero.

examples:

- pcap
- tls key logs
- x11 proxying
- wayland tracing
- dbus
- binder
- perf
- ebpf
- ftrace
- pipewire
- socket tracing

## tier 1: commodity probes

target range: approximately $10–$100.

examples:

- fx2 logic analyzer
- dslogic-class analyzer
- usb-can
- uart adapter
- taradov usb sniffer
- inexpensive swd/jtag probe

this is the preferred hardware tier.

## tier 2: better development hardware

target range: approximately $100–$500.

examples:

- higher-quality logic analyzers
- j-link-class probes
- better usb analyzers
- higher-quality can tooling

support where useful, but do not require this tier for core workflows.

## tier 3: professional protocol analyzers

examples:

- high-end usb analyzers
- hdmi analyzers
- pcie analyzers
- specialized automotive analyzers

use vendor integrations, loaners, or optional support. do not design xodb around mandatory access to this class of hardware.

# core product opportunity

traditional tools typically show one domain:

```text
wireshark       network
logic analyzer  pins
gdb             process state
perf            cpu samples
strace          syscalls
openocd         target cpu
```

xodb should combine them:

```text
external transaction
      ↓
kernel event
      ↓
process/thread
      ↓
stack
      ↓
function/source
      ↓
runtime object
      ↓
agent hypothesis
```

example:

```text
spi transaction
    ↓
irq
    ↓
driver wakeup
    ↓
userspace read()
    ↓
thread 17
    ↓
parse_packet()
    ↓
allocation
```

the system should answer questions such as:

- what software caused this bus transaction?
- what external event woke this thread?
- what packet triggered this allocation?
- what usb request preceded this crash?
- which source function produced this can message?
- what happened on the kernel side between these two protocol events?

# recommended initial implementation order

1. pcap/network ingestion
2. tls key-log integration
3. x11 protocol capture
4. structured wayland tracing/proxy
5. sigrok/pulseview-compatible logic-analyzer ingestion
6. taradov usb-sniffer pcapng ingestion
7. can/socketcan integration
8. uart/serial ingestion
9. dbus
10. android binder
11. openocd/jtag/swd integration
12. gpu api event ingestion
13. hdmi control-plane analysis
14. higher-cost analyzer integrations as optional backends

# design principles

- capture formats should remain raw and preservable.
- decoded interpretations should retain provenance.
- unsupported or ambiguous protocol data should remain visible rather than silently guessed.
- hardware timestamps should be preserved when available.
- clock-domain uncertainty should be explicit.
- loss/drop counters must be first-class.
- protocol decoders should be modular.
- cheap hardware should remain useful even when expensive hardware offers better timing or bandwidth.
- no protocol analyzer should become a mandatory dependency for xodb.
- agent analysis should sit above deterministic capture and decoding, not replace them.

# concise product statement

xodb should become an instrument hub for software and hardware behavior.

the long-term goal is not simply to debug a process, but to understand everything that process can observe, emit, and interact with:

```text
cpu
memory
kernel
network
usb
display protocols
serial
embedded buses
storage
audio
gpu
ipc
external devices
```

the preferred strategy is to acquire raw evidence using the cheapest practical commodity mechanism and make xodb responsible for correlation, semantics, visualization, and agent-assisted analysis.
