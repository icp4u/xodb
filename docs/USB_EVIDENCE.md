# Offline USB evidence

`--open-pcap FILE` reads Linux usbmon captures with pcap/pcapng link types
`LINKTYPE_USB_LINUX` (189) and `LINKTYPE_USB_LINUX_MMAPPED` (220). xodb does
not start usbmon, open a USB device, or acquire capture privileges. The source
file remains the immutable stream with id 1; decoded URBs are a derived `usb`
stream reported by `list_streams`.

The decoder pairs submit/completion/error events by URB id, reports observed
latency, setup packets, status and captured lengths, and decodes device,
configuration, string, interface, endpoint, HID and CDC functional
descriptors. Interface class summaries identify HID, CDC control/data and the
common SCSI bulk-only mass-storage combination. `query_stream` uses
`view=devices` or `view=endpoints` for the bounded observed lifecycle. First
and last record mean first and last observation in this file; usbmon does not
prove physical connection or disconnection.

All counts are bounded. `list_streams` reports the decoder limits and separates
pcap interface/OS/packet drops from malformed URBs, unmatched submissions,
orphan completions and records omitted at the derived-record cap. A truncated
or malformed record stays addressable with an `undecoded` reason.

USB transfer data and decoded string descriptors are private evidence. They
are available only to the direct observe-scope MCP connection that opened the
file; transfer data also requires `include_raw=true`. Shared-session peers,
controllers and network transports receive null string values and cannot ask
for data bytes. `--redact` applies the same refusal and the common output
scrubber. The raw parent stream applies that gate too, so it cannot bypass the
USB stream policy.

When an opened capture archive has ECTX tables containing an exact
`/dev/bus/usb/BBB/DDD` descriptor, `correlate` can join the bus/device address
to its process and fd. usbmon does not name the URB submitter (kernel drivers
and every holder of the device share its traffic), so a USB join is never
`exact`: a descriptor present in snapshots bracketing the aligned record is
`sampled`; a one-sided or unaligned observation is `inferred`.
Other device nodes and absent tables are not guessed.

## Making a capture

Capture access is configured outside xodb. On distributions that install
`dumpcap`, an administrator can grant the packaged binary its documented
capture capabilities or put the operator in the distribution's Wireshark
capture group. A user with access to a selected usbmon interface can then run,
for example:

```text
dumpcap -i usbmon1 -w usb.pcapng
```

`tcpdump -i usbmon1 -w usb.pcap` is another option when the operator already
has permission. Capture only the bus and time window needed for the
investigation: usbmon can contain keystrokes, storage traffic, device serials
and other private data. xodb installs no setuid binary, capability, group,
udev rule, kernel module or privilege helper.

Tests generate synthetic pcapng bytes and synthetic descriptors. They never
read live usbmon or a real USB device.
