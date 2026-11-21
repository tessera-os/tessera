# mac-hid / HostedDeviceWire

Swift 6.2+, macOS 26+. Products: `HostedDeviceWire` (also shared by mac-audio
and mac-power), `MacHIDCapture` (AppKit host), `MacHIDDriver` (virtual reports).
Build and test with `swift build && swift test`.

## Live input check

```sh
TARWIN_HID_LIVE=1 swift test
swift test
```

The opted-in test creates and activates a real NSWindow with a first-responder
NSView. It posts tagged CGEvents at the HID event tap, pumps AppKit's event loop,
and translates only the NSEvents delivered to that view. A test channel sends
the resulting frames through `HostedDriverEndpoint.send` to slot 0 opened from
a `HostDeviceRegistry` containing `MacHIDDeviceProvider`; there is no loopback
shortcut into the driver. It checks 12 events and 20 ordered InputRing reports:
Shift/A down/up (usage 4, modifier bit 2), relative mouse movement, click,
button-held drag, line scroll, and continuous pixel scroll. Both scroll axes,
the precise-scroll wire flag, absolute pointer companions, and continuous-clock
timestamps are checked. Events are posted individually to prevent coalescing.

Without the environment flag the live test returns without opening a window;
the existing offline tests still run. Opted-in permission, focus, delivery, and
Mach errors fail rather than skip. Run only in an unlocked graphical session:
the test temporarily takes focus and moves the pointer. Explicit
`activate(ignoringOtherApps: true)` was needed for the command-line xctest runner
on this Mac; ordinary `activate()` did not focus the window.

`CGPreflightPostEventAccess()` was already true on this Mac, and the live test
posted successfully without new TCC grants or database writes. The system TCC
database already had allowed Accessibility, PostEvent, and ListenEvent entries
for `/Library/Devin/agent/devin-remote`. The runner was
`/Applications/Xcode.app/Contents/Developer/usr/bin/xctest`. On another machine,
grant Accessibility to the responsible terminal/test runner in System Settings
→ Privacy & Security → Accessibility, then relaunch it. Input Monitoring is not
needed by this test: it receives events in its own view, not a global event tap.

The live test also attempts magnify, rotate and swipe using **undocumented,
test-only** CGEvent fields: type 29 (with type 30 as a delivery fallback), field
110 for subtypes 8/5/16, field 113 for magnification, field 114 for rotation,
field 115 for swipe direction, and field 132 for began/changed/ended phases
(1/2/4). It checks delivered NSEvent types and the gesture reports' subtype,
16.16 values, phases and timestamps through the same Mach path. No direct
NSEvent construction substitutes for posting. These numeric fields are not
supported public API and must not be copied into production event capture.
The public SDK has no equivalent gesture constructor.

Without field 132, magnify/rotate reached the app's event monitor but were not
dispatched to the focused view on this Mac. Explicit phases enabled view
delivery. The test posts a zero-valued begin, a nonzero change, and a zero-valued
end. Fields 113 and 114 alias the same stored value on this Mac, so the test
writes only the field for the active subtype. Missing gesture delivery fails with per-attempt
NSEvent diagnostics instead of skipping or claiming success.

## Hosted platform registry

Register `try MacHIDDeviceProvider(driver: driver)` in `HostPlatform.devices`
(or a standalone `HostDeviceRegistry`). Its kind is `hid`; `open(slot: 0)` returns
an independently owned `HostPort` send reference to the retained driver's frame
inbox. All other slots throw. Keep the registry/provider alive while using ports.
`HostedDriverEndpoint.send(frame:to:)` sends a TWHD frame to that inbox, which
dispatches to `driver.receive` on a user-interactive serial queue. This is an
alternative inbound transport: do not concurrently feed the same driver from
XPC/loopback and Mach. Return traffic still uses its injected HostedDeviceChannel.

Mach envelope (native host ABI): `mach_msg_header_t`, message ID `0x54574844`,
then little-endian u32 TWHD byte length, frame bytes, zero padding to 4-byte size.
No descriptors, reply right, or out-of-line data. Opened send rights are owned by
HostPort and must not be independently deallocated. The receive right remains
alive through Dispatch cancellation. Clock timestamps use
`HostClock.monotonicNanos()` (continuous, includes sleep), not its absolute epoch.

## Tessera.app integration

H7 owns XPC service registration, listener acceptance, authentication, and the
AppKit event monitor. Construct `XPCDeviceChannel(serviceName:)`,
`XPCDeviceChannel(endpoint:)`, or `XPCDeviceChannel(connection:)` with an accepted
connection. The default service is `dev.tessera.tarwind.devices`; it is injectable.
The channel takes over the connection's event handler and resumes it. Call
`close()` when finished. Callbacks run on a user-interactive serial receive queue;
configure them before traffic starts, and serialize sends from each producer.
All buffers passed to callbacks are borrowed only for the duration of the call.
Do not retain a `FrameView` or its payload beyond that call.

XPC messages are dictionaries: `tw.frame` is XPC data containing exactly one
frame. `tw.shmem` is an XPC shared-memory object, sent via `sendSharedMemory` and
delivered via `onSharedMemory`; the receiving family negotiates the region layout
and lifetime. No pointer values are transmitted. XPC ping handling is independent
of UI event processing and answers on the high-QoS receive queue in every family.
No agent or service listener is installed by this package.

On the main actor create `HIDEventTranslator(channel:)`; call `setFocused(true)`
only for the focused guest view. Forward its NSEvents using `translate`, providing
the guest window-coordinate extent. Call `setFocused(false)` on resign-key,
view removal, or disconnect *before* closing the channel. It emits all-released
keyboard, pointer, and tablet reports and clears local held state. Translation
while unfocused is ignored. The translator does not consume or install a global
event monitor. Forward received LED frames to `translator.receive` on the main
actor (copy the borrowed frame before a queue hop), and handle `onLEDs` to reflect
caps-lock (bit 1); this package does not modify global macOS keyboard LEDs.

On the driver side retain `MacHIDDriver(channel:ring:)`. It installs the receive
callback. One receive producer and one input-service consumer own the SPSC ring.
Descriptors correspond to device IDs 1 keyboard, 2 relative pointer, 3 tablet,
4 gestures; no report IDs are prepended. Deliver LED output via `setLEDs`.

## Frame wire format, version 1

All integers are little endian, unaligned. No native Swift struct layout is used.

| Offset | Type | Meaning |
|---|---|---|
| 0 | u32 | magic bytes `54 57 48 44` (`TWHD`) |
| 4 | u16 | version, 1 |
| 6 | u16 | family: 1 HID, 2 audio, 3 power |
| 8 | u16 | family-specific kind |
| 10 | u16 | flags (zero unless specified below) |
| 12 | u32 | payload length, at most 65,536 |
| 16 | u64 | sender sequence (wrapping counter) |
| 24 | u64 | host `mach_continuous_time` converted to nanoseconds |
| 32 | bytes | payload, exactly the declared length |

The decoder rejects truncated or trailing bytes, invalid magic/version, and
oversized lengths without trapping. Unknown families/kinds can be decoded for
forward compatibility but the HID driver ignores them. Sequence is diagnostic,
not an acknowledgement or a replay filter. Timestamp is carried into each report.
Every family reserves kind `0xffff` for ping and `0xfffe` for pong, empty payload;
pong echoes the ping's sequence and timestamp. The host should ping input every
500 ms and apply the DeviceKit restart budget externally.

### HID kinds

| Kind | Payload |
|---|---|
| 1 keyboard | 8 bytes: modifier bitmap, reserved zero, six page-7 usages |
| 2 pointer | 17 bytes: buttons u8, dx i16, dy i16, vertical wheel i32 (16.16), AC Pan i32 (16.16), normalized window X u16, Y u16 |
| 3 tablet | 13 bytes: flags u8, X u16, Y u16, pressure u16, tilt X i16, tilt Y i16, twist u16 |
| 4 gesture | 17 bytes: type u8, delta X i32, delta Y i32, phase u32, momentum phase u32 |
| 5 LEDs | 1 byte: standard boot-keyboard LED bitmap (Num/Caps/Scroll/Compose/Kana bits 0–4) |

Keyboard modifier bits 0–7 mean left Control/Shift/Alt/GUI, right
Control/Shift/Alt/GUI (usages E0–E7). Six-key overflow emits ErrorRollOver (1)
in all slots. Each caps-lock flagsChanged emits a press/release of usage 0x39.
Unsupported virtual
keycodes are ignored. Repeated keyDown does not duplicate a held usage.

Pointer button bits are NSEvent button numbers 0–4; coordinates clamp to
0…65535, in the supplied window coordinate system (no Y inversion). Relative
values clamp to signed 16-bit. Wheel flag bit 0 distinguishes precise pixel
scroll from line scroll; fractional values survive transport. The driver
accumulates sub-unit remainders and converts wheel/pan to signed 16-bit integer
HID units (resetting remainders on unit changes). Each pointer frame produces a
9-byte relative report and a 13-byte absolute tablet report with in-range set,
zero pressure/tilt, and the normalized window coordinates.

Tablet flags bit 0 is tip, bit 1 in-range; pressure is 0…65535, tilt in signed
degrees, twist 0…360 degrees. Forward tabletProximity as well as tabletPoint.
Gesture types: 1 magnify, 2 rotate, 3 swipe, 4 smartMagnify. Deltas are signed
16.16 (magnification factor delta, rotation degrees, or swipe X/Y respectively).
SmartMagnify has no delta semantics. Phase fields contain NSEvent phase bits.

Reports and payloads have the same layout except the pointer conversion above.
Driver rejects incorrect payload sizes and ignores unknown kinds.
`InputReportRecord` holds deviceId, reportLength, timestampNs and 64 inline bytes;
it is an in-process value, **not** a shared-memory ABI. Ring capacity must be a
positive power of two. Slots allocate once at initialization. Acquire/release
indices publish complete records; full rings drop new records and increment
`overruns`. The consumer should reset input state if it observes a gap/overrun.
The frame codec, report builder and ring use no Foundation or steady-state heap
allocation; AppKit/XPC adapters are regular Swift and may allocate.
