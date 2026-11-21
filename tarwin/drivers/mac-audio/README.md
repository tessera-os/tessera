# mac-audio

Swift 6.2 / macOS 26 package. Products are `MacAudioWire` (PCM ring and family-2
codec helpers), `MacAudioHost` (HAL), and `MacAudioDriver` (Tarwin endpoint state).
Depends on `HostedDeviceWire` in `../mac-hid`; no changes to that package required.

## Hosted platform registry

Register `try MacAudioDeviceProvider(driver: driver)` in `HostPlatform.devices`
or a standalone `HostDeviceRegistry`. Kind is `audio`; slot 0 is the default
playback/capture endpoint inbox and returns an owned `HostPort` send reference.
Other slots throw. `HostedDriverEndpoint.send(frame:to:)` forwards family-2
host events to `driver.receive`; see mac-hid's README for the Mach envelope.
Keep the provider alive and use only one inbound transport at a time. Driver
control operations must be externally serialized with this inbox's delivery;
return/control traffic still uses the injected HostedDeviceChannel. Frame times
use `HostClock.monotonicNanos()` in the continuous epoch, not absoluteNanos.

```
swift build && swift test
TARWIN_AUDIO_HAL=1 swift test
```

The normal smoke test renders offline through `AudioProcessor.render`, the same
method called by the real HAL callback. The opt-in test requires a loopback device
selected as both default input and output. After 250 ms of startup silence to
prime both independently started AudioUnits, it plays a deterministic pseudorandom
marker followed by a stereo 1 kHz sine through the playback ring, records through
the capture ring, checks marker correlation (>0.99), waveform RMS error (<0.005),
and advancing position frames for both endpoints. Missing devices or silence
fail the opted-in test rather than skipping it. Microphone access and device
routing are host responsibilities, not simulated successes.

BlackHole 2ch setup on this Mac (no reboot was needed):

```sh
brew install --cask blackhole-2ch
brew install switchaudio-osx
sudo killall coreaudiod
SwitchAudioSource -a
SwitchAudioSource -s 'BlackHole 2ch' -t input
SwitchAudioSource -s 'BlackHole 2ch' -t output
SwitchAudioSource -c -t input
SwitchAudioSource -c -t output
TARWIN_AUDIO_HAL=1 swift test
```

## Host integration / lifetime

Tessera.app/H7 owns XPC acceptance and mapping. Supply one `HostedDeviceChannel`
and optional playback/capture `AudioRing` views to `MacAudioHost`. It uses separate
HALOutput AudioUnits for playback (bus 0) and input (bus 1), with interleaved F32
client streams. The ring may be F32 or I16, 44100/48000 Hz, mono/stereo; conversion
occurs in the shared callback processor. The input callback calls AudioUnitRender
into a preallocated buffer. Slice sizes up to 4096 frames are supported.

Default input **and** output device listeners rebuild running units on a
user-interactive control queue. Ring mappings, gain, mute, and stream position
survive the rebuild; `lastDeviceError` records failures. Device disconnects may
require the owner to restart once hardware returns. No listener/service/agent
outside Core Audio is installed. Call `shutdown()` before discarding the host.

The render thread never performs XPC sends. A high-QoS 10 ms timer sends the
latest position for each active endpoint, and reports xrun counter changes;
normal scheduler jitter applies. Atomic position and timestamp are snapshots,
not a sample-accurate synchronized clock pair. `flushPositions()` publishes
immediately (also used by deterministic offline tests). `automaticPositions:
false` is intended only for these tests. Hardware callbacks and offline tests
share `AudioProcessor.render` / `capture`; missing playback data is always zero.
Volume and mute apply in these methods, not to the user's global device volume.

Create a `MacAudioDriver` with the remote channel, then open, configure with a
mapped ring, and start each endpoint. Commands and receive callbacks must be
serialized by its owner; the host serializes control internally. XPC ping/pong
is answered on HostedDeviceWire's high-QoS queue; offline channels have a direct
family-2 fallback. Health/restart supervision (500 ms ping, 100 ms restart budget)
is external. `onGap` is the input to the Tarwin audio service's **OVERRUN** gap
signal. A full ring drops newest frames; a playback underrun inserts silence.

For restart, retain `AudioStreamSnapshot`s, re-send/map their rings in H7, and
call `restore(on:)` with a fresh channel. This replays open/configure/gain/mute
and running/draining state. Never reset shared indices while a producer or
consumer is active. Drain forbids new producer writes by convention, consumes
queued playback, then stops; capture drain is rejected. Stop preserves queued
data and position; close releases logical state, not ownership of external maps.

## Shared-memory ring ABI (version 1)

The region is little-endian on macOS, at least 8-byte aligned (64 recommended),
with a **64-byte header** followed by interleaved PCM frames. No Swift object or
pointer is in shared memory. Immutable header fields must not change after
publication. Validate before using `AudioRing(region:byteCount:)`; the view does
not own the mapping. `AudioRing.initialize` is for a fresh exclusively owned
region; its preconditions are deliberately not a decoder for untrusted input.

| Offset | Type | Meaning |
|---|---|---|
| 0 | u32 | magic `TWAR`, numeric 0x52415754 |
| 4 | u32 | capacity in frames, nonzero power of two |
| 8 | u32 | channels, 1 or 2 |
| 12 | u32 | format: F32=1, signed I16=2 |
| 16 | u32 | sample rate, 44100 or 48000 |
| 20 | u32 | reserved zero |
| 24 | atomic u64 | monotonically wrapping write index, producer-owned |
| 32 | atomic u64 | monotonically wrapping read index, consumer-owned |
| 40 | atomic u64 | overrun calls, producer-owned |
| 48 | atomic u64 | underrun calls, consumer-owned |
| 56 | u64 | reserved zero |
| 64 | PCM[] | capacity × channels × sample bytes |

This is SPSC, including across processes. Indices publish sample copies with
full memory barriers (Darwin OSAtomic 64-bit operations, stronger than required
acquire/release); other implementations may use lock-free acquire loads and
release stores. Never use ordinary loads/stores for the four atomic words.
Do not share an owning AudioRing object across processes: share its raw region
via `XPCDeviceChannel.sendSharedMemory` (`tw.shmem`, xpc_shmem_create), map it with
xpc_shmem_map, retain the XPC object/mapping, then construct a nonowning view.
H7 must associate each mapping with an endpoint **before** configure/start.

Data offset is `64 + ((index & (capacity-1))*channels + channel)*sampleBytes`.
Use `requiredBytes` for checked sizing. A read fills the entire requested output
with data followed by silence, returning actual frames consumed. A write returns
actual frames accepted. Counters count affected calls, not lost frames. I16
conversion clamps [-1,1] to [-32768,32767]; non-finite float-to-I16 becomes zero.
Ring and frame operations use no Foundation and allocate no steady-state memory.

## Family 2 frame kinds

Outer header is the 32-byte `HostedDeviceWire` TWHD header, version 1. All fields
below are packed little-endian; payload lengths are exact. Endpoint is u32:
1 playback, 2 capture. Header timestamps use mach_continuous_time converted to
nanoseconds; sequence identifies a command and is echoed in status. Data flows
through the mapped PCM rings, not frame payloads.

| Kind | Direction | Payload |
|---|---|---|
| 1 open | driver→host | endpoint u32 |
| 2 configure | driver→host | endpoint, rate, channels, format, capacity: five u32 |
| 3 start | driver→host | endpoint u32 |
| 4 stop | driver→host | endpoint u32 |
| 5 drain | driver→host | endpoint u32 (playback only) |
| 6 volume | driver→host | endpoint u32, gain F32 bits (finite 0…1) |
| 7 mute | driver→host | endpoint u32, boolean u32 (0/1) |
| 8 close | driver→host | endpoint u32 |
| 0x100 position | host→driver | endpoint u32, frames u64, hostTimeNs u64, queuedLatencyNs u64 |
| 0x101 gap | host→driver | endpoint u32, cumulative overruns u64, cumulative underruns u64 |
| 0x102 status | host→driver | endpoint u32, command kind u16, status u16 |
| 0xffff ping | either | empty |
| 0xfffe pong | either | empty; echo ping sequence/timestamp |

Position counts actual frames transferred (not silence inserted); latency is
queued frames × 1e9 / sampleRate, excluding unmeasured hardware pipeline latency.
Status: 0 success, 1 malformed/unknown kind, 2 configuration, 3 invalid state,
4 Core Audio failure, 5 no device. Unknown endpoint or invalid outer frame is
ignored. Configuration must match the already-mapped ring. Driver state changes
are optimistic; nonzero host status moves it to stopped and exposes `lastStatus`.
Callers must inspect status before proceeding on a real asynchronous transport.

Transitions: closed→open→configured→running; running→draining→stopped;
running/draining→stopped; configured/stopped→configured or running; any→closed.
Neither configure while running nor capture drain is allowed.
