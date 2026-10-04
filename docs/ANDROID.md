# Android native debugging over USB

Verified on the non-rooted Pixel, Android 17, with an x86-64 Linux workstation
running the desktop GUI. The phone runs a headless ARM64 xodb and an owned C
executable. [Test evidence and screenshots](research/android-gui.md).

## Run the demo

Connect and authorize the phone for USB debugging. From this checkout:

```sh
./scripts/demo-android
```

This uses the newest completed `scripts/build-android` bundle in `.work` and
`zig-out/bin/xodb` for the GUI.


To build a new bundle with an already installed Android NDK:

```sh
python3 -B scripts/build-android --ndk /path/to/android-ndk
```

The build requires Zig, the NDK, CMake/Ninja, make and the normal host build tools.
The launcher requires Python 3, `adb`, `ss`, one authorized USB ARM64 Android
device, and a built desktop GUI. It installs no SDK or app. The current builder
uses a Linux x86-64 host NDK; [build details](research/android-native-build.md).

## Walkthrough

The initial stop is in Android's loader (`__dl__start`), before the demo runs.
The source pane already displays `demo.c`, but it is not the current code yet.
F10/F11 step assembly until the executing frame has source information; loader
locals are unavailable. Press Space to reach the preset `change_value` breakpoint.
You can also click the gutter beside a code line in `demo.c` before continuing;
source breakpoint placement does not require the current frame to be in that file.

- **Space / Continue:** reach the `change_value` function entry, line 9.
- Click the source gutter beside **line 11**, then **Space**. Locals show
  `amount=5`, `next=12`; the pending store will change `state.value` from 7 to 12.
- **F11 / Step:** advance a source line. **F10 / Over:** step over.
  **F7 / Instruction:** step one ARM64 instruction.
- Click a stack frame to inspect its locals and source. Stepping returns to #0.
- **Tab / Registers:** switch the right pane between locals and ARM64 registers.
- **Q:** close the GUI and clean up the device session.

For a hardware-watch demonstration, start a fresh run and stop at line 11 as
above. Click local **next**, then **W / Watch**. Press Space to reach the second
function entry, then Space again. The next assignment stops with **12 → 21**
and `access completed`. **V / Watches** shows the installed watch; select its
row and press **W / Remove** to remove it. A local watch retains its address after
that local's lifetime; this demo deliberately reuses the stack slot on its second
call. Selecting a pointer local watches the pointer's storage, not its pointee.

![Hardware watch in the Android GUI](research/android-gui/02a-watch-hit.png)

The program makes two calls and exits. The service has a five-minute deadline
starting at launch; `--seconds N` sets a shorter limit (1–300). The fixture also
has parent-death protection and its own five-minute alarm once main starts.
Use Q to finish; Detach is not needed for this demo.

## Transport and cleanup

The launcher stages only `xodb`, `xodb-android-demo` and `demo.c` in a newly
created `/data/local/tmp/xodb-gui.XXXXXX` directory. It launches:

```text
xodb --headless --mcp --listen 127.0.0.1:DEVICE_PORT --agent-scope control
     --source ./demo.c --break change_value -- ./xodb-android-demo
```

It then allocates one unused host port with `adb forward --no-rebind tcp:0
tcp:DEVICE_PORT` and launches desktop `xodb --connect 127.0.0.1:HOST_PORT`.
Device and host listeners are loopback only; the host binding is checked before
launching the GUI. A busy device port fails cleanly; the launcher does not evict
another service. xodb accepts one client and closes its listener after accept.
Readiness comes from stderr, since a test connection would consume that client.

**The MCP TCP service has no authentication. Loopback limits its exposure, but
other local processes/apps with access may reach it before the GUI connects.
Use only an authorized device and trusted workstation.** This flow does not
enable network ADB or open a LAN listener.

Closing the GUI or interrupting the launcher closes its control pipe; a remote
shell terminates and waits for its own xodb child. The launcher removes only its
forward and three exact files, then removes the empty directory. All operations
and server output are retained under `.work/android-gui-<timestamp>/`. No root,
phone settings, apps or personal data are changed.

If USB disappears, cleanup cannot be confirmed immediately. The device deadline
still bounds the service. The launcher reports errors and retains the exact
device directory path for inspection when reconnected; it does not attempt
broad process kills or `adb forward --remove-all`. Automatic reconnect is not
implemented. Restart the demo for a fresh session.

## Current scope

- Native executable launched as an ADB-shell child: verified.
- Source breakpoints, source/instruction stepping, stack/locals/registers,
  disassembly and GUI hardware write watches: verified on the Pixel.
- MCP evaluation and memory reads: verified in the earlier stdio service test.
- Rootless CPU profiling of a debuggable APK: verified through the separate
  [simpleperf capture helpers](ANDROID_PROFILING.md), followed by offline
  period-weighted flames, time/thread filtering and sample inspection in xodb
  GUI/MCP. [Import workflow](SIMPLEPERF_IMPORT.md).
- APK-native attachment now works in the separate ANDROID_APPS.md
  using app-UID ADB stdio. ART/Java inspection and reconnect remain future work.
- The remote workspace still has fewer features than the local GUI; expression
  entry and expandable fields are among the remaining gaps.
