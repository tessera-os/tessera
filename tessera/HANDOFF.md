# Handoff

Everything learnt taking Tessera from "builds inside a Fedora WSL distribution"
to "boots on Apple silicon, renders on the GPU through Metal, runs a supervised
display service that sets its own mode and draws its logo on it, reaches the GPU
through WebGPU, and stops cleanly when told to" — and then, after the compiler
moved into the Kira Language Framework, to "boots on x86_64 Linux too", and
then to "the SDK is Kira and RIDL, with Vulkan the one native library" (§10c).

Written for someone starting with no memory of any of it.

---

## 0. What this repository is built against

**An installed Kira compiler, the Kira libraries in `../../kira-projects`, and
the framework's LLVM bundle.** That is the whole of the coupling, besides the
sysroot (below).

Kira is a language of the Kira Language Framework. `klf` is the framework
binary, and the compiler is a driver built from the `.klfd` definitions in the
`klf-kira` checkout and installed as `kira` under `~/.klf`:

```sh
klf build ../klf-kira/languages/kira -o kira     # the native driver
cd ../kira-language-framework && knvm klf binstall   # the framework first
cd ../klf-kira && knvm binstall                 # build, register and install it
```

`knvm binstall` builds the driver with the `klf` toolchain knvm has installed,
not with the framework checkout. Run `knvm klf binstall` first whenever the
framework changed, or the driver comes out without what the framework added:
a stale one emits a `.ridl` of 613 `arg0: RawPtr` functions instead of the
library's surface.

`/root/.klf/bin/kira` is a **launcher**, not the compiler: it reads
`~/.klf/toolchains/kira/current.toml` and dispatches to the channel named there,
which on this host is `dev/0.1.0`. So `kira --version` reports the installed
channel rather than the state of any checkout:

    channel = "dev"
    version = "0.1.0"
    primary = "kira"

`scripts/lib.sh`'s `kira_compiler` answers with `TESSERA_KIRA` if it is set, then
that launcher, then whatever `kira` is on the PATH. There is no
`~/.kira/bin/kira` launcher in use any more.

**Kira is this project's own repository, not a third party.** An earlier handoff
read as though it were, and a roadmap section was written proposing an elaborate
patch-and-stamp mechanism to apply a diff to a sibling checkout. The answer was
always to commit it.

### The old Kira checkout is not needed

The Rust implementation of Kira (`kira-projects/kira`) is archived and nothing
here reads it. No manifest names `packages/linux` any more: libtessera's
`app/Backend/Linux/` declares every system call this userland makes, and every
other package reaches the kernel through LibTessera (roadmap/16 §25). An
installed toolchain carries its own Foundation, so `kira_foundation` and
`TESSERA_KIRA_FOUNDATION` are gone. The checkout's last use was its LLVM pin;
`scripts/lib.sh`'s `host_llvm_home` now takes the newest bundle under
`~/.kira/toolchains/llvm` that carries clang, which is the bundle the
framework links with (`provisioned_llvm` in `klf-driver`), so `kira_checkout`
and `TESSERA_KIRA_CHECKOUT` are gone too. `TESSERA_LLVM` still names a bundle
outright.

### The target's C library, for a cross build

The framework builds every target with the clang in the LLVM bundle Kira
provisions. That bundle carries a compiler and no C library, so there is no
second toolchain to fetch: what differs between targets is only where the C
library comes from. `crates/klf-frontend-rt/src/toolchain.rs`'s
`CToolchain::for_target` in the `../kira-language-framework` checkout is where
that decision lives, and it comes down to three cases:

- the host's own triple takes no sysroot at all, because the host's C library is
  the target's C library
- an Apple target takes `-isysroot` from `xcrun --show-sdk-path`
- any other target takes `--sysroot` from the environment

So a cross build needs one thing: a sysroot holding the target's C library.
`scripts/lib.sh`'s `require_cross_sysroot` finds it and exports it as
`KLF_SYSROOT`, and the framework reads two variables, in this order:

    KLF_SYSROOT_<TRIPLE>   that target's own, dashes as underscores
    KLF_SYSROOT            whichever target is being built

Two names because a machine building for two targets has two C libraries and
neither is a sensible default for the other, while a user with one cross target
should not have to spell the triple. The per-target name answers first, so the
plain one is never asked when the specific one is set. With neither set:

    kira: error: building for `aarch64-unknown-linux-gnu` on `x86_64-unknown-linux-gnu` needs a sysroot
    holding that target's C library; set KLF_SYSROOT_AARCH64_UNKNOWN_LINUX_GNU or KLF_SYSROOT to it

**A sysroot is checked for an unwinder before the link.** A Linux program links
`-lgcc_s` — the shared half of the target's GCC runtime — so the sysroot has to
hold `libgcc_s.so.1` or `libgcc_s.a`, and the framework refuses otherwise:

    kira: error: the sysroot at <path> holds no `libgcc_s.so.1` or `libgcc_s.a`, which is the unwinder a
    `<target>` program links; install the target's GCC runtime into it

`libgcc_eh.a` does not count, and the framework accepted it until commit
`398e38e` in `../kira-language-framework`. That is what clang's *static*-link
spec asks for. A program that links `-lgcc_s` does not link it, so a sysroot
holding only that one produced the linker error the check was written to name.
It is also all that a stock Fedora aarch64 sysroot holds, before
`setup-host.sh` runs, which is what made the mistake matter.

The compiler installed at `~/.klf` on this host predates that commit, so it
still prints the three-name form:

    kira: error: the sysroot at /tmp/opencode/empty-sysroot holds no `libgcc_s.so.1`, `libgcc_s.a` or `libgcc_eh.a`, which is the unwinder a `aarch64-unknown-linux-gnu` program links; install the target's GCC runtime into it

`knvm binstall` on the current framework checkout drops `libgcc_eh.a` from that
list. The aarch64 build here does not depend on which of the two is installed,
because `scripts/setup-host.sh` put `libgcc_s.so.1` and `libgcc_s.so` in the
sysroot.

The check is worth keeping rather than passing `--unwindlib=none`, because a
sysroot is a package set the user installs: an incomplete one is theirs to fix
and deserves a message naming the missing file. The flag produces a binary that
needs a `libgcc_s.so.1` the guest does not have, and the user finds out at boot
rather than at build.

**Fedora's aarch64 sysroot is genuinely incomplete for this**, which is why
`scripts/setup-host.sh` has `stage_shared_unwinder`. The distribution's cross
gcc ships the static half of the GCC runtime into the sysroot (`libgcc.a`,
`libgcc_eh.a`) and keeps the shared half out of it, so the link fails with
`unable to find library -lgcc_s`, naming the linker rather than the package that
was left out. The script copies in the one file from Debian's `libgcc-s1`
package, for the reason the rest of the target's C library comes from there when
it is not already present: it is one file with a fixed name and no Fedora
package provides it. It then writes `libgcc_s.so` beside it, and that detail cost
a build here: `-lgcc_s` asks the linker for the unversioned name, not the SONAME,
so with only the `.so.1` present the link still fails.

On a Darwin host the same file arrives with the rest: `libgcc-s1-arm64-cross` is
one of the Debian `-arm64-cross` packages `setup-host.sh` stages, and it carries
both names.

`scripts/setup-host.sh` also adds the Rust standard library for each cross target
through `rustup`, because the framework's runtime is Rust and a cross build
compiles every object before saying `can't find crate for 'std'`.

### The system call table is the framework's, not ours

`@FFI.Syscall { name: ... }` resolves through `crates/klf-kir/src/syscalls.rs`
in `../kira-language-framework`, which carries the whole Linux 7.0 table by name
for both architectures: 327 calls for aarch64, 369 for x86-64. Nothing has to be
added to it for Tessera to make a call, and the earlier arrangement — a curated
63-entry table in `../kira`'s `crates/kira-runtime-abi/src/syscall/mod.rs`,
uncommitted in that checkout's working tree for two sessions and fatal to lose —
belongs to the 1.9.1 compiler this project no longer builds against. That table
still has 51 entries and still has no socket calls; the socket calls this
userland makes resolve in the framework's table. `error[KSEM279]` and the
symptom this section used to warn about exist in no compiler Tessera reaches.

The three calls added late are in the framework's table already, at the numbers
`linux-7.2`'s own `include/uapi/asm-generic/unistd.h` (aarch64) and
`arch/x86/entry/syscalls/syscall_64.tbl` (x86-64) give:

    clone3              435 on both architectures
    waitid               95 aarch64, 247 x86-64
    pidfd_send_signal   424 on both

Legacy `clone` takes its arguments positionally and the last two are in a
different order on aarch64 than on x86-64, so the same source is a different
call per architecture and the mistake is silent. `clone3` takes a
`struct clone_args` and a size, identically everywhere — which is also the shape
this userland is good at, since building a structure at byte offsets is exactly
what Kira's typed memory is for. It carries `CLONE_PIDFD`, which answers with a
descriptor for the child: that is what lets PID 1 wait for a service to die in
the same `ppoll` as everything else, and signal it without the race that a
recycled process identifier is.

---

## 1. The machines this was done on

Most of the graphics work was done on the first of these; the compiler migration
and everything verified on Linux was done on the second.

- Apple M1, macOS 27 (pre-release; Homebrew warns about it, harmlessly).
  - Host page size 16K. This matters more than anything else on its list.
  - `~/Code/kira-projects/` holds `tessera`, `kira`, `klf-kira`, `kira-ui`,
    `ui-foundation`, `ember`, and about twenty other siblings.
- Fedora, x86_64 Linux.
  - `~/Dev/kira-projects/` holds the same siblings.
  - x86_64 is native here and aarch64 is the cross target.
  - QEMU's TCG aarch64 emulation produces no console output from the kernel on
    this host, so aarch64 boots cannot be observed here at all. See §3.
- Build root `~/.tessera-build/`, never inside the repository:
  - `src/linux-7.2/` — the kernel, patched in place, with `.tessera-patches/`
    stamps recording which patches were applied
  - `out/<arch>/` — `kernel/`, `initramfs.cpio.zst`, `system.img`, `graphics.img`,
    and the staged `rootfs/` the initramfs is packed from
  - `sysroot/aarch64-linux-gnu/` — Debian's cross glibc, staged. Darwin only:
    on Fedora the target's C library is a system directory,
    `/usr/aarch64-redhat-linux/sys-root/<release>`, which `arch_sysroot` finds
  - `sysroot-staging/` — scratch space for unpacking the `.deb` a sysroot needs
  - `gpu/` — host and guest graphics stacks, sources and prefixes
  - `logs/` — `boot-<arch>.log`, `kernel-mac.log`, `mesa-build.log`, others
- Disk ran out once mid-session. A kernel with DWARF needs ~3 GB for the final
  link alone; the GPU source trees are another ~2 GB. Keep 6 GB free.
- There is no `toolchains/` here any more. `$BUILD_ROOT/toolchains/zig-0.15.2/`
  was the Zig cross toolchain and nothing writes to it now; a copy left on a host
  that ran `setup` before the removal is dead weight, and `rm` it.

---

## 2. Building and running

    kira build setup                         # once. Knows Fedora, Debian and Darwin
    kira build sysroot -arch aarch64         # Debian's libraries, Mesa venus, Vulkan loader, libdrm
    kira build host-gpu                      # virglrenderer + QEMU, patched
    kira build kosmickrisp                   # on a Mac: Mesa's Vulkan over Metal
    kira build boot -test                    # build, install, boot, assert
    kira build boot -tampered                # a system its seal does not cover: PID 1 refuses it
    kira build boot -interrupted             # an install stopped midway: PID 1 refuses the volume
    kira build boot -update                  # an update kept, then a failing one rolled back
    kira build boot -emulate yes -test       # the guest translated by TCG, as on a host of another architecture
    kira build boot -dev                     # the dev machine, left running
    kira build devroot install date          # one component onto it, no reboot
    kira build devroot uninstall date        # the sealed system's date again
    kira build devroot reset                 # every root goes at the next boot

`kira build boot` builds what changed and boots it from Kira in the build
package (build/app/Boot.kira). Install.kira boots the installer against
`~/.tessera-build/out/<arch>/volume.img` only when the system image's digest
differs from `volume.installed`, then the volume is booted (roadmap/05). The
checks of `-test` and every `-services` mode read the serial log and drive
QEMU's monitor (TestBoot.kira, BootServices.kira, BootScenarios.kira,
BootPlatforms.kira). Options are graph options, as
`kira build boot -output-size 2880x1800 -dev`.

Measured on x86_64 with a loaded 4-core host: a graph run with nothing
changed is about 2 s, and `kira build devroot install date` after an edit
to date about 5 s. An edit to date followed by `kira build boot -dev` has
the desktop on screen in about 11 s: 4 s building the image (system.img is
stored uncompressed, squashfs level 0), 3.5 s installing, 3.4 s from QEMU's
start to the desktop. The console is a virtio console (`hvc0`), because the
emulated UART traps on every byte; the kernel logs at `loglevel=4` unless
`-kernel-log all`. The boot log's lines arrive as the services write
them, so prefixing each with the host's time (as `ts` does) times the boot.

`setup` arranges the target's C library — a sysroot on both hosts, staged
`stage_shared_unwinder` included where the distribution's own leaves the shared
unwinder out — and adds the Rust standard library for each cross target, which
is what a cross Kira build needs from the host. See §0.

`kira build` is the one entry point; `kira build` with no step lists the
steps. The scripts left in `scripts/` are moving into the build package.

`scripts/build-runtime.sh` and `scripts/tessera runtime` are gone. Kira's
typed memory is a compiler builtin lowered in place and the Heap library is Kira
source, so no per-target runtime archive is built or staged. Kira links against the target's C library rather than folding
it in, which is the cost: every image with Kira code in it carries the loader
and the C library. `scripts/lib.sh`'s `guest_lib_dir`, `guest_loader` and
`guest_runtime_libs` answer where, and `build-initramfs.sh`, `build-system.sh`
and `build-installer.sh` all stage them.

`kira build` gained `-o <path>` and `--emit`, and lost `--sysroot`,
`--relocation-model`, `--linkage` and the fixed `.kira-build/<triple>/main` it
used to write. The build scripts name their own output:

    kira build --target x86_64-unknown-linux-gnu -o "$STAGING/init" ../init

### When a program traps

A trap prints its reason and `runtime trap KLF-RT-<code>`. The images are
stripped, with their debug information kept in each component's dSYM:
`kira build symbols` gathers them in `.kira-build/out/symbols/symbols/`, at
each binary's install path (the installer's under `installer/`). So the runtime does
not name frames. Instead it prints every word on the trapping thread's stack
that points into an executable segment, as `<image>+0x<address>`, innermost
first. Name each one on the host:

    llvm-symbolizer --obj=<that image's dSYM DWARF> 0x<address>

The return addresses of the frames that led to the trap are among them. Words
that only look like code addresses come out too.

For more, `QEMU_GDB=1` opens QEMU's gdbstub on port 1234, and the kernel loads
every program at the same addresses each boot (`norandmaps`). A program's PIE
base is then `0x555555554000`.

### Boot options, passed after `--` on the kernel command line

The kernel hands anything it does not recognise to init: a word with no `=`
arrives as an argument, a word with one arrives as an environment variable, and
this program only reads arguments.

- `tessera.autoexit` — start the services, then stop the machine through the
  same shutdown path a `SIGTERM` uses, so a boot test ends by itself
- `tessera.system` — mount the system `boot/current` names from the first
  btrfs disk, become it, execute the init inside
- `tessera.dev` — boot `system/dev`, a writable snapshot, with the sealed
  system read-only at `/var/db/devroots/base`, and run the dev root service

The kernel ends init's arguments at a second `--`, so the command line carries
exactly one; Boot.kira gathers every flag behind it.
- `tessera.restart-test` — kill the display once, on purpose, so a boot
  demonstrates supervision rather than asserting it

`tessera.input` and `tessera.shell` are gone. The keyboard belongs to the
display service now and is read unconditionally; the shell flag was a hole in
refuse-to-boot and had nothing left to exec.

---

## 3. What is verified, with the lines that prove it

Ordinary boot:

    tessera: userland reached, pid 1 is alive
    tessera: this init is a Kira program talking to the kernel directly

The x86_64 boot test passes end to end on this Fedora host, which it never did
before the migration to the framework-hosted compiler:

    $ bash scripts/run-qemu.sh x86_64 --test
    ==> boot test: x86_64
    ==> x86_64 booted to the initramfs userland (log: /root/.tessera-build/logs/boot-x86_64.log)

    $ bash scripts/run-qemu.sh x86_64 --services-media
    ==> boot test: x86_64
    ==> x86_64 booted to the services userland (log: /root/.tessera-build/logs/boot-x86_64.log)

What the display does in the `-test` boot, from the same log file that run
leaves behind:

    mosaicdisplay: the mode is set, the display is Tessera's
    mosaicdisplay: flipped to framebuffer 47, the splash is on the screen
    tessera: stopping mosaicdisplay
    tessera: mosaicdisplay was killed by signal 15
    tessera: every service is stopped, powering off

**aarch64 is verified by building it, not by booting it.** The cross build needs
a sysroot and no Zig, and the binary it produces is a correct aarch64
dynamically linked program:

    $ scripts/build-initramfs.sh aarch64
    ==> building init with Kira
    ==> aarch64 initramfs built: /root/.tessera-build/out/aarch64/initramfs.cpio.zst (4,2M)

    $ file /root/.tessera-build/out/aarch64/rootfs/init
    init: ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
          interpreter /lib/ld-linux-aarch64.so.1

    $ readelf -d /root/.tessera-build/out/aarch64/rootfs/init | grep NEEDED
    libm.so.6   libc.so.6   libgcc_s.so.1

That last line is the assertion for the cross toolchain: `-lgcc_s` resolved out
of the sysroot, so `scripts/setup-host.sh` staged a shared unwinder into it.
See §0.

The aarch64 boot test cannot run on this host. QEMU's TCG aarch64 emulation
produces no console output at all from the kernel, with or without an initramfs,
so the log is empty and the test times out:

    $ bash scripts/run-qemu.sh aarch64 --test
    ==> boot test: aarch64
    warn: aarch64 timed out after 300s without reaching userland
    --- last 40 lines of /root/.tessera-build/logs/boot-aarch64.log ---
    qemu-system-aarch64: terminating on signal 15 from pid 632244 (timeout)

That is an emulator and host limitation rather than a Tessera one, and it
predates the migration: `out/aarch64/kernel/arch/arm64/boot/Image` was built
before any of this work. No aarch64 boot has been observed here at any point,
so nothing above claims one.

A service being handed a descriptor over its channel — the first message ever
sent between two Tessera processes:

    tessera: handed display /etc/tessera-release over its channel
    mosaicdisplay: through a descriptor init opened —
    NAME="Tessera"
    VERSION="0.1.0"
    ARCH="aarch64"

The last three lines are the assertion. The display never opened that file and
has no path to it compiled in: it read a descriptor out of a message's ancillary
data and read the file through it.

Handover to the system volume:

    tessera: system volume mounted, handing over to /init
    tessera: system volume is the root, pid 1 is the system's own init

Refusal, with `tessera.system` and no disk:

    tessera: /dev/vda would not mount (ENOENT)
    tessera: refusing to boot: the system volume could not be mounted

GPU, through venus to MoltenVK to Metal:

    vk_smoke: device = Virtio-GPU Venus (Apple M1)
    vk_smoke: driver = venus (Mesa 25.0.7)
    vk_smoke: readback = 64 128 191 255 (want 64 128 191 255)
    vk_smoke: PASS — GPU cleared and read back through Vulkan

WebGPU on top of it, which is the layer Ember — and so Kira UI — draws
through. A WGSL source string compiled by Tint inside Dawn, lowered to SPIR-V,
carried across by venus and run by Metal:

    dawn_smoke: device = Virtio-GPU Venus (Apple M1)
    dawn_smoke: driver = venus: Mesa 25.0.7
    dawn_smoke: backend = Vulkan
    dawn_smoke: readback = 11 18 1796 (want 11 18 1796)
    dawn_smoke: PASS — WGSL compiled, ran on the GPU and read back through WebGPU
    tessera-gfx: PASS — every graphics test passed

The last line is what `--graphics` asserts on, and it is init's rather than any
one test's: a boot on which the second test never ran now fails instead of
passing on the first.

A supervised service that owns the display, started by an init that does not:

    info[TesseraInit.Service.Start]: started a service
        = service: "mosaicdisplay"
        = pid: 81
    mosaicdisplay: connector 40 is connected, 26 modes, first is 1280x800
    mosaicdisplay: crtc 39 drives connector 40 through encoder 41
    mosaicdisplay: two buffers of 1280x800, 5120 bytes a row
    mosaicdisplay: the mode is set, the display is Tessera's
    mosaicdisplay: flipped to framebuffer 47, the splash is on the screen
    mosaicdisplay: listening to /dev/input/event0

Supervision, with `tessera.restart-test` — a real `SIGKILL` through the real
path, and the restart that follows is not arranged:

    info[TesseraInit.Supervise.Loop]: tessera.restart-test was set; killing a service
        = service: "mosaicdisplay"
    warn[TesseraInit.Service.Reap]: a service was killed by a signal
        = service: "mosaicdisplay"
        = signal: 9
    info[TesseraInit.Service.Start]: started a service
        = service: "mosaicdisplay"
        = pid: 82

Shutdown, with `tessera.autoexit`:

    info[TesseraInit.main]: every service is up
    info[TesseraInit.Supervise.Shutdown]: shutting down
        = reason: "tessera.autoexit was set"
    info[TesseraInit.Supervise.Shutdown]: stopping a service
        = service: "mosaicdisplay"
    warn[TesseraInit.Service.Reap]: a service was killed by a signal
        = service: "mosaicdisplay"
        = signal: 15
    info[TesseraInit.Supervise.Shutdown]: every service is stopped; powering off
    [    0.945081] reboot: Power down

Signal 15 rather than 9 is the assertion worth keeping: it means the service was
*asked* and went, rather than being killed when the deadline ran out.

The screendump that follows a `-display` boot is 1280x800 — the mode PID 1
chose, not the console's — and holds exactly three greys: 25 for the ground,
222 for the tile, 16 for the mark, 3645 pixels of it. `tessera: drew the
splash, N bytes` is the older `/dev/fb0` path and now appears only when the
card could not be driven.

Input:

    tessera: listening to /dev/input/event0
    tessera: key 37 pressed        # K, then I, R, A

### DeviceKit and the device services

DeviceKit (`roadmap/17-devicekit.md`) is built through all five steps of its
§25. The `-services` boot asserts each of these entries, on x86_64 and
aarch64; the run fails when one is missing. The services and the platform
write with Kira's `log`, and BootLog.kira's `has("message|field|...")`
asserts one entry: its header holds the message, and the `= ` lines under
that header, up to the next one, hold every field. A field written under
another message does not count. A message two programs both say starts
with the end of its module, as in `Devices]: a device was added`. init
and tessera-ui write with `log` too, so `seen` takes an expectation
either way: `log:message|field|...` for an entry, anything else for a line
as printed. Printed lines are left to the console banner and to the
command-line tools, whose output is their answer. These are from x86_64 on
2026-10-08:

    $ scripts/run-qemu.sh x86_64 --services
    ==> boot test: x86_64
    ==> x86_64 booted to the services userland (log: /root/.tessera-build/logs/boot-x86_64.log)

    info[TesseraBootstrap.main]: listening
        = services: 3
    info[TesseraBootstrap.Broker.Broker]: a service checked in
        = service: "tessera.devices"
        = pid: 68
    info[AdaptiveDesktop.Desktop.Startup]: listed the services
        = count: 3
        = names: "tessera.devices, tessera.power, tessera.volume"
    info[TesseraDevices.main]: listening
        = audioOutputs: 2
    info[TesseraPower.main]: listening
        = powerSources: 0
        = thermalZones: 0
        = clocks: 1
    info[TesseraVolume.Volumes]: found a disk
       --> app/Volumes.kira:312:5
        = disk: "vda"
        = bytes: 4194304
        = blockBytes: 512
        = access: "read-only"
        = content: "ext4"
    info[TesseraVolume.Mount]: mounted a volume
       --> app/Mount.kira:150:5
        = disk: "vda"
        = mountPoint: "/Volumes/scratch"
        = filesystem: "ext4"
        = readOnly: true
        = holds: "lost+found"
    info[AdaptiveDesktop.Desktop.Startup]: read the power state
        = externalPower: 1
        = battery: "none"
        = thermalLevel: 0
    info[AdaptiveDesktop.Desktop.Startup]: listed the audio outputs
        = count: 2
    info[AdaptiveDesktop.Desktop.Startup]: played the startup chime
        = bytes: 19200
    info[DeviceKitManager.Manager.Drivers]: started a driver
        = driver: "ccid-driver"
        = entry: 4708322830147896435
        = pid: 73
    info[TesseraCcidDriver.main]: found a reader
        = device: "08e6:4433"
        = interface: 0
    info[TesseraCcidDriver.main]: read a slot
        = slot: 0
        = card: "no card"
    info[DeviceKitManager.Manager.Published]: a driver published an entry
        = program: "/System/Library/DriverExtensions/ccid-driver.dext/ccid-driver"
        = id: 13931131917049250931
    info[TesseraTabletDriver.main]: found a tablet
        = device: "0627:0001"
        = interface: 0
    info[TesseraTabletDriver.main]: claimed the interface from the kernel's driver
    info[TesseraTabletDriver.main]: read the report descriptor
        = bytes: 74

bootstrap, the services, devicekitd and the drivers log through Kira's
`log`: a level, the module and file, a message that stays the same, and
the values as fields under it. `KIRA_LOG` picks the levels shown. init and
the platforms still print their own lines and move to `log` one by one. The
excerpts here leave out each entry's source line and some fields.

The scratch disk is a 4 MiB ext4 image the graph makes (Disks.kira) and the boot attaches
read-only. The chime goes to the ALSA loopback card. The reader is QEMU's
`usb-ccid` on a `qemu-xhci` controller, with no card in it. The tablet is
QEMU's `usb-tablet` on the same controller. The kernel's usbhid binds it
first, and `tablet-driver`, whose manifest may detach a kernel driver,
takes its interface away.

The Volume service lets go of a volume when asked, as diskarbitrationd
does. `diskutil`, after macOS's, asks it over the broker. init's table
carries a program's arguments now, as launchd's `ProgramArguments` does,
so a boot can run `diskutil` with a verb. `-services-multi` runs
`diskutil unmount scratch` and `-services-restart` runs `diskutil eject
scratch`:

    info[TesseraVolume.Eject]: unmounted a volume
        = disk: "vda"
        = mountPoint: "/Volumes/scratch"
    info[TesseraVolume.Eject]: ejected a disk
        = disk: "vda"
    Disk vda ejected
    tessera: diskutil exited 0

The service follows disks that come and go through two DeviceKit registry
watches. `-services-media` plugs a USB stick, a 4 MiB ext4 image labelled
`stick`, into the xHCI controller through QEMU's monitor once the
services run, then pulls it out. The service mounts it read-write at
`/Volumes/stick` and detaches the mount when the stick goes:

    info[TesseraVolume.Mount]: mounted a volume
        = disk: "sda"
        = mountPoint: "/Volumes/stick"
        = readOnly: false
    info[TesseraVolume.Hotplug]: a disk went away; its volume was unmounted
        = disk: "sda"
        = mountPoint: "/Volumes/stick"

The media boot also runs `diskutil activity`, which keeps a `Watch`
channel to the service open and prints what it hears, as macOS's
`diskutil activity` prints DiskArbitration's callbacks:

    ***DiskAppeared ('vda', DAVolumePath = '/Volumes/scratch', DAVolumeKind = 'ext4')
    ***DiskAppeared ('vdb', DAVolumePath = '<null>', DAVolumeKind = 'empty')
    ***DAIdle (no more changes in the near future)
    ***DiskAppeared ('sda', DAVolumePath = '<null>', DAVolumeKind = 'ext4')
    ***DiskDescriptionChanged ('sda', DAVolumePath = '/Volumes/stick', DAVolumeKind = 'ext4')
    ***DiskDisappeared ('sda', DAVolumePath = '/Volumes/stick', DAVolumeKind = 'ext4')

The mobile boot runs `diskutil info scratch`, and the plain services boot
runs `diskutil list /dev/vda`, in macOS's columns, and asserts it leaves
the data disk out:

    /dev/vda (internal):
       #:                       TYPE NAME                          SIZE   IDENTIFIER
       0:                       ext4 scratch                    *4.2 MB   vda

Every mount and unmount after
the first scan is posted as `System/volumeChanged` to every System channel,
as NSWorkspace posts didMount and didUnmount, and the multi boot asserts
that the platform hears `/Volumes/scratch was unmounted`.

The media boot runs `pmset -g` too, after macOS's, which reads the Power
service's page through `Power.read`. QEMU's machine has no battery:

    Now drawing from 'AC Power'
    Note: No thermal warning level has been recorded
    Note: No CPU power status has been recorded

The mobile boot runs `caffeinate -i -t 1`, which holds a WakeLock for a
second. The Power service logs it under the reason the client gave:

    info[TesseraPower.Service.Clients]: a wake lock was taken
        = program: "/bin/caffeinate"
        = kind: "CPU"
        = seconds: 1
        = reason: "caffeinate command-line tool"
    info[TesseraPower.Service.Clients]: a wake lock was released
        = program: "/bin/caffeinate"
        = reason: "caffeinate command-line tool"

The multi boot runs `date 010100002030`, after macOS's `date`, which sets
the clock with the kernel's own call. The Power service sees Realtime jump
against Monotonic on its next tick and posts `timeChanged`, and the platform
shows the new time. date runs as `caffeinate -i date 010100002030`, as
macOS's caffeinate runs a utility under its assertion: the Power service
answers the wake lock from its loop, after it has begun to watch the clock.
Run straight from init, date set the clock on an aarch64 boot before the
service watched it, and the jump went unseen.

    Tue Jan  1 00:00:00 UTC 2030
    info[TesseraPower.Service.Clock]: the clock was set
        = forward: true
        = seconds: 102498...
    info[AdaptiveDesktop.Desktop.Clock]: the clock was set
        = now: "2030-01-01 00:00 UTC"

The restart boot runs `ioreg -l -c BlockDevice`, after macOS's `ioreg`,
which prints the registry's block devices and their properties. Without
`-c` it prints the whole registry as a tree under each entry's parent in
the Service plane.
Among its lines, from an x86_64 boot:

    +-o vda  <class BlockDevice, id 0x7d79c9da93f7c637>
        "busType" = "virtio"
        "driver" = "virtio_blk"
        "size" = 4194304

Every service is reached through the broker, `bootstrap`
(`roadmap/16-libtessera.md` §25.4). The `-services-restart` boot kills it
once the services have checked in, and fails unless they check in again
with the broker init restarts:

    info[TesseraInit.Supervise.Loop]: tessera.restart-test was set; killing a service
        = service: "bootstrap"
    warn[TesseraInit.Service.Reap]: a service was killed by a signal
        = service: "bootstrap"
        = signal: 9
    info[TesseraInit.Service.Start]: started a service
        = service: "bootstrap"
        = pid: 78
    info[TesseraBootstrap.main]: listening
        = services: 3
    info[TesseraBootstrap.Broker.Broker]: a service checked in
        = service: "tessera.devices"

A client reaches the broker on its System channel, one connection it
keeps while it runs, over which `connectService` and `listServices` are
calls with the §10.3 header. The services boots assert that the platform
holds one:

    info[TesseraBootstrap.Broker.Broker]: a program holds a System channel
        = program: "/bin/adaptive-desktop"
        = pid: 73

Events come down the same channel. The Devices service watches the
registry for audio endpoints, cameras and haptic devices and posts each
one that comes or goes through the broker, which sends it to every
process entitled to its class. `-services-multi` plugs QEMU's
`usb-audio` speaker into the xHCI controller and pulls it out; the
kernel now carries `snd-usb-audio` for it:

    info[TesseraDevices.Service.Changes]: a device was added
        = kind: "audio output"
        = device: "Audio 0"
    info[TesseraBootstrap.Broker.System]: a service posted an event
        = service: "tessera.devices"
        = channels: 1
    info[AdaptiveDesktop.Desktop.Devices]: a device was added
        = kind: "audio output"
        = name: "Audio 0"
    info[TesseraDevices.Service.Changes]: a device was removed
    info[AdaptiveDesktop.Desktop.Devices]: a device was removed
        = kind: "audio output"
        = name: "Audio 0"

The platform names a device that comes from `Device.list`, and keeps the
name, so it can say which one went once the service no longer lists it.

The platform's session loop blocks reading the display channel, so it
looks at its System channel between display messages, at least four
times a second.
When the broker is killed in `-services-restart`, the platform's read
answers `PeerClosed` and it asks for its System channel again:

    warn[AdaptiveDesktop.Desktop.Devices]: the System channel closed; connecting again
    info[TesseraBootstrap.Broker.Broker]: a program holds a System channel
        = program: "/bin/adaptive-desktop"
        = pid: 72
    info[AdaptiveDesktop.Desktop.Devices]: watching for devices again

The broker's one-shot `Connect` and `List` are gone with it: a client's
only connection to the broker is its System channel, and a service's
its check-in.

Two things this took that are easy to trip on again. Memory objects and
mappings are whole pages, and a page is 16 KiB on aarch64: every size that
assumed 4096 now asks `System.info(.Machine)`. And under TCG a sysfs walk is
slow enough that a service which scanned before it listened missed its
clients' first requests, so the services listen first, and DeviceKit keeps
its walk until a uevent says it changed.

### Freeform windows: move, resize, and the input hold

MosaicDisplay follows the pointer itself once the platform grants a move or a
resize (`roadmap/08-display-server.md`, "Windows"). A press in the band along a
freeform window's edge, 6 pixels outside to 2 inside, is the server's: it asks
the platform for the resize, and the window is configured at each size it
passes through, one configure in flight at a time (`Input/Resize.kira`). Over
the band the cursor is the Mac's double-headed arrow; the five shapes are
painted once at start in `Float` (`Display/CursorShapes.kira`). In decimal
`Number` they took twelve seconds of CPU, and the platform's first messages
waited behind them long enough to fail every services boot.

`/root/scratch/qresize.sh` boots `-dev`, opens Notes, drags its bottom
trailing corner and its leading edge, and takes screenshots. It logs
`a press took a window's edge`, `the platform granted a resize` and
`a resize ended|width: 973|height: 531`.

While a bar menu or the switcher is out, Adaptive Desktop sends
`hold_input(true)` instead of taking focus. Keys and the pointer go to the
platform, and the window in front keeps focus and its coloured traffic
lights, as on a Mac. The lock screen still takes focus.

`BootLog.has` matches a bare-number field whole:
`key: 4` used to match `key: 44`, and a services check passed on the space
key.

### Frames, keys and input devices in MosaicDisplay

Frames are exchanged one message at a time (`Channel/Exchange.kira`). A
client's `FrameRequest`, `Attach` and `Commit` are each taken as they arrive,
from the one wait the loop makes, and the client's `FrameExchange` remembers
where it is. Nothing waits on a client, so a slow window holds up no key and no
other client. The old code read a whole exchange inline and parked any other
message in a `held` list.

Keys carry their modifiers, their text and their time. The wire is version
2: six 32-bit words from offset 16 and a 64-bit word at 40. `Key` sends the
usage, the state, the provenance, the modifiers as bits (shift 1, control 2,
option 4, command 8, caps lock 16), up to four UTF-8 bytes of text, first byte
lowest, and milliseconds of the monotonic clock. The text comes from a named
keymap (`Input/Keymap.kira`, `Keymaps.us`), and the modifiers from the keys held
down. KiraUI takes the codepoint from the text and no longer rebuilds the
modifiers itself.

Repeat is the server's. The kernel's repeat records are dropped. A press
arms a timer on the loop's port (500 ms, then every 33 ms); the repeat stops when
the key comes up, or when keys would go somewhere else (`Input/Repeat.kira`).

Every keyboard types and every pointer moves the cursor, as on a Mac
(`Input/Hotplug.kira`). A DeviceKit registry watch on input devices wakes the
loop. Its first read names the devices already there, so boot and hotplug take
the same path. Each device has its own port key: `PortKey.keyboard` or
`PortKey.pointer` plus a serial. A device that goes, or stops answering, is
closed and what it held down is let go. The display server keeps running, and
clients hear that there are no keys only when the last keyboard goes. The multi
boot plugs a USB keyboard in and pulls it out (`found a keyboard|keyboards: 3`,
`a keyboard went away|keyboards: 2`). The VM already has two keyboards when it
boots, so the count starts at 2.

The splash and the cursor are painted in `Float`. Decimal `Number` is slow
when it runs per pixel. The splash took about 11 s in `Number` and pushed every
services boot past QEMU's 20 s. Its tile and mark are now signed distances,
sampled 4×4 only near an edge (`Brand/`).

A boot that looks hung may be QEMU's timeout. TestBoot.kira kills QEMU at
20 s for `-services` and 40 s for `-services-restart` and `-services-multi`.
`qemu-x86_64.log` then says `terminating on signal 15`. To see where the time
goes, sample `info registers -a` on the monitor every half second, and map RIP
to a binary and a symbol with `llvm-symbolizer`.

Foundation's log prints a site's first four events, then only the 8th, 16th
and so on, whatever the values. A test must not look for the fifth event from
one site. `relayoutAll` logs one `laid the surfaces out` event with every
placement for that reason. `setMode` logs `the mode changed` with the layout
it produced (`layout:`), so a test can follow mode changes past the fourth
layout.

### Stage Manager

`CompositorMode.Stage` (4) is the compositor's half (`mosaicdisplay`
`Display/Stage.kira`). The application in front is on the stage: the focused
one when it is an application, otherwise the shown one highest in the stacking
order. It is configured to `stageWindow`. Every other shown application keeps
that configured frame too, but is drawn scaled into its strip slot
(`placedFrame`), and the pointer finds it there (`hitFrame`). A press on a strip
picture arrives at the platform as `SurfacePressed`, and the platform's focus
grant brings it to the stage. The layout numbers live in display-client
(`Channel/Stage.kira`, `StageLayout`, `stageSlot`), so the platform's icons and
the compositor's pictures agree.

PlatformKit orders the strip (`Core/Stage.kira`: `stagedSurface`,
`stripSurfaces`) by the platform's own z-order, which follows the same focus
grants as the compositor's. PlatformUI's `StageStrip` draws the icons. It
places them with `edgePadding` in a top-leading `ZStack`, because KiraUI has no
`.offset` or `.position` yet. Adding one means a translation in
KCoreAnimation's `CALayerDescription`.

Adaptive Desktop grabs F6 (usage 63) to turn it on and off. On leaving a
freeform mode, the compositor keeps every application window's frame
(`Client.windowFrame`). The freeform arm of `geometryFor` gives it back, and
it is cleared once freeform is back. The multi boot presses F6 twice and
asserts both layouts.

### Notifications

What a notification says goes over the AppKit link, not the display wire.
The display protocol's `Notify` carries only an id and a priority.
`addNotification` in KiraUI (`Tessera/Notifications.kira`, a platform file)
calls AppKit's `postNotification`, which writes a `Notify` record
(`N<tab>title<tab>body`) on every link the process holds. A notification
posted before PID 1 hands the link over is kept in `bridge.unsent` and sent
when `adoptPlatformLink` takes the link. On the platform side, `take` keeps
each one with the link's client number and application name, and
`takeNotifications` hands them over.

The platforms call PlatformUI's `followNotifications` every time their root
is built. A link waking marks the platform's interface stale, so a new
notification is drawn on the next frame. Each new one is logged once
(`a notification banner appeared`, with title and body) and stays five
seconds: `redrawAfter` asks for the frame that takes it away. Display Check
posts one per client, and the multi and mobile boots assert both.

Display Check runs its own session loop rather than the Hosting one, so it
waits on its own `Waits` port (`Tessera/DisplayCheckWaits.kira`): the display
channel and PID 1's channel. Before that it never read PID 1's channel during
a session, never took its platform link, and its notification sat in
`unsent`. A display link handed over meanwhile is kept for the next session,
as Hosting keeps one.

The banner's event is PlatformUI's, a library's, so a test boot sets
`KIRA_LOG=TesseraUI=info,PlatformUI=info`. Unset, a program prints only
its libraries' faults, and an event a library logs at `info` is silently
absent from the boot log.

### Inlay, disk images and alerts

Inlay is a `NavigationSplitView`. The sidebar lists Applications under
Favorites and each opened image under Locations. The path's first value is
an `InlayRoute` (`inlay/app/Selection.kira`), and the detail is a grouped
`Form` for the place it names. `selectChosenPlace` runs on every build. When
the path names no place that still exists, it stores the default with
`navigationStore`: the first image holding an application, else
Applications. That way the sidebar always highlights a row. LibTessera's
`openedDiskImages` lists every application on an image, and
`DiskImage.isInstalled` names the ones already installed. Inlay shows
"Installed" for those in place of Install.

What PID 1 answers about a request is shown with KiraUI's `.alert`
(`kira-ui/app/Alert.kira`). It is a glass card in the overlay band, modal
while shown, with its title, message and actions. Inlay uses the first
sentence as the title and the rest as the message. The actions are
bordered capsule buttons. A bordered button lays its label over itself
(`CAAxis.None`, as a ZStack does), so a button stretched to the card's width
or height keeps its label centred. On Adaptive Mobile the card follows the
iOS 27 kit's `Alert` component: 300 wide, a 14-point inset, the title and
message leading-aligned in 17-point type, and 48-point capsule buttons. On
Adaptive Desktop it stays 260 wide and centred, as a Mac's alert is. The kit
has no macOS alert to take values from.

`kira build container <name> <bundle.app>...` builds and signs an image,
with the key `-container-key` names or the developer's own in the build root,
unless given `-container-signed no`. If a machine is running, it plugs the
image in through the monitor.

An application that lists `.Applications` in its `ApplicationOptions`
watches `/Applications` (`kira-ui/app/Tessera/DirectoryWatch.kira`, which
also watches `/Volumes`). `takeApplicationsChange()` tells the build closure
to read the list again. The Dock and the desktop icons follow installs and
uninstalls this way, with no key pressed.

A square clip inside a rounded one keeps the rounded corners it reaches
(`kcoreanimation/app/Compositor/ClipShape.kira`, `nestedClip`). The clip's
shape kind carries a mask of the corners drawn square, which
`clipShapeCoverage` in `GlassCommon.ksl` decodes. Without it, a scrolling
list that fills a window drew square corners outside the window's rounded
ones.

Not done yet, and what each needs:

- Eject in Inlay's sidebar, as on a Mac. The Volume service's client wire
  is decoded only in `diskutil/app/Volume.kira`. It belongs in LibTessera,
  so that diskutil and Inlay share it. The service needs the
  `tessera.volume` entitlement, and the broker
  (`bootstrap/app/Broker/Table.kira`, `holds`) gives every entitlement only
  to programs under `/bin`. Inlay is in `/System/Applications`, so it holds
  only the defaults. Spec 16 §11.6 derives a process's set from its bundle's
  declaration, which for a bundle on the system volume can be read as it
  stands. The client also waits up to 30 seconds for an answer, so Inlay
  must not call it from a button's action on the interface's thread.
- A mount namespace per application (12 "The sandbox", 13:307). An
  application is dynamically linked: its loader is
  `/lib64/ld-linux-x86-64.so.2`, and its RUNPATH names nine frameworks under
  `/System/Library/Frameworks` and `/System/Library/PrivateFrameworks`. It
  also reads fonts and the Vulkan driver from the system volume. The view
  12 gives (`/` the image, `/data`, `/run/…`) therefore has to bind those
  read-only as well. That is the natural reading, since 12 does not name
  libraries. `kernelLaunch` (`libtessera/app/Backend/Linux/Process.kira`)
  is where the child would build it, between `clone3` and `execveat`.
  Nothing there may allocate, so every path has to be built before the
  clone.
- `-services-multi` failed once in six runs on
  2026-10-12 with "focus routing failed", and every line it asks for was in
  the log once the machine had stopped. The test judged the log at one
  moment, before the last lines landed. It now asks for the whole set until
  it holds or five seconds pass. The key 4 press does reach client 3; the
  malformed packet client 3 then sends, and its disconnection, are the
  test's own robustness check (`DisplayCheck.kira`).

### Scale

The display protocol is in points. After `Welcome` (the client's one surface
number as an id range) MosaicDisplay sends `Output`: the mode in pixels, the
refresh in millihertz and the scale. The scale is two at 192 pixels an inch or
more, from the connector's `widthMm`, and when the connector gives no size,
two above 1600 pixels high. MosaicDisplay keeps every placement in points
(`Scanout.pointWidth()`, `pointHeight()`), lays the composition out in points
with `beginBatch(points, scale, pixels)`, places the cursor plane at the
pointer times the scale and draws the composed cursor at its pixel size over
the scale. KiraUI's session keeps the scale in `Host.scale`; the renderer
makes textures of `drawnPixels()` and encodes `drawnSize()` at the scale. At
1280x800 under QEMU the scale is one and nothing differs from before.
`kira build boot -arch x86_64 -output-size 2880x1800 -dev` gives the display
that mode with no EDID, so it is drawn at scale two, 1440x900 points.

A session reads what its port says arrived without waiting
(`pollDisplayMessage`, `Session.pollMessage`). The wait on the display
channel stays armed while a frame's grant and completion are read straight
off the channel, so it can complete for a message already taken; read with
the blocking `receiveDisplayMessage`, that completion held the platform until
the next display event, and the links to the platform, notifications and
menus with them, went unread meanwhile.

When pointer input is driven from QEMU's monitor, `mouse_set` the virtio
mouse first. The monitor's `mouse_move` and `mouse_button` go to the active
mouse, which is the USB tablet, and tablet-driver holds the tablet's
interface, so MosaicDisplay never sees it. Monitor.kira reads `info mice`
for the virtio one.

### How to check pixels without screenshotting the desktop

QEMU's monitor writes the guest's display to a file. This is the honest way to
verify drawing, and it does not photograph whatever else is on the screen:

    -monitor unix:/tmp/qemu-mon,server,nowait

    python3 -c "
    import socket,time
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/tmp/qemu-mon')
    time.sleep(1); s.recv(65536); s.sendall(b'screendump /tmp/shot.ppm\n'); time.sleep(3)"

The result is a P6 PPM: `P6\n<w> <h>\n255\n` then three bytes a pixel. `sips -s
format png` converts it.

On macOS, `screendump` writes the composed picture of any boot with the venus
device: a blob scanout is shown through its mapping when the console has no
GL, and the services boot checks the image (`picturedScreen` in
Monitor.kira). A `-desktop` or `-dev` boot on Linux shows venus frames through
egl-headless, and `screendump` answers "Error: no surface" for them. Capture the VNC screen
instead: an RFB 3.8 client with no authentication that asks for one raw
framebuffer update at 32 bits a pixel gets the composed desktop.

### Recovery, the installer media's screen

`../recovery` is a platform program that draws a Mac's recovery: a menu bar,
the wallpaper and one window with Install Tessera, Disk Utility, Startup Disk
and Terminal. init starts it in place of the platform under `tessera.recovery`.
`kira build boot -arch aarch64 -recovery` shows it in a window; `-services-recovery`
checks it:

    recovery: info[Recovery.main]: listed the disks
    recovery:    = count: 2
    ==> aarch64 booted to the services userland

Its views build on the host from `recovery/preview` with `kira build`, and
capture headless as the showcase does.

What is drawn and what is done:

- The disks and partitions are the Volume service's, read with the same
  hand-decoded `List` diskutil uses.
- Install, Partition, Erase and Startup Disk change nothing yet. Install
  needs the installer's steps as a program Recovery can run against a
  chosen disk, with mkfs.btrfs and the system image on the media; the
  others need a partitioning service.
- Terminal shows a prompt only: Kira UI has no terminal view and the system
  no shell or pty.
- The SDK's Kira UI contract carries no method default arguments, no Button
  title init, no Picker tag and no State of a list. Recovery works around
  each; a component built against the SDK meets the same gaps.
- `recovery/Resources/Images` and `preview/Resources` are no longer read:
  the glyphs are SVG text in `Glyphs.kira`.

---

## 4. Kira, as a language to write an OS in

Learnt the hard way, and none of it is in a document anywhere.

- **1.9.1 dropped semicolons in FFI attributes.** `@FFI.Syscall { name: chdir }`
  and `@FFI.Extern { library: x, symbol: y, abi: c }`, and no `;` after the
  bodyless declaration either. Older code in sibling repositories still has them.
- **Passing an array to a function moves it.** `row = push(row, …)` per pixel is
  a million moves; append in place instead.
- **An array passed where a pointer is wanted works, and only outward.** The
  seam (`array_elements_address`, from the FFI work in the 1.9.1 line) writes the
  elements into a fresh C block in C widths and passes that. The callee's writes
  land in a copy that is then dropped. This is why a row handed to `write` lands
  on the framebuffer and a buffer handed to `read` comes back empty.
- **`U32(x)` traps on a negative `Int`, and the trap ends the process.** In PID 1
  that is a kernel panic reading "Attempted to kill init! exitcode=0x00000100" —
  which names neither the conversion nor the line. It cost this session an hour:
  a `-1` file descriptor was being written into a `struct pollfd` on the
  shutdown path only, so every other path looked fine. Check before converting,
  or keep the sentinel out of the structure.
- **Kira already carries raw memory.** Look there before writing C:
  `heapLoad<T>` and `heapStore<T>` are builtins, and the Heap library has
  blocks that free themselves. Tessera once wrote nine functions of C it did
  not need.
- **A member a package declaration does not know is ignored, in the old
  `Package Name { }` manifest form** — verified: a manifest carrying
  `somethingUnknown { }` beside the known `let` members still builds and runs.
  Where the parser does give up instead, it says
  `error[4002]: malformed package manifest: declares construct Name extends
  Package with typed let members`, which names neither the unknown member nor
  the position it was in. Worth knowing before that message is read as the
  manifest's known members being wrong.
- **Every package's native libraries share one namespace, program-wide.**
  Declaring the same name twice is error 4035, not a harmless repeat:

      error[4035]: native library declared twice: every package's native
      libraries share one namespace
- **The seam works for a plain C extern, not only a syscall.** `tessera_store_bytes`
  takes a `[U8]` where its declaration says `RawPtr`, and a row of pixels crosses
  in one call rather than a store per pixel.
- **`RawPtr` is built from an integer and cannot be followed.** No dereference,
  no pointer arithmetic, no conversion back to a number — which is why
  `tessera_offset` exists: one `mmap` divided into the dozen structures a modeset
  hands the kernel, rather than a page for each.
- **A `String` traps on a NUL byte.** `linuxWrite` takes a `String`, so it cannot
  carry the zero byte a black pixel is made of. Use the array seam.
- `String(Int(x))` to print a number; `%` and `/` on `U32` for masking and
  shifting; `filledBytes(count, value)` from Foundation for a buffer.
- Structs: `struct Name { var field: Int }`, built as `Name { field: 1 }`.
- `borrow` on a parameter to read without taking.

### The seam: typed memory and the Heap library

Reading back what the kernel wrote needs loads and stores of C-shaped values at
byte offsets, and blocks to hold them. Kira has both.

**Typed memory is a compiler builtin.** `heapLoad<T>(pointer, offset)` and
`heapStore<T>(pointer, offset, value)` read and write a value at its C layout,
unaligned, lowered in place; `heapOffset`, `heapCopyBytes`, `heapMoveBytes` and
`heapFillBytes` sit beside them. There is no declaration to write, no native
library to name and no C.

**Blocks come from the Heap library**, `import Heap`, a path dependency on
`klf-kira/languages/kira/std/heap`. A block with one owner is a `ByteBlock`:

    let headerBytes = zeroedBlock(count: 96, alignment: 16)
    let header = headerBytes.pointer()

It is zeroed, which the KMS two-pass pattern depends on, since a stale byte in
a structure is a pointer the kernel would follow. It frees itself when the
scope holding it ends, so error paths carry no frees. A function that builds a
block for its caller returns the `ByteBlock` (`return move block`) and the
caller holds it; a reply that carries one, `DkReply` or `DmAnswer`, owns it as
a field. A value whose type runs a drop is never copied (error 3398): hand it
over with `move` or lend it with `borrow`.

**Raw allocation is for what outlives a scope.** A pointer kept in a global
table (`ltObjects[...].pointer`, `dvStreams[...].descriptor`,
`dmPublished[...].properties`) or carried out as a message payload comes from
`allocateZeroed(memoryLayout(size, 16))` and is given back with `deallocate` by
whoever holds it last. A `ByteBlock` there would make the table's elements
impossible to copy. `copyBytes` traps on overlapping ranges; `moveBytes` is the
one for those.

**Leaks are visible.** A program with `KLF_HEAP_REPORT=1` in its environment
writes what it left on the heap to stderr when it exits.
`kira build boot -heap-report 1 ...` puts it on the kernel command line,
which hands it to init, and init passes it on to every program it starts.
The report is written only when main returns. A service is stopped with
`SIGTERM`, so only the ones that watch for it (03, Shutdown) report at the end
of a services boot: bootstrap, devicekitd, devices, power, volume and
MosaicDisplay. Drivers are started by devicekitd with an empty environment and
do not report.

**Not there yet: atomics and volatile access.** Pages shared with clients and
read under a sequence count, the power page and the stream slots, are written
with plain stores today.

**There is no C in Tessera's userland any more**, and `allowThinFfiShim` is gone
with it. Two things the shim had grown that the runtime has no equivalent of
turned out not to be needed either:

- *A pointer at an offset*, for slicing one big mapping into the dozen
  structures a modeset hands the kernel. Allocating each structure separately
  removes the question, and removes the fixed cap on how many modes a connector
  may report along with it.
- *A bulk row copy*, to avoid a store per pixel. A store per pixel is a million
  calls to draw a screen and it is fine: the splash is drawn once at boot, and
  anything that has to draw at a display's pace will be the GPU doing it. The
  per-pixel version is also shorter, allocates nothing per row, and sidesteps
  the move semantics of handing an array to a function.

What remains true is the shape: a field is an offset and a width, and the
offsets are still hand-transcribed from the kernel's headers, one `OFFSET(...)`
line per field in `kernel/abi-assertions.c`. The framework-hosted compiler
now reads a manifest's `Autobind` record and makes a native library's
structs, enums, constants and functions from its headers (klf D-370), but its
scanner neither follows `#include` nor evaluates `#if`, which the kernel's
uapi headers need. See [02](roadmap/02-kernel-and-syscalls.md).

`mmap` is still used, for the one thing it is actually for — mapping the card's
own buffer, which is memory this program does not own.

## 5. The calls this userland makes

This list is history rather than a work item. While the syscall table was a
curated one this repository extended, it grew to 63: `read write mount umount2
reboot execve wait4 exit_group sync ppoll` first, then `chdir chroot openat close
ioctl mmap munmap mprotect lseek pread64 pwrite64 fstat statx clock_gettime
nanosleep epoll_create1 epoll_ctl epoll_pwait clone getpid kill setsid pipe2 dup3
fcntl rt_sigaction rt_sigprocmask rt_sigreturn signalfd4 mkdirat unlinkat
renameat2 ftruncate fdatasync getdents64 fchmodat syncfs statfs`, then the
socket family for step 5 of the roadmap: `socket socketpair bind listen accept4
connect sendmsg recvmsg shutdown getsockname setsockopt getsockopt`.

The table is the framework's now and it carries every Linux call by name, so
none of the additions since was a change to this project at all — see §0.
Every call this userland declares is in libtessera's backend, and grepping it
lists them:

```sh
grep -rh "@FFI.Syscall {" ../libtessera/app/Backend --include=*.kira \
  | sed 's/.*name: //;s/ }.*//' | sort -u
```

Notes that mattered while the table was ours:

- `openat`, not `open`: AArch64's table is the generic one, which has no `open`.
- Each entry of that table said whether an interpreter may serve it under
  `--backend vm`. The rule was whether the call is bounded by a descriptor the
  program already holds. `mmap` may not — it would map into the interpreter's
  address space. `clone` would fork the interpreter. `getpid` would answer with
  its identity. `bind` was the one socket call an interpreter would not serve:
  the other eleven are bounded by a descriptor the program already holds, or mint
  one and hand the number back the way `pipe2` does, while `bind` writes a name
  into the developer's filesystem, which is `mkdirat`'s refusal wearing another
  hat.
- `clone3` and `waitid` came late, and `waitid` is the reason the numbers differ
  between the two architectures: 95 on aarch64, 247 on x86-64.

What the old table called missing — the thread group, `getrandom`, `uname`,
`prctl`, the `setuid` family — is in the framework's table. This userland calls
`uname`, `memfd_create` and the `timerfd` trio already, which the old table would
have refused. The ones genuinely not called yet are the ones
`roadmap/02-kernel-and-syscalls.md` argues about, and none of them is waiting on
a compiler.

---

## 6. Talking to devices

### ioctl request numbers

A request is not an index. Direction in the top two bits, the size of the
structure in the next fourteen, a driver family byte, and the call number:

    request = 0xc0000000 | (sizeof(struct) << 16) | ('d' << 8) | nr

`0xc0000000` is read-and-write, which every DRM call is. `'d'` is `0x64`.
Computed and in use:

    DRM_IOCTL_VERSION        nr 0x00  size 64   0xc0406400
    DRM_IOCTL_MODE_GETRESOURCES  nr 0xa0  size 64   0xc04064a0
    DRM_IOCTL_MODE_GETCONNECTOR  nr 0xa7  size 80   0xc05064a7
    DRM_IOCTL_MODE_CREATE_DUMB   nr 0xb2  size 32   0xc02064b2
    DRM_IOCTL_MODE_MAP_DUMB      nr 0xb3  size 16   0xc01064b3
    DRM_IOCTL_MODE_SETCRTC       nr 0xa2  size 104  0xc06864a2
    DRM_IOCTL_MODE_GETENCODER    nr 0xa6  size 20   0xc01464a6
    DRM_IOCTL_MODE_ADDFB2        nr 0xb8  size 104  0xc06864b8
    DRM_IOCTL_MODE_PAGE_FLIP     nr 0xb0  size 24   0xc01864b0

The kernel tolerates an oversized size field (it clamps to its own), which is
why a wrong guess appeared to work early on. Do not rely on it.

### Struct offsets, computed from `include/uapi/drm/drm_mode.h`

    drm_mode_card_res (64):      fb_id_ptr 0, crtc_id_ptr 8, connector_id_ptr 16,
                                 encoder_id_ptr 24, count_fbs 32, count_crtcs 36,
                                 count_connectors 40, count_encoders 44
    drm_mode_get_connector (80): encoders_ptr 0, modes_ptr 8, props_ptr 16,
                                 prop_values_ptr 24, count_modes 32,
                                 count_props 36, count_encoders 40,
                                 encoder_id 44, connector_id 48,
                                 connector_type 52, connection 60
    drm_mode_modeinfo (68):      clock 0, hdisplay 4, vdisplay 14, vrefresh 24,
                                 flags 28, type 32, name 36 (32 bytes)
    drm_mode_create_dumb (32):   height 0, width 4, bpp 8, flags 12, handle 16,
                                 pitch 20, size 24
    drm_mode_map_dumb (16):      handle 0, pad 4, offset 8
    drm_mode_crtc (104):         set_connectors_ptr 0, count_connectors 8,
                                 crtc_id 12, fb_id 16, x 20, y 24, gamma_size 28,
                                 mode_valid 32, mode 36
    drm_mode_get_encoder (20):   encoder_id 0, encoder_type 4, crtc_id 8,
                                 possible_crtcs 12, possible_clones 16
    drm_mode_fb_cmd2 (104):      fb_id 0, width 4, height 8, pixel_format 12,
                                 flags 16, handles 20, pitches 36, offsets 52,
                                 modifier 72 — the last four are arrays of four,
                                 one per plane, and XRGB8888 has one plane, so
                                 only the first entry of each is written. The
                                 four bytes of padding at 68 are what puts the
                                 modifiers on an eight-byte boundary.
    drm_mode_crtc_page_flip (24):
                                 crtc_id 0, fb_id 4, flags 8, reserved 12,
                                 user_data 16

`pixel_format` is a fourcc rather than an enumeration: XRGB8888 is "XR24",
which is 0x34325258.

### The two-pass pattern, and the trap in it

Every "tell me what you have" call is made twice: once with counts zeroed and
pointers null, to learn how many there are; once with somewhere to put them.

**Between the passes, zero the counts you are not asking for.** The kernel wrote
all of them on the first pass, and each count is a promise that the pointer
beside it is writable. Leave one standing next to a null pointer and the call
fails with `EFAULT`, which is also what a genuinely bad pointer gives, and names
nothing.

### Input

`/dev/input/event0` answers `struct input_event`: 8 bytes of seconds, 8 of
microseconds, then `type` and `code` as two 16-bit fields packed into the word
at offset 16, and `value` at offset 20. Twenty-four bytes, always whole. Type 1
is a key; value 0/1/2 is released/pressed/repeated. Keycodes: K 37, I 23, R 19,
A 30.

### `O_DIRECTORY`, and why Tessera does not pass it

It is the one open flag the two architectures do not share: `0o200000` on
x86-64, `0o40000` on aarch64. A program that hardcodes either number opens a
directory on one architecture and answers `EINVAL` on the other.

Tessera passes it nowhere. A directory is opened read-only and `getdents64`
answers `ENOTDIR` on anything that is not one, so one call settles the question
and there is no flag to get wrong. `init/app/Storage/Directory.kira`'s
`isDirectory` does exactly that, on a fresh descriptor whose offset is 0, so it
consumes nothing a later enumeration would want.

That is why the x86_64 boot tests pass where directory enumeration used to fail.
`-services-media` is the one that shows it best, because
`mosaicdisplay` enumerates `/dev/input` and names a path it found:

    mosaicdisplay: keyboard discovered by EVIOCGBIT at /dev/input/event3

That path came out of the `getdents64` loop in
`mosaicdisplay/app/Input/Device.kira`, so `ENOTDIR` was never
mistaken for a name. Both boot tests are in §3.

### The framebuffer

`/dev/fb0`, XRGB8888, little-endian, so each pixel is `B G R 0` in memory.
There is no `lseek` in use, so rows go out top to bottom in order and one write
per row. The end of the screen is found by writing until the device answers
`ENOSPC` — the byte count is width × height × 4, which is how the size was known
before the display could be asked.

---

## 7. Decisions, so they are not relitigated

- **A library is a binary reached over RIDL; only the kernel's ABI is C.**
  Every library (`libtessera`, `devicekit`, `platform-kit`, `display-client`)
  is a component built on its own into a shared library in
  `/System/Library/Frameworks/<Module>.framework`, and its `public`
  declarations are its RIDL surface. Its dependents link it dynamically and
  call it through `@Ridl` declarations that `klf ridl bindgen --lang kira`
  writes into their `app/bindings/` from the `.ridl` in the SDK, never from its
  sources (roadmap/18-components.md).
  `@FFI.Syscall`, and the typed memory that lays out what a syscall reads, stay
  C. A `distinct` crosses as a struct of its one `raw` field, which has the
  representation's layout.
  A generic struct or construct crosses as its template and the instances it
  names with `@Instance(Type)` (KLF-RIDL §20.7, §23.5). KiraUI's
  `Binding<Bool|Number|String>`, `Tab`, `TabView`, `Picker` and `TagLayer`
  over `Number` and `String` are exported that way; Clock's
  `TabView(selection:)` uses `Binding<Number>`. Not exported yet: generic
  methods (`Widget.tag<Value>`), and a second `Toggle.init`, since RIDL has
  no overloads.

- **Refuse to boot, like macOS.** A system volume that will not mount stops the
  machine, with the reason on the console, through the same `reboot` path
  `tessera.autoexit` uses. No recovery mode: a boot that repairs is a boot that
  did not refuse. `tessera.shell` was a hole in this and has been removed.
- **The display is a process, not part of PID 1.** DRM master is exclusive:
  whoever holds `/dev/dri/card0` owns the screen, so an init that held it would
  be an init nothing could ever take the display from. `mosaicdisplay` is
  that process, PID 1 starts and restarts it, and this is the first step of the
  road to a display server rather than a tidying-up.
- **The card is opened once and never closed.** A DRM master that closes gives
  the console its mode back, and the splash with it. PID 1 holds
  `/dev/dri/card0` for the life of the machine, which is also what makes the
  display Tessera's rather than something it borrowed. `/dev/fb0` is kept as the
  fallback for a machine with no card, or a card that would not set a mode: it
  is somebody else's mode, and that is exactly why it is second.
- **Setup is macOS-shaped, not ChromeOS-shaped.** An installer creates state
  once; later boots verify rather than reconcile. Nothing of it is built. The
  installer is the only component allowed to create, so it is the only one that
  can be wrong in a way nothing later corrects.
- **The seal is absent, not stubbed.** The system volume is read-only squashfs.
  `DM_VERITY` is off, `veritysetup` does not exist on macOS, and a root hash
  would ride a kernel command line nothing signs. Read-only is true; trusted is
  not.
- **16K pages** on aarch64 — see §8.
- **No kernel debug info, no boot logo, no aarch32 compat, no MTD.**
- **A window uses the 2D device**, not venus: scanning venus out needs a GL
  context and QEMU on macOS has no OpenGL. Fixing that properly is §10.
- **GL is not a path.** sokol is out of Ember now, Vulkan is the direction,
  and Apple deprecated GL for reasons. Do not reach for zink or llvmpipe.
- **The SDK is Kira and RIDL, and Vulkan is the one exception.** No component
  compiles C, ships a header or binds one; Ember's Vulkan backend links the
  Vulkan loader and nothing else. Dawn is not part of Tessera, and a library's
  C for other platforms gets no Tessera row (roadmap/14, "What a Tessera
  program is made of").

---

## 8. Kernel configuration, and what each line prevents

In `kernel/config/tessera-common.config` and `tessera-aarch64.config`:

- `CONFIG_ARM64_16K_PAGES=y` — Hypervisor.framework maps guest memory at the
  host's page granularity. A 4K guest asking for a host-visible GPU buffer at a
  4K-aligned offset asks for something the host cannot map, and QEMU stops on
  `hvf_vcpu_exec: assertion (isv)` inside its own vcpu loop, naming nothing.
- `CONFIG_DEBUG_INFO_NONE=y` — DWARF cost about ten times the kernel's own size
  and a link needing 3 GB resident. It is what ran the disk out.
- `# CONFIG_LOGO is not set` — Linux paints its mascot on the framebuffer the
  moment a display binds.
- `# CONFIG_COMPAT is not set` — the compat vDSO is ARM code, and the LLVM
  bundle Kira pins is built for the host architecture alone, so there is no ARM
  backend to build it with. Tessera runs no aarch32 binary anyway.
- `# CONFIG_MTD is not set` — the `virt` machine always presents two pflash
  banks and defconfig binds the CFI driver to them. The probe writes to the
  flash command register, QEMU flips that region from memory to MMIO mid-run,
  and under hvf that calls `hv_vm_unmap` on a range the hypervisor never mapped:
  macOS kills the emulator with `EXC_GUARD` a second into the boot.
- `CONFIG_VIRTIO_INPUT=y`, `CONFIG_INPUT_EVDEV=y` — the `virt` board has no PS/2
  controller.
- `CONFIG_CGROUPS`, `CONFIG_MEMCG`, `CONFIG_CGROUP_PIDS`, `CONFIG_CGROUP_SCHED`,
  `CONFIG_PM_WAKELOCKS`, `CONFIG_TRACING` — what LibTessera reaches: a Job is
  a cgroup v2 directory, a wake lock is a wakeup source, and trace events go
  to `trace_marker`. PID 1 mounts `cgroup2` at `/sys/fs/cgroup`.
- `CONFIG_CFG80211` off — the defconfig's cfg80211 loads `regulatory.db` at
  boot and the image carries no firmware. Nothing drives a wireless device yet.
- Keep `CONFIG_FRAMEBUFFER_CONSOLE=y`. It is what sets the display mode; without
  it the scanout stays at 640x480 while the framebuffer keeps the driver's size,
  and the window shows a corner of the picture. Silence the cursor with
  `vt.global_cursor_default=0` on the command line instead.

---

## 9. The graphics stack

### Guest (build/app/GuestGraphics.kira)

Cross-built for aarch64-linux with the same LLVM bundle and sysroot as the
kernel: **libdrm 2.4.125**, **Mesa 25.0.7** (`-Dvulkan-drivers=virtio`, nothing
else — no gallium, no GL, no window system, no LLVM, `-Dzstd=disabled
-Dshader-cache=disabled`), **Vulkan-Loader 1.4.321** with headers at the same
tag, plus static **zlib** and **expat** because Mesa's shared code reaches for
them.

Traps: the 1.4.313 loader and headers disagree about `vkCmdDispatchTileQCOM` and
will not compile together. Autotools projects need `-fuse-ld=<lld>` in `CC` or
the macOS linker is used. libtool cannot cross-build a Linux shared object on a
Mac; build static.

### Dawn, removed

Tessera used to fetch a prebuilt aarch64 Dawn (`scripts/fetch-dawn.sh`) and
render through WebGPU. It no longer does: Ember's Vulkan backend renders
directly on the loader above, `fetch-dawn.sh` is deleted, and Ember's Tessera
rows link `vulkan` alone. The sections below that mention Dawn record what was
true when they were written.

### Host (build/app/HostGraphics.kira)

**virglrenderer 1.1.1** with venus, patched four ways, and **QEMU 10.0.2**
configured `--target-list=aarch64-softmmu --enable-virglrenderer --enable-hvf
--disable-pvg` - the last because Apple obsoleted `PGTask_t` in macOS 27 and
QEMU's own ParavirtualizedGraphics device no longer compiles.

### The memory model, which is the whole trick

venus gives a guest host-visible memory by allocating it in the host's Vulkan
driver and sharing it out as a dma-buf or an opaque fd. **Metal has neither.**
This is the same wall the earlier WSL investigation hit through dzn, reached
from the other side.

MoltenVK does the opposite: `VK_EXT_external_memory_host` imports a pointer the
caller already owns, which underneath is `newBufferWithBytesNoCopy`. So the
renderer allocates shared memory itself, hands the driver a pointer into it, and
hands the guest the same descriptor as a `VIRGL_RESOURCE_FD_SHM` blob. One set
of pages, no copy, unified memory underneath.

Measured before any of it was built, by `host_import_smoke.c`:
`minImportedHostPointerAlignment` is 16K, the pointer imports as a host-visible
coherent type, and a `vkCmdFillBuffer` reads back through the original `mmap`
pointer. That probe is worth keeping — it is the cheapest thing that can say no.

### QEMU invocation

    -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M   # GPU, headless
    -device virtio-gpu-pci                                    # 2D, a window
    -machine virt,accel=hvf -cpu host
    VK_ICD_FILENAMES=/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json

`hostmem=2G` silently leaves the guest reading `-host_visible`, with one line in
QEMU's log about the BAR being shorter than the region, after which venus reports
a required kernel parameter missing and names neither.

---

## 9b. The Kira beside this, as of 1.9.1

Tessera's compiler is the driver built from the `klf-kira` definitions, so what
happened in `../klf-kira` matters here as much as what happened in `../kira`.
What follows is committed on `../kira`'s `main` and pushed to the fork.

**The workspace is 1.9.1.** One line in `[workspace.package]`; every crate
inherits it. The compiler Tessera builds against is a different thing: it is
installed from `../klf-kira` and `kira --version` reports its channel and
version, `0.1.0` on `dev` here — see §0.

**`kira build` names its output and lost the linkage flags.** `-o <path>` and
`--emit` are new; `--sysroot`, `--relocation-model` and `--linkage` are gone,
and so is the fixed `.kira-build/<triple>/main` an older compiler wrote. A
target is spelled the vendor way on the command line and in the output path
alike, `aarch64-unknown-linux-gnu`.

**Typed memory lowers in place.** No archive is built or staged for it; the
compiler emits the loads and stores itself. That is why
`scripts/build-runtime.sh` is deleted and `scripts/tessera runtime` is gone, and
why no manifest declares a native library for it.

**Every program links the target's C library.** There is no static linkage to ask
for: the framework links the C library rather than folding it in, and no flag
changes that, so every image with Kira code carries the loader and the C library.
§3 has the `file` and `readelf -d` output that shows it on a built aarch64
`init`.

**The lint and autobind work below is about the 1.9.1 compiler in `../kira`,
which Tessera no longer builds against.** It is recorded because the sibling
libraries still depend on it. The compiler Tessera does build against is the
framework-hosted driver, whose subcommands are `build`, `run`, `check`, `format`
and `lsp` — there is no `kira lint` and no `kira autobind` in it. A manifest's
`Autobind` record is read at build time instead, and a `Headers` block carries
the include directories itself rather than a `--sysroot` on the command line.

**Autobind carries a header's enumerators.** It read structs, functions,
arrays, pointers and callbacks, and had nowhere to put a number. It now emits
`let NAME: Int = value` for every `enum` case the listed headers define, chosen
by an `AutobindMode.Selected` declaration's `constants:` list or by `AllPublic`.

That is half of what `kernel/abi-assertions.c` exists for. A `#define` still
cannot be reached — the preprocessor has consumed it before clang has a cursor
— so DRM's ioctl request numbers, `SCM_RIGHTS`, and the `CMSG_*` arithmetic stay
hand-written and stay asserted. What *can* move into a generated `let` is any
constant a UAPI header spells as an `enum`, and `linux/virtio_gpu.h` is full of
them: 70 came out of `virtio_gpu.h` and `drm_mode.h` together, including
`VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID = 4611`, which is the `0x1203` §11
records from the venus device.

**A lint sees every declaration, and has a level and a group.** A body walk
answered only for a `function`, so every structural lint was blind to
`construct`, `class`, `struct` methods, `extend` blocks and trait defaults —
which is most of a Kira program. `kira lint` in a package with no `linter.kira`
did nothing at all and printed `ok`. Relevant to Tessera when it grows one: a
`linter.kira` is overrides rather than switches, `LintLevel` is
`Allow | Warn | Deny`, a lint belongs to a `LintGroup`, and `@Allow(KLINT002)`
silences one site.

**A hazard worth knowing before trusting that lint's output.** On a package that
does not compile it exits non-zero having printed nothing on either stream,
where `kira build` reports the error properly. Half-fixed there; the path where
the compile returns diagnostics rather than an error still says nothing.

## 10. What is next, in order

The current forward plan is [ROADMAP.md](ROADMAP.md), with the product sequence
in [23 Product experience](roadmap/23-product-experience.md). Chapters 19–38
describe the planned everyday OS capabilities and their implementation paths.
The notes below record the earlier desktop bring-up sequence; use the detailed
chapters and current acceptance evidence for status.

**Phases A and B of that roadmap are done.** There is a process system: PID 1
starts services from a table, waits on their pidfds and a signal descriptor in
one `ppoll`, restarts what dies, and stops the machine by asking first and
insisting after three seconds. The display and the keyboard live in
`mosaicdisplay`. And there is a channel: every service is started holding one
end of a `socketpair` at descriptor 3, and a file descriptor has crossed it.

**DeviceKit's five steps are done** (§3, and `roadmap/17-devicekit.md` §25
for where they depart from the spec), and services are reached through a
broker, `bootstrap`, over a System channel each process keeps, which
carries `deviceChanged` events as well as calls. A driver manifest may
detach a kernel driver. Drivers ship as DriverKit's do, as bundles in
`/System/Library/DriverExtensions`, each `<name>.dext` holding the
executable and an `Info.plist` whose `IOKitPersonalities` are its
manifests; devicekitd reads them when it starts and logs
`loaded ccid-driver.dext, 1 personality`. Left on that side: the System
channel handed over in the Startup message by a Launcher, and its other
events; and Display wake locks once MosaicDisplay owns blanking. An eject
now has the drive let its medium go through `Block.eject`, and the restart
boot asserts that a CD's tray opens.

What is next, in the order the roadmap argues for:

1. **Blob framebuffers**, so the pixels the GPU rendered are the pixels scanned
   out. **Proven end to end this session** by
   `venus_scanout_smoke.c`: a host-visible Vulkan image
   rendered on the GPU, exported as a dma-buf, named a framebuffer, and scanned
   out with the host accepting the `SET_SCANOUT_BLOB` (no `ERR_INVALID_RESOURCE_ID`,
   no `ERR_UNSPEC`). It took two patches — `patches/mesa-25.0.7-venus-scanout`
   (guest venus exposes `VK_EXT_external_memory_dma_buf` on a host that exports
   none, and does not forward the export to that host) and the
   `virtio_gpu_rect_update` hunk in `patches/qemu-10.0.2-darwin-venus` (present a
   blob through a 2D surface, not a GL texture). Ember's Vulkan backend now
   renders into the exported blob itself — see `roadmap/07-graphics.md`.
2. **Page-flip events**, and one flip in flight, which is the frame clock
   everything above will pace off.
3. **The protocol itself**, on the channel that now exists: objects numbered by
   the client, surfaces, and a malformed message that disconnects one client and
   leaves the machine running — `roadmap/08-display-server.md`.
4. **Ember inside Tessera**, through `openHeadlessGraphicsWithBackend(.Vulkan)`. That
   question is answered: a package with a dynamic native library cross-builds
   for aarch64 Linux, and so does everything else — every Tessera program is
   dynamically linked now.

---

## 10c. No C: the SDK is Kira and RIDL

As of 2026-10-11, uncommitted across the checkouts named here.

- **The rule.** A Tessera component is Kira and RIDL. Vulkan is the one native
  library a program links. `scripts/build-ui-stack.sh` says so in its header
  and checks for the loader; nothing else native is built for Tessera.
- **Symbols are Kira.** KCoreAnimation's SVG symbol rasteriser was C
  (`kiraicon`) and is now `kcoreanimation/app/Content/Symbol/`: the SVG subset
  symbol sets use, fills scanned into a coverage plane, strokes as a distance
  field, weight growth, and ink measurement cached in a Foundation `Map`.
  Kira UI sizes symbols with `symbolInk`. The glyph atlas is indexed by a
  `Map` and packed by one `packGlyph` shared by text and symbols.
- **Text is not yet.** `kiratext` (FreeType and HarfBuzz) is KCoreAnimation's
  last C, and it has no Tessera row: on Tessera its bindings are excluded and a
  text call traps by name. Porting it is the next large piece
  (roadmap/09-text.md).
- **Foundation's `abs` and `copysign`** read the sign of a Number with an
  extended mantissa (19 or 20 significant digits) backwards. Fixed in
  klf-kira's Foundation with `numberNegative`; a motion test caught it.
- **Manifests are constructs.** Every Kira package's `package.kira`, Ember's
  included, is `construct Name extends Package { let member: Type = … }`, which
  reports a misspelled member as error 4003 where the old `Package Name { }`
  spelling ignored it. Test packages stay `.App`, since tests are collected
  only from non-library modules; check them with `kira check --test`.
- **Kira Graphics is gone.** Ember replaced it; the `kira-graphics` checkout is
  deleted.
- **Composition is written, not booted.** MosaicDisplay's `Compose.kira`
  routes each picture through `routeFor`: direct scanout when the topmost
  surface covers the output, otherwise every surface drawn as a quad, bottom
  first, through Ember into one of two exported images (roadmap/07).
- **Not booted since.** None of the above has been built for aarch64 and
  booted. That is the next check: `scripts/build-ui-stack.sh aarch64`, the
  initramfs, then `scripts/run-qemu.sh aarch64 --services-multi`, each under a
  hard timeout.

---

## 10b. Kira UI, and what it took

What follows records a boot that happened, on Apple silicon, before the migration
to the framework-hosted compiler. Read the log as what was observed then. The
package checks clean now, which is a separate fact from the boot and is recorded
at the end of this section.

It lowers a widget tree, lays it out, renders it and submits the frame — Kira UI →
Kira UI Foundation → Ember → Dawn → WebGPU → Vulkan → venus → the host's
Metal. The boot log:

    tessera: started ui as pid 84
    tessera-ui: a WebGPU device, with no window
    tessera-ui: a render target of 1280x800
    tessera-ui: 2 render commands from the widget tree
    tessera-ui: the frame was submitted

The third line is the only one that could have said otherwise. A widget tree
lowers and lays out to a value whatever happens; rendering answers with a count,
and zero would mean the tree reached the backend and drew nothing. The program
used to print "the widget tree lowered" above these, guarded by a check that the
lowered tree still contained the string the program had just put in it. That
could not fail, so it proved nothing, and it was quoted here as though it did.
It is gone.

The pixels are in a GPU texture and go no further. Getting them on the screen is
steps 6 and 8: `mosaicdisplay` owns the card and knows nothing about surfaces.

`tessera-ui` now renders into a **shared surface** when the machine can allocate
one (`sharedSurfacesAvailable()`), and falls back to a plain texture with a line
when it cannot. A shared surface is what a client hands the compositor — memory
scanned out with no copy. On this emulator it always falls back: this guest's
Mesa has no libgbm to allocate through, and even given the memory, Dawn's import
of it cannot complete on venus. `dawn_scanout_smoke.cpp` is
the isolated proof of that: through Dawn's SharedTextureMemory API it imports a
venus allocation and makes a texture, then `BeginAccess` (the acquire) fails
silently, because venus's emulated sync-fd semaphore does not satisfy Dawn's
acquire. The guest-venus scanout patch was extended to advertise that sync-fd
semaphore (`patches/mesa-25.0.7-venus-scanout`), which is what got Dawn as far
as the import. On real hardware the whole path works. See
`roadmap/07-graphics.md`.

`scripts/build-ui-stack.sh aarch64` builds all of it from a clean checkout.

**Kira UI compiles now, and the patch that used to make it is gone.** It did not
compile before, for any target, on any machine: Ember bound
`objc_msgSend` under one name at many shapes, which the FFI rule refused — one
name, one C type. Two changes in `../kira` fixed it at the root rather than
around it:

- **One FFI name may carry several shapes of one symbol.** `objc_msgSend` on
  arm64 is not variadic, so every selector needs the prototype it actually has.
  A call picks a shape by arity, then argument types, then — for shapes that
  differ only in what they answer — the expected result: a statement expects
  `Void`, a condition `Bool`, an annotated binding its type. See the FFI
  overloading commit and `KSEM372`.
- **Autobind takes the sysroot.** A shipped header reaches `<math.h>`, which
  libclang finds only under the target's sysroot; a cross-target harvest bound
  nothing without it. The sysroot now rides beside the target into autobind's
  clang — through the manifest's `Headers` block, since the compiler Tessera
  builds against takes no `--sysroot` on the command line.

**sokol is gone from Ember**, committed in that repository. It was GL,
so it pulled X11 and OpenGL onto the link line of a machine that is a compositor
and has neither. The monotonic clock and live-reload hooks it used to host moved
to a neutral `NativeLibs/Support` C library; the harness helpers moved to
`app/App/Harness.kira`; the aarch64-linux Wayland row was dropped
(Optional-with-no-row traps the calls by name). `tessera-ui` links
`libwebgpu_dawn` and the C library and nothing else — no GL, no X11, no
`libwayland-client`, no sokol — which is what the deleted patch existed to
produce.

Kira compiles a native library's `sources` for the host and expects a prebuilt
archive at `generated/native/<triple>/` for a cross target, and nothing built
those for aarch64 Linux from a Mac. `scripts/build-ui-stack.sh` does: FreeType
and HarfBuzz (`libkiratext.a`, 3.6M), the state store, the icon module, the
appearance probe, the shared-surface seam, and the neutral graphics-support
shim. HarfBuzz is C++ and the staged sysroot has `libstdc++.so.6` but no C++
headers — it was staged for the kernel and for Dawn, neither of which needs them
— so the script fetches `libstdc++-14-dev` the way `setup-host.sh` fetches
everything else.

There is no `--linkage dynamic` to ask for and nothing is static: every Tessera
program is dynamically linked now, because the framework links the target's C
library rather than folding it in. `tessera-ui` needs the most beside that —
`libstdc++`, `libwebgpu_dawn.so` and the guest Vulkan stack — but it is no longer
the exception.

**`ui` checks clean again.** It did not: it called
`runFoundationLayout`, `foundationRender` and
`EmberFoundationBackend.beginFrame`, and the libraries had replaced all
three. Tessera no longer lays out and renders by hand. The chain is
`caLayoutTree` → `caReconcileImmediate` into a `Compositor` → `caCompositorEncode`,
and `caCompositorEncode` builds the backend and owns the frame begin, so there is
no backend left for Tessera to construct. Both commands exit 0:

    $ kira check ../ui
    $ kira build ../ui --target aarch64-unknown-linux-gnu --emit kir

What that does not show is a boot. `tessera-ui` is built into the initramfs only
when the guest GPU stack is, and `scripts/build-initramfs.sh` says so:

    warn: aarch64: no guest GPU stack -- run scripts/build-guest-gpu.sh and scripts/fetch-dawn.sh
    warn: aarch64: this initramfs carries no tessera-ui; the display server runs without it

Neither `build-guest-gpu.sh` nor `fetch-dawn.sh` has been run on this Fedora
host, so `tessera-ui` has not been built, staged or booted here, and the boot log
at the top of this section is the only evidence that it ever reached a GPU at
all. Checking and lowering to KIR is what was verified.

**There is no window and there will not be one.** Ember opens one on
Linux by being a Wayland client (`DawnWindowWayland.kira`); Tessera has no
compositor to be a client of and is meant to be the compositor. So this takes
`openHeadlessGraphics`, which exists for exactly this: "a COMPONENT of a
compositor... its pixels belong to another process."

`createSharedSurface` is the right way to hand those pixels over — GBM allocates
and exports a dma-buf — and it returns nothing here: this guest's Mesa is
`-Dvulkan-drivers=virtio` with no gallium, so there is no libgbm in it. That is
the first thing to solve for step 6.

---

## 11. Not verified, and someone should

- **The Fedora/WSL host.** The x86_64 and aarch64 boot tests pass here. What has not
  been run on Linux is the full `scripts/tessera build` as one command, and
  neither is any kernel config decision under a real hardware accelerator: the
  GPU work in §9 was all done on Apple silicon.
- **aarch64 booting on this host.** QEMU's TCG aarch64 emulation produces no
  console output at all from the kernel here, with or without an initramfs. The
  aarch64 kernel and initramfs build and the binary is right — §3 has `file` and
  `readelf -d` on it — but the boot cannot be observed. This is an emulator and
  host limitation, not a Tessera one, and it predates the migration.
- **`scripts/tessera build` as one command** — the stages were driven
  individually all session.
- **The handover interaction with services.** With `tessera.system`, PID 1 hands
  over *before* starting anything, so the system volume's init inherits no
  children and starts no services of its own. That is coherent today because the
  system image carries only its own init, and it is the first thing to revisit
  when the system volume grows a display service.
- **The restart limit.** Five starts, then a line on the console and no further
  attempts. The path is written and has never been reached.
- The Vulkan loader in the graphics image reports 1.4.357 while built from
  1.4.321 sources, which suggests it found the host's headers. Harmless so far.
- **A dumb-buffer scanout is shown by the device itself.** virglrenderer,
  started without its GL renderer for venus, cannot make a 2D resource, so
  `SET_SCANOUT` for the splash's dumb buffers used to be answered with
  `ERR_INVALID_RESOURCE_ID` (`ctrl 0x103, error 0x1203`). The darwin-venus
  patch now sends a venus device's 2D commands to QEMU's own 2D path, which
  keeps the pixels in guest memory and a pixman image, and answers them at
  once: virglrenderer signals no fence on context 0 without its GL renderer.
  The virgl `SET_SCANOUT` that turns a scanout off also clears the scanout's
  surface, which the console frees; before that, the restart boot crashed the
  emulator when the new MosaicDisplay showed its splash. GPU frames still
  reach the display only as blobs. Every restart boot logs "vkr: <command>
  resulted in CS error" for the first MosaicDisplay's context, immediately
  before the context is destroyed: init has just killed it, which suggests the
  host read a ring the process was writing when it died. The plain services
  boot, which kills nothing, logs none. A bare guest blob
  (`VIRTGPU_BLOB_MEM_GUEST`, no venus) is recognised but answers
  `SET_SCANOUT_BLOB` with `ERR_UNSPEC`: virglrenderer cannot map it, because
  the pixels are guest pages rather than the host shared memory the
  host-pointer patch gives a venus allocation. The scanout resource has to come
  from venus, not from `RESOURCE_CREATE_BLOB` alone.
- **The multi boot's USB stick is sometimes never mounted.** About one multi
  boot in fourteen fails with `no "log:AdaptiveDesktop.Desktop.Devices]: a
  volume was mounted|path: "/Volumes/stick""`. The Volume service's only line
  for the stick is `cannot open a disk`, `disk: "sda"`, `error: "DeviceLost"`,
  logged right after the keyboard step, so the first open of the new disk
  failed and nothing tried it again: `appeared` runs once, and `changed` runs
  again only on a property change, which did not come. `DeviceLost` is EIO,
  ENXIO, EPIPE, ESHUTDOWN or a lost manager connection; the line now carries
  the error's `detail`, the errno, so the next failure says which.

---

## 11b. Left undone, with what is known about each

- **LibTessera is built and imported by nothing.** `libtessera`
  implements every call of `roadmap/16-libtessera.md` and
  `build-initramfs.sh` builds it for the image's architecture, but no program
  links it yet. `Thread.spawn` and the TLS calls answer `Unsupported` until
  Kira can start a thread on a stack it built; §25 of the document lists the
  other departures.

- **Four `kira-ffi` commits exist on one machine and nowhere else.**
  `02a8f45` (one FFI name carrying a symbol's several shapes — `objc_msgSend`
  is not variadic on arm64, and a graphics backend needs 38 shapes of it),
  `23844f5`, `a98cde3`, and a `git rm` of four dead files, all based on
  `1912dda`. They reached this machine only as pasted patch text, and the paste
  dropped whole runs of lines inside hunks — five hunks in the first patch have
  old-side counts short by one to three. One drop was recoverable by reading the
  file; the rest are not, because a dropped context line cannot be told from a
  line the patch adds. Do not reconstruct them. Get the objects: the box is
  `ip-172-31-75-158`, unreachable over NetBird and not answering on any public
  DNS name in this machine's shell history, and a push request is queued to its
  Claude session.

- **`kira lint` on the userland.** There is no `kira lint` in the compiler Tessera
  builds against — the subcommand does not exist, and `kira lint <path>` is read
  as a source file named `lint`. `kira check` is what reports diagnostics. Nothing
  here has a `linter.kira`, so nothing is linted. The three programs are small
  enough that this costs nothing today and will not stay that way.

- **`tessera-ui` on this host.** It checks clean and lowers to KIR, and it has
  not been built, staged or booted here because the guest GPU stack this host
  needs first has never been built. See §10b.

## 12. Things tried that did not work, so they are not tried again

- **Turning off `fbcon`** to remove the cursor: took the mode setting with it.
- **`-D_UUID_T` globally** to fix `file2alias`: breaks `<unistd.h>`, which
  declares functions taking a `uuid_t`. The patch is per-file and Darwin-only.
- **Disabling `CONFIG_SYSTEM_TRUSTED_KEYRING`** to avoid OpenSSL in a host tool:
  it is selected by things that are on, and turning *those* off would make a Mac
  build a different kernel than a Linux one. Point `PKG_CONFIG_PATH` at
  Homebrew's OpenSSL instead.
- **A `[U8]`-only read path in Kira**: rejected as a special case, and then
  unnecessary — Kira's `heapLoad<T>` is general, and the C shim that used to sit
  in front of raw memory is gone.
- **Reading back through the array seam**: it copies out only. Confirmed in
  `kira_rt_array_elements`, which builds a fresh block and passes that.
- **Presenting GPU frames through the 2D device by reading them back**: rejected
  as a copy that defeats the point.

## Release train workspace bring-up (2026-10-24)

The release train layout is flat:

```text
Kira-projects/
  development/
    tessera/
    desktop/
    kira-ui/
    klf-kira/
    ...
  staging/
    tessera/
    desktop/
    kira-ui/
    klf-kira/
    ...
  worktree-<name>/
    tessera/
    desktop/
    kira-ui/
    klf-kira/
    ...
```

`development` and `staging` are independent repositories, not clones of each
other and not worktrees. `development` has no remote. `staging` has a
`development` remote and is reset to the latest `development` every Thursday
before the release is cut. Each `worktree-<name>/` is a folder of linked
worktrees of `development` or `staging`.

Each workspace contains only Tessera repositories and its Kira dependencies.
The creator uses an explicit repository inventory, not a scan that could copy
unrelated projects from the outer container. All repository paths are direct
siblings. Package manifests, component locations, source scopes and VM state
paths follow that layout. Legacy source checkouts and their dirty work remain
untouched.

Development integrates committed changes. Source edits happen in worktree
workspaces. Staging is the weekly release workspace. Existing CoreIcon work
was copied into a separate signed checkpoint for host-build validation. The
previously unversioned reportcrash and debugserver sources were checkpointed
only in the new workspace; development is now their only repository, with no
base checkout or remote.

From a workspace's tessera checkout:

- `kira build workspace create worktree-name` from development creates linked
  worktrees of development.
- `kira build workspace create staging` from development creates staging as an
  independent repository that tracks development.
- `kira build train` in development or staging captures an immutable snapshot.
- `kira build -base <digest> workspace create worktree-name` creates sources at
  the pinned revisions and records the base in workspace.base.
- `kira build boot -dev` in a pinned worktree boots shared train artifacts and
  installs changed roots after devroot starts.
- `kira build overlay` updates a running workspace VM and removes reverted
  roots. Early boot components still require a derived image.

VM state belongs to `<workspace>/.tessera-state/`. An installed read-only train
volume is shared; each workspace VM uses a small qcow2 delta. Unchanged build
outputs come from the shared store, without a full output tree per worktree.
Snapshot pins retain release artifacts through collection. Relative source
identities resolve symlinks, and discovered-input variants let workspaces keep
independent cache results for different sibling dependencies.

Verification includes Build tests, execution probes for action reuse and
collection, and real Kira compilation through a symlinked workspace. A library
edit recompiles the library and its consumer while the unrelated program and
base workspace stay cached; executing the consumer confirms the new value.
The disk helper test verifies isolated writes, stable reopen, and rejection
of a different base. A full train build and real VM overlay boot are still
pending sufficient storage or access to the larger build machine.

## 2026-10-31 Cairn implementation follow-up

The Cairn Tessera workspace has a review changeset for host-tested product and
safety work. The source remains in review until it is explicitly accepted;
these notes do not mark any QEMU/desktop boot checkpoint complete.

**Home / Desktop:** Layout edits now guard self-drops, duplicate/unknown
folder members and invalid widget indices. The page overview can explicitly
add/remove empty pages. A retained empty page persists; `Home.txt` v3 escapes
unsafe delimiters and reads legacy v2. Adding apps to a full selected page
preserves user placement by moving existing icons forward.

**Files / Backup:** Transfer collision checks use no-follow metadata so a
broken symbolic link cannot appear to be a free destination. Backup copying
checks bytes and full tree manifests before marking a generation complete;
verified restores stage changes without replacing current documents.
`FileOperations` now includes a strict, persisted opt-in daily/weekly schedule
with power/idle/space and failure backoff decisions. A one-shot runner can
execute a due backup and record success only after verification; it does not
start a daemon. Its retention default is to keep **all** previous backups;
pruning requires an explicit positive count. Its source-tree consistency
check is not a filesystem-atomic snapshot.

**App identity / Store foundation:** `app-registry` provides publisher-bound
identities, versioned accepted and pending records, preserved data ownership,
rollback metadata and consent-gated rollback. Current permissions are
rechecked at delayed activation and rollback so revoked access is never
re-granted from a previous state. The registry v2 file format reads legacy v1.
`app-catalog` provides offline search/browse, compatible install/update
states, bounded cached metadata, Ed25519-signed feeds, pinned trusted
certificate checks, a download queue with at most three active downloads,
and restart-reconciled job history. The image-verification component checks
actual staged image bytes plus signed manifest metadata, with a recheck at
activation. The signer is currently identified by the SHA-256 of certificate
DER bytes: certificate renewal needs an authenticated migration policy. The
privileged immutable-image installer and OS-backed permission enforcement
are **not** implemented by these pure models.

**Host checks:** Run from the Cairn Tessera root with the working Kira/KLF
host toolchain and platform linker:

```
kira test tessera-packages/desktop/tests/layout_kik
kira test tessera-packages/trash/tests/trash_kik
kira test tessera-packages/inlay/tests/operations_kik
kira test tessera-packages/app-registry/tests/registry_kik
kira test tessera-packages/app-catalog/tests/catalog_kik
kira check --target aarch64-unknown-linux-gnu tessera-packages/app-registry
kira check --target aarch64-unknown-linux-gnu tessera-packages/app-catalog
kira check --target aarch64-unknown-linux-gnu tessera-packages/inlay/operations
```

The Kira host preflight `tessera-packages/tessera/scripts/verify-host.sh --tests`
checks tool availability, assets and whether the build-output directory
supports advisory locking. The Cairn-backed build directory may refuse
advisory locks; a full `kira build boot -arch aarch64 -test` still needs a
compatible build filesystem and complete train SDK integration. Host
compilation and tests must never be presented as successful OS boot tests.
