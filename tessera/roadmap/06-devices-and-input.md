# 06 — Devices and input

How Tessera knows what hardware it has, and how a keypress becomes something an
application sees.

## Where it stands

The display card and framebuffer fallback still have fixed paths. Input no longer
does: MosaicDisplay enumerates `/dev/input`, opens each event node, and asks its
`EVIOCGBIT` capabilities before deciding that it is a keyboard. The services boot
proves this with `keyboard discovered by EVIOCGBIT at /dev/input/event0`. A
second display on `card1` is still invisible, and there is no hotplug.

`CONFIG_VIRTIO_INPUT` and `CONFIG_INPUT_EVDEV` are on because the `virt` board
has no PS/2 controller.

## Enumeration

Hardcoded paths are correct for exactly one machine, and Tessera runs on one
machine today. The cost of that shows up the first time there are two of
anything.

`/dev/input/` holds `event0`, `event1`, … with no indication of what each is.
The answer is `EVIOCGBIT`, an ioctl that reports which event types a device
emits: a thing that reports `EV_KEY` with keyboard keycodes is a keyboard, a
thing that reports `EV_REL` is a mouse, a thing that reports `EV_ABS` with
`ABS_MT_*` is a touchscreen. That is how every input stack on Linux does it and
there is no shortcut.

Similarly `/dev/dri/card*` — open each, ask for its resources, take the one with
a connected connector.

Both need `getdents64` ([05](05-storage-and-state.md)) and both need
`EVIOCGBIT`, which is another ioctl whose request number is computed rather than
remembered.

**This belongs in the display server**, not in PID 1 and not in a library: it is
the process that owns the display and the input, and enumeration is how it finds
them.

## Input

### The pipeline

    evdev  →  display server  →  focus  →  the client that has it

The display server opens every input device, reads events, decides who they are
for, and forwards them over the protocol ([08](08-display-server.md)). A client
never opens an input device. That is not a security decision so much as a
correctness one — two processes reading the same evdev node both get every
event.

### What arrives

`struct input_event`: eight bytes of seconds, eight of microseconds, then `type`
and `code` packed into the word at offset 16, and `value` at 20. Twenty-four
bytes, always a whole number of them. `EV_KEY` is 1, `EV_REL` is 2, `EV_ABS` is
3, `EV_SYN` is 0.

`EV_SYN` is the one that gets skipped and should not be. It ends a group of
events that happened together, which is what makes a mouse's two axes one
movement rather than two, and what lets a keyboard report a modifier and a key
in the same instant. **Events are batched between syncs and delivered as a
batch.**

### Keycodes are not characters

A keycode is a position on a keyboard. `30` is the key where `a` is on a US
layout and where `q` is on a French one. Turning one into a character needs a
keymap, and a keymap is a real piece of work: layouts, modifier levels, dead
keys, compose sequences.

Tessera's honest first answer is **one built-in layout, US, compiled in**, with
a note that this is a placeholder. The second answer is XKB keymaps, which are
the only sane source of layout data and which mean either linking `libxkbcommon`
(a glibc-carrying program can) or parsing a subset in Kira.

What must not happen is a keymap invented ad hoc, because every application will
then inherit its gaps.

Modifier state — shift, control, alt, and the lock keys — is the display
server's, tracked across events and sent to the client with each key so that a
client never has to reconstruct it.

### Repeat

The kernel repeats keys when it feels like it (`value == 2`). A UI usually wants
its own repeat rate and its own delay, and wants repeat to stop when focus
moves. The display server should synthesise repeat from a timer and ignore the
kernel's, which needs `timerfd` ([02](02-kernel-and-syscalls.md)).

### The pointer

`EV_REL` with `REL_X`, `REL_Y` and `REL_WHEEL`; buttons as `EV_KEY` with codes
from `BTN_LEFT` up. The display server accumulates motion into a position,
clamps it to the display, and draws a cursor.

**The cursor is a compositor problem, not a client one.** Two ways to draw it: a
DRM cursor plane, which is a hardware overlay the display never composites into
the frame — free, and moves without a redraw — or a quad drawn on top of the
scene, which always works. virtio-gpu's cursor plane support should be checked
before relying on it; the fallback is not expensive.

### Touch, and everything else

`EV_ABS` with the multitouch protocol. The S23+ (dm2q) is the first machine
with a touchscreen. MosaicDisplay holds a touchscreen as an absolute pointer:
the reported touch position places it, and the contact (`BTN_TOUCH`)
is the primary button. Further fingers and gestures are not delivered yet.

A screen with a broken digitizer keeps a dead zone. Settings > Developer turns
on developer mode (`developer.mode`) and picks an edge
(`developer.dead-zone.edge`) and a share of the screen
(`developer.dead-zone.percent`, 50 when unset). LibTessera's `DeadZone.kira`
reads them. MosaicDisplay lays the output out in what the zone leaves, draws
the composition there through Ember's pass draw area, and drops presses whose
touch lands in the zone. At boot Adaptive Mobile shows a banner while a zone is
kept; tapping it sets the edge to `none`.

## Hotplug

Devices appearing and disappearing arrive as messages on a netlink socket
(`NETLINK_KOBJECT_UEVENT`). That needs the socket family
([04](04-ipc.md)), and it is the reason netlink is on the list at all.

Without it, a keyboard plugged in after boot does not exist. On a VM that is
academic. On hardware it is the first thing anyone notices.

The minimum version: listen, and on an `add` or `remove` for a device in the
`input` or `drm` subsystem, re-enumerate. Nothing clever, and no attempt to be
`udev` — there are no device permissions to set and no rules to run, because
everything runs as root and there is nothing to run.

## Network

`CONFIG_VIRTIO_NET` and `CONFIG_INET` are on and no userland has ever opened a
socket. Once the socket family exists ([04](04-ipc.md)), a network stack is
mostly configuration: an address, a route, a resolver.

**Later, but no longer optional.** A person installs applications Tessera did not
build ([12](12-apps.md)), and while sideloading from a volume is the first path
and should never become second-class, most software arrives over a network.

What does not follow is a browser ([01](01-principles.md) says no) or a
system-wide package manager ([13](13-security-and-updates.md): the system updates
as a whole volume). What is needed is smaller: an address, a route, a resolver,
and the ability to fetch a file. A sealed system with a network is a larger
attack surface than one without, and the answer is that the system's own software
does not listen on anything.

## Sound, USB, RTC, power

None configured. Each is a decision rather than an oversight:

- **Sound** matters the first time an application wants to make a noise, and
  ALSA is a large surface. Not on the critical path.
- **USB** is a controller and a hub for the sake of devices virtio already
  provides. On real hardware it is unavoidable; on the `virt` board it is
  avoidable and avoided.
- **RTC** — the machine currently does not know what time it is. That is
  invisible until something shows a clock or writes a timestamp.
- **Power** — battery, lid, sleep. All of it is meaningless in a VM and all of
  it is table stakes on a laptop.

## Checkpoints

- [x] Input devices are found by asking what they emit rather than by path.
      MosaicDisplay enumerates `/dev/input` and selects a keyboard through
      `EVIOCGBIT`; the boot test still routes the injected key through it.
- [x] The pointer moves a cursor on the display. MosaicDisplay draws the
      cursor into the composed picture where there is no cursor plane, and
      moves it with every pointer; the multi boot moves the virtio mouse onto
      a Stage Manager strip picture at 89,184 and asserts the press lands on
      that surface (`a press landed on a surface without focus|surface: 2`).
- [x] Modifier state is tracked and delivered with each key. The multi boot
      sends Shift-C and asserts `a key arrived with a modifier held|client: 2|
      key: 6|state: "pressed"|text: "C"|shift: true`.
- [x] Key repeat comes from a timer, at a rate Tessera chose. MosaicDisplay
      drops the kernel's repeats and arms a timer on its loop's port: 500 ms,
      then every 33 ms (`Input/Repeat.kira`). The multi boot holds B for
      1250 ms and asserts `a key repeated|client: 2|key: 5`.
- [x] A keycode becomes a character through a keymap that is named rather than
      improvised. `Keymaps.us` (`Input/Keymap.kira`) gives each key its text,
      which the key carries on the wire; the multi boot asserts `text: "a"` at
      client 3.
- [x] A device plugged in after boot is noticed. MosaicDisplay watches
      DeviceKit's registry for input devices (`Input/Hotplug.kira`); the multi
      boot plugs a USB keyboard in and pulls it out and asserts
      `found a keyboard|keyboards: 3` and `a keyboard went away|keyboards: 2`.
      The Devices service sees a USB speaker come and go the same way.
