# Burrito mode: is it the microwave?

Your Wi-Fi drops every time someone heats lunch. xodb can show whether the
microwave is the cause. It listens to the 2.4 GHz band and to your own Wi-Fi
link on one clock, then says what it measured:

> microwave-like interference: 60 Hz pulsing, ~48% duty, 2448-2466 MHz (Wi-Fi channels 7-13); seen 30-90 s into the last 120 s

and how hard it hits each Wi-Fi channel:

> microwave-like 60 Hz pulsing at 2445-2475 MHz: channels 6-13 blasted (up to 49 dB over the floor, 53% of the time), 1-5 and 14 clean

```sh
xodb --burrito                                                  # list the cards, read the in-use link passively
sudo xodb --burrito --radio wlan1 --phases 30,60,30             # microwave off 30 s, on 60 s, off 30 s
sudo xodb --burrito --radio wlan1 --traffic wlan0 --phases 30,60,30   # plus per-channel traffic from a second spare card
sudo xodb --burrito --radio wlan1 --channel 10                  # one fixed window: the highest sample rate
sudo xodb --overview --radio wlan1 --radio-traffic wlan0 --panel radio  # the Radio panel (W)
xodb --overview --radio-demo kitchen --panel radio              # the panel on SYNTHETIC spectrum and traffic
```

## Receive-only, always

xodb never transmits from a card it holds. On a card you choose, it sets
monitor mode and runs the ath9k spectral scan in `background` mode with
`trigger`; moving the window across the band is a monitor channel change. A
traffic card (`--traffic`) is put in monitor mode and only read through a
packet socket; xodb never writes to it.
It never uses `chanscan`, because that mode rides on active scans. It sends no
scans, probes or association requests and injects nothing. The card's TX
counters (`/sys/class/net/NAME/statistics/tx_packets` and `tx_bytes`) are read
when the card is taken and every second after that. If they move, xodb puts
the card back and stops. The terminal run prints the counters before and
after, and exits with an error if they moved. Every second xodb also checks
that each card it holds is still in monitor mode; if something else took it,
xodb stops and leaves the card to it.

By default xodb sends nothing at all. `--ping` (`--radio-ping` in the
overview) turns on the one thing it can send: an ordinary ICMP echo to your
gateway at 50 Hz, bound to your in-use Wi-Fi interface, to measure loss while
the interferer runs. If the socket cannot be bound to that interface, xodb
does not ping. The panel labels that lane "ping (sent)".

## Your cards

Each card is in one of three roles:

| Role | When | What xodb does with it |
| --- | --- | --- |
| in use | associated (or up with a link in any mode), up with a default route, another interface on the same card is up, or managed by NetworkManager, iwd, ConnMan, wpa_supplicant or hostapd (read-only checks of their runtime files and processes; a running manager that does not say which cards it holds claims them all) | reads it passively: signal, TX bitrate, retries and failures, the channel survey (busy share, noise), and with `--ping` the gateway ping at 50 Hz. It never changes the card's mode, channel or state. |
| spare | none of the above | nothing, until you choose it with `--radio NAME` (needs root). It is then used for the waterfall (ath9k) or kept as a receive-only monitor. |
| blocked | switched off by rfkill | nothing. xodb does not unblock radios, because a network manager may then start scanning. |

`xodb --burrito` and MCP `list_radios` show every card with its role, the
reason for it, and what the card can contribute. They also say what is
missing, for example: "no spectral-capable adapter: showing link-quality
evidence only; an AR9271 USB adapter adds the 2.4 GHz waterfall".

**The usual setup** is a laptop whose built-in card is its internet link, plus
a USB AR9271 (ath9k_htc) as the spectrum sensor. The built-in card is in use,
so it is only read. The AR9271 is spare, so `--radio wlan1` takes it.

**Putting it back.** Before changing anything, xodb writes the card's earlier
state to `$XDG_STATE_HOME/xodb/radio-restore` (under sudo this is often
root's `~/.local/state`). The state is: up or down, interface type, and the
spectral settings. On exit xodb restores the card and deletes the file. After
a crash or `kill -9`, the next xodb start that finds the file restores the
card, unless the xodb that wrote it is still running. A second xodb never
takes a card that another one holds. xodb puts a card back only while it is
still the one it took, in the mode xodb left it: a file from before a reboot
is dropped, and a card that was replugged, changed by something else, or
taken by a network manager meanwhile is left alone (only the spectral scan
xodb started is switched off). While xodb holds a card it checks every second
that the card is still in monitor mode; if not, it stops and leaves it alone.

## What it measures

| Source | Clock | Rate | Needs |
| --- | --- | --- | --- |
| ath9k spectral scan (HT20 FFT: 56 bins over 20 MHz, rssi, noise, TSF) | the card's TSF (µs), mapped to CLOCK_MONOTONIC by the lower envelope of read time minus TSF; the panel and MCP report the spread as uncertainty | about 6,600 samples/s on an AR9271 at the default `--spectral-period 16` (period 1 gives about 25,000/s) | root, debugfs, a spare ath9k/ath9k_htc card |
| link: nl80211 station and survey of the in-use card | CLOCK_MONOTONIC | 2 Hz | nothing (unprivileged) |
| gateway ping, opt-in with `--ping` (ICMP echo over a ping socket bound to the in-use interface) | CLOCK_MONOTONIC | 50 Hz | `net.ipv4.ping_group_range` that includes you (most distributions), an IPv4 default gateway on the Wi-Fi link |

The detector (`src/radio/detect.zig`) is pure and tested on synthetic
spectra. It works in these steps:

1. **Energy.** A sample has energy when its channel power (noise + rssi) is
   at least 8 dB above the floor. The floor is the quietest tenth of samples,
   capped by the hardware's noise figure.
2. **Pulsing.** The on/off series is cut into slots of twice the median gap
   between samples. Its autocorrelation is measured at the 60 Hz and 50 Hz
   periods and at twice each. Mains pulsing means a strong peak at one period
   (r ≥ 0.35), clearly stronger than at the other period, with its second
   multiple present, at least 20 periods seen, and a duty cycle between 10%
   and 90%. A sample rate too slow to resolve 50/60 Hz is reported as too
   slow, never as "no pulsing". The terminal's `half=` is the ACF at half a
   mains period minus the mean ACF at quarter and three-quarter periods: a
   transformer oven should be negative, while a 100/120 Hz frame source stays
   positive. Subtracting those flanks removes the broad positive correlation
   from Wi-Fi or Bluetooth activity in the same window. The gate takes the
   same baseline off the full-period ACF too (`half` must be under half of
   it), so a weak frame source on a busy band is still rejected.
3. **Shape.** Each active sample's occupied width counts the bins within
   10 dB of its peak, and the spread of peak frequencies across samples shows
   hopping. Bins hot in at least 10% of active samples give the occupied
   band, and the band gives the Wi-Fi channels it overlaps.
4. **Verdict.** In this order: microwave-like (mains pulsing); continuous
   wideband energy with "mains pulsing not seen" (an inverter microwave looks
   like this, so does a video sender); narrowband hopping (Bluetooth-like);
   Wi-Fi-like bursts; activity not classified; quiet. The confidence comes
   from the autocorrelation, how many periods were seen and the coverage,
   never from a guess. With only link evidence, xodb says what the link did
   and that it cannot name the source.
5. **When.** Two-second chunks find when the interference started and
   stopped. Ping loss inside that interval is compared with loss outside it.

## Sweep, focus and N sensors

One spectral window sees 20 MHz. By default the sensor sweeps: windows on
channels 1, 4, 7, 10, 13 and 14 (2402-2494 MHz, interiors overlapping by
4 MHz), 600 ms each. 600 ms is the shortest dwell that still resolves 50/60 Hz
in one visit (the detector wants 20 mains periods and half a second). Every
window is revisited within 3.6 s and watched 17% of the time; the plan says so
in words ("sweep 2402-2494 MHz: 6 windows ..., each revisited within 3.6 s
(17% of the time)"), and the views show each region's age.

A focus narrows the plan: `--focus 2440-2470` (`--radio-focus`, or a drag in
the panel) sweeps only the windows that cover the span; a span that one
window holds, or `--channel N`, parks the sensor on one fixed window, never
retuned, for the highest sample rate (about 6,600 samples/s against about
5,000 while sweeping). Retuning happens at once and is a monitor channel change.

Several spectral cards (`--radio wlan1,wlan2`, up to four) share the plan.
Each sensor owns contiguous windows; enough sensors (six here) watch the whole
band at once with no sweeping; with a park hint one sensor stays on the
blast region while the others sweep. Every card's TSF is mapped to the host
clock separately, and the verdicts work on host time. Only one AR9271 was on
hand: the N-sensor planner and collector are tested with synthetic sensors
(`--demo kitchen --demo-sensors 2`).

HT40: the AR9271 (ath9k_htc) does deliver HT20/40 spectral records (type 2,
152 bytes, 128 bins over 40 MHz; about 2,400 a second at period 16) when its
monitor channel is HT40+/-. `--ht40` shows that; xodb counts these records
but does not decode them yet (that would cover the band in three windows).

## The 14 channels: the blast radius

Spectral samples are grouped by the window they were taken in, and each
window gets the detector's verdict with its dwells joined end to end. In a
window with mains pulsing, each MHz is folded over the mains period: energy
that follows the half-cycle (hot clearly more often in the "on" half, with its
on-minus-off power 3 standard errors clear of the bursts of whatever else is
there) is the interferer's. The access points and Bluetooth that share the
window are classed by a verdict on the off-phase samples. So the spectrum's
bars are coloured mains-pulsed, continuous, Wi-Fi-like, hopping, other or quiet.

Each channel (its 22 MHz mask at its true centre, 5 MHz apart, overlapping)
is measured by the window centred nearest it: power, floor (the quieter tenth,
capped by the card's own noise figure), power over the floor, and the share of
samples 8 dB or more over the floor. The interferer's own power inside the
mask while it is present says how badly the channel is hit: **blasted** at
20 dB or more (a typical link has 25-45 dB of SNR), **grazed** at 6 dB or
more, otherwise **clean**; **unseen** when no window covered it. This is
instantaneous severity, while the adjacent percentage is the share of watched
time (`<1%` is printed instead of rounding a real hit to `0%`). The verdict groups them
("channels 6-13 blasted (up to 49 dB over the floor, 53% of the time), 1-5 and
14 clean") and names the least affected of channels 1, 6 and 11.

The terminal's five-second headline and channel line analyse the same exact
interval. If pulsing is clear but no MHz bucket passes the synchronous-energy
test, both report that the location is unresolved instead of naming the whole
observed band. A phase summary unions the locations independently supported by
its five-second windows, reports how many pulsing windows were localized, and
marks a channel hit if any such window hit it. A carrier that moves during the
phase therefore appears as its swept span rather than one long-window peak.

The blast is the mains-pulsed energy and the continuous energy touching it
(the oven's skirt). Continuous energy apart from it is another source: it is
named separately ("other continuous energy at ...") and does not count as
the blast. With no mains pulsing at all, the span is reported as continuous
wideband energy, never as a mains blast.

## Traffic

`--traffic wlan0` puts a second spare, monitor-capable card in monitor mode
and hops it across the plan's channels, 500 ms each, reading radiotap headers
and the first bytes of each frame: frames/s, an airtime estimate (preamble +
length / rate, from the reported legacy, HT, VHT or HE rate), the retry share
of data and management frames, frames with a bad FCS, and how many distinct
networks (BSSIDs) and stations (transmitters to an AP, probes) were heard. The
point: while the microwave runs, traffic on the blasted channels retries and
fails its FCS, and stays put on the clean ones ("traffic on hit channels: 57
frames/s, 33% retries, 9.3 bad-FCS frames/s; on clean channels: 41 frames/s,
7% retries").

## The panel

The Radio panel (**W**) has the verdicts in words; the total-energy
spectrum (x = frequency across the view, y = dBm per FFT bin: live bars
coloured by class, a peak hold, a slowly decaying max ghost, the 14 channel
masks beneath, the blast band, each swept region's age, and a live pulse);
the channel strip (one lane per channel at its true centre, newest row on
top, 500 ms rows: power, floor, over floor, busy, frames/s or retry, chosen
with the chips or `[` `]`; cells the sweep did not visit carry the last value,
faded); per-channel traffic; and the cards. The **waterfall** chip shows R2's
time-across waterfall instead of the strip.

**Drag** across the spectrum or the strip to focus the sensors on that span:
they retune at once, and the view zooms with a pop, the bars springing up as
fresh samples land. `f` toggles a fixed window for the focus; **double-click**
or Esc returns to the sweep.
Retunes are rate-limited to four a second (each costs the cards an RF
calibration); requests in between collapse into the newest.

The panel adds each new sample once (spectrum rows, strip cells, waterfall
columns) and computes the verdicts off the GUI thread once a second. It
draws when samples landed, at most 10 frames a second, and at the view's
30 fps only while the pop animates (1.2 s).

What it costs (AR9271 + RTL8852BE, measured with /proc): the panel draws in
under 1% of a core and the collector reads a fixed window in about 1%.
Sweeping adds the AR9271's chip reset on each retune; a traffic card adds its
driver's RF calibration on each channel change (rtw89: DPK and RX DCK, kernel
busy-waits), about 7% of a core at 500 ms per channel. The verdicts are
computed once a second on a short-lived thread.

## When the stream stops

Under a strong signal (a magnetron a few metres away) the AR9271 delivers
fewer samples, and some records are corrupted. xodb shows a stall instead of
freezing: after 2 s without samples the panel, the verdict and the CLI say "no
spectral samples for N s (re-triggered X times, re-armed Y times)". After 1 s
of silence xodb triggers the scan again; after 3 s it re-arms it from scratch
(disable, settings, background, trigger, and the channel again), at most every
3 s. The parser resynchronises on the next plausible record after a corrupted
one, rejects records with an impossible frequency, and the host-clock mapping
holds back samples whose TSF disagrees with it by over 250 ms: a lone garbage
TSF is dropped, and only an offset that holds for half a second is a TSF step
(then the mapping re-anchors). The counts are in the report (`spectral.silent_s`,
`retriggers`, `rearms`, `rejected`, `tsf_steps`).

The spectral ring holds about 80 s of samples; a longer window says "spectrum
covers only the last N s of the M s asked".

## Over MCP

`list_radios` returns the cards, roles, reasons, capabilities, the TX
counters of a taken card, and what is missing. `radio_interference` takes
`window_ms` (1000..600000, default 30000) and `redact`. It returns the verdict
in words and in numbers (r60, r50, duty, band, channels, width, hop spread,
coverage), the per-chunk kinds, the link and ping summaries split by the
interference interval, the spectral clock and its uncertainty, and the TX
counters. `radio_channels` takes the same arguments and returns, per channel
1-14, the window that measured it and how fresh, power, floor, occupancy, the
interferer's power over the floor and share of time, the impact, and the
traffic counts; plus the verdict in words, the blast band, the per-window
regions, five-second pulsing/location counts for a phase, the least-affected
of channels 1/6/11, the sweep plan and the TX counters of every taken card. An
agent can answer "which channel should my AP
use when the microwave is on?" from it. All three tools are observer-only. A
card is only ever taken by the operator's `--radio` or `--traffic`; the tools
start the passive collector if none is running (no ping) and say when the
window is partial.

## Privacy

Spectral samples carry power per bin and no identities. The traffic card's
frames are read only as far as the 802.11 header: addresses are hashed with a
per-session random key the moment they are read, the hashes are kept in
memory only to count distinct networks and stations, and nothing but the
counts is ever shown, returned or stored. SSIDs and frame bodies are not
parsed. `--redact` hides the gateway address. Tests use synthetic spectra
(`detect.Synth`) and synthetic radiotap frames generated in the test, and a
synthetic sysfs/procfs tree for the card roles.

## Not yet

- ath10k/ath11k spectral samples: xodb recognises the driver and says it does
  not read them yet. nRF24 dwell-and-sample and SDR sources are planned (R3).
- Decoding HT20/40 samples (128 bins over 40 MHz): the AR9271 delivers them
  (see above); they are counted, not decoded.
- Locking the traffic card onto the blast region by itself once the verdict is
  in (a drag does it by hand).
