# mac-power

Swift 6.2, macOS 26. `MacPowerHost` reads IOPowerSources and ProcessInfo and
observes IOPS changes on the main run loop, thermal/low-power notifications,
and NSWorkspace willSleep/didWake. Construct/start/stop/refresh it on the main
actor. Observation starts and publishes immediately by default. `stop()` removes
notifications and invalidates the IOPS run-loop source. Sampling closures and
notification centers are injectable for tests; normal use reads the real APIs.

`MacPowerDriver` depends on `../../tarwin-power`. Supply a fresh pinned,
4096-byte-aligned 4096-byte page to its failable initializer. It uses the actual
`PowerPageWriter` to publish LibTessera §18.1 PowerInfo before `onPublished`.
Keep that page alive for the driver's lifetime and give clients only read-only
mappings after first publication; no page mapping authority is implemented here.
Driver receive calls and callbacks must be serialized by the owner.

Thermal values map to `TarwinPower.ThermalBand` nominal/fair/serious/critical.
Unknown future host thermal states become critical. The driver starts critical
until a valid environment frame arrives. The first present internal battery is
selected for PowerInfo; otherwise the first present UPS is used. Any present
source on AC reports externalPower=Mains (4); IOPS does not reliably identify
USB/wireless/dock charging here. Percent is 0…100 or UInt32.max for unknown/no
battery. State is Unknown=0, Discharging=1, Charging=2, Full=3, NotCharging=4.
Time estimates are minutes converted to nanoseconds; unknown/unlimited estimates
are zero. Draw/throttle fields are zero (not measured, not invented).

If IOPS reports no present sources, host publication contains one online Mains
source. Source IDs are snapshot-local. Full snapshots replace prior sources,
so battery removal cannot leave stale slots behind. Snapshots support up to 32
sources; host truncates beyond that. No-battery VM tests also exercise the real
IOPS query, not only a fixture.

Sleep/wake frames call `onSystemEvent` for the power service. TarwinPower's
`SystemSleep` requires a topology, policy lock, armed wake token, and platform
park transaction; it exposes no safe host-notification hook. We deliberately do
not fake those prerequisites or call suspend from a macOS notification. The
composition/power service must connect these events to its policy.

## Family 3 wire format

Uses HostedDeviceWire from `../mac-hid`: 32-byte TWHD header, version 1, family 3,
little-endian integers. Header timestamps use `HostClock.monotonicNanos()` (Mach
continuous epoch including sleep). Sequence increments per host frame. Driver
ignores stale timestamps, unknown kinds, invalid outer frames, malformed payloads
and duplicate source IDs. Invalid snapshots do not partially update publication.

| Kind | Payload |
|---|---|
| 1 sources | count u32 (1…32), then count × 32-byte source records |
| 2 environment | thermal u32 (0 nominal, 1 fair, 2 serious, 3 critical), lowPower u32 (0/1) |
| 3 sleep | empty |
| 4 wake | empty; host also refreshes sources/environment after wake |
| 0xffff ping | empty |
| 0xfffe pong | empty, echoing ping sequence and timestamp |

Each 32-byte source record:

| Offset | Type | Meaning |
|---|---|---|
| 0 | u32 | snapshot-local source ID |
| 4 | u32 | kind: 1 internal battery, 2 mains, 3 UPS |
| 8 | u32 | percent 0…100, or 0xffffffff unknown |
| 12 | u32 | flags: bit 0 present, 1 on external AC, 2 charging, 3 full; others zero |
| 16 | u64 | time-to-empty ns, 0 unknown |
| 24 | u64 | time-to-full ns, 0 unknown |

The frame/source codecs and page publication contain no Foundation and perform
no steady-state heap allocation. IOPS/AppKit observation is regular Swift and
may allocate. XPC dictionaries/shmem and health queue behavior are supplied by
HostedDeviceWire; H7 owns authentication, listeners, and connection handoff.

## Hosted platform registry

Register `try MacPowerDeviceProvider(driver: driver)` in `HostPlatform.devices`
or `HostDeviceRegistry`. Kind is `power`; `open(slot: 0)` returns an owned HostPort
send reference to the default driver's TWHD inbox; other slots throw. Retain the
provider while ports are used. `HostedDriverEndpoint.send(frame:to:)` delivers
host frames to `driver.receive`; replies use its injected HostedDeviceChannel.
This is an alternative inbound transport, not a second concurrent writer to the
same publication page. See mac-hid README for the inline Mach envelope.

```
swift build && swift test
```

Tests cover thermal mappings, real/no-battery IOPS samples, page publication,
notifications→frames→page, sleep/wake service events, malformed/stale frames,
ping/pong, and registry open/bad-slot plus Mach endpoint delivery. They do not
physically sleep the machine or claim battery/thermal hardware endurance.
