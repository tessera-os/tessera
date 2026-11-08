# Tessera

An operating system built on the Linux kernel with a userland of its own.

Tessera is not a distribution. It takes the kernel as given and replaces
everything above it: there is no init system inherited from elsewhere, no shell
assumed to exist, and no package manager. The userland is written in
[Kira](../../kira-projects/klf-kira).

## Where it is

Booting, on its own userland. PID 1 is a Kira program that reaches the kernel
through raw system calls — `mount`, `write`, `wait4`, `ppoll`, `sync`, `reboot`,
`execve`. Each one lowers to a `syscall` instruction in a wrapper of its own: 29
`syscall` sites in the emitted object, one per call Kira's table knows this
program makes.

The SDK a Tessera program builds against is Kira and RIDL and nothing else
([roadmap/14](roadmap/14-tooling-and-ports.md),
[roadmap/18](roadmap/18-components.md)). No component compiles C, ships a C
header or binds one: libraries reach each other through their `.ridl`
contracts. The one native library is Vulkan, the one Ember's Vulkan backend
links for the GPU; there is no Dawn. WebKit WPE is the one other exception, under
the WebKit exception in `AGENTS.md`.

What remains is not what the userland says, but what it carries with it,
described below. Every program is dynamically linked, so every image with Kira
code in it carries the loader and the C library too.

## What it trusts

Tessera has no root of trust. Nothing checks the bootloader, the kernel or the
initramfs before they run: there is no secure boot, no measured boot and no
hardware key, and a virtual machine on a Mac offers none to build one on. The
system volume is read-only squashfs, so nothing running on Tessera can change
it; it is not verified, so a volume changed outside Tessera boots as though it
had not been. `dm-verity` is off and no root hash is computed. The system is
trusted only because of where its image came from.
[roadmap/13](roadmap/13-security-and-updates.md) states the threat model and
what closes this gap.

Applications are checked, but not against Tessera. A disk image may carry an
Ed25519 signature from any key. PID 1 refuses an image whose bytes do not match
its signature, and tells the owner which key signed an image it has not seen
before, or that an image is not signed at all; a second request goes ahead. No
key is built into the system, none is required and none is privileged, so the
project has no way to refuse software someone else made. A signature says who
made an image, not whether to trust them.

## Architectures

aarch64 is the target Tessera is for. x86_64 is carried alongside it for about
two years, as the compatibility architecture, and every change is expected to
work on both until that support is dropped.

There are two build hosts. On x86_64 Linux, aarch64 is cross-compiled, and its
kernel and initramfs build here; booting it is a separate matter, because QEMU's
TCG emulation of aarch64 produces no console output at all from the kernel on
this host, so `kira build boot -arch aarch64 -test` cannot be run here and the
x86_64 boot test is the one that proves anything. On Apple silicon it is the
other way round: aarch64 is the native architecture, it is compiled without a
cross toolchain and runs under Hypervisor.framework with nothing translated, and
x86_64 is not built at all — a Mac has no Linux cross compiler to build it with.

The experimental `dm2q` kernel profile targets the Snapdragon Galaxy S23+
(SM-S916B/DS). Build it with `kira build kernel devicetrees -arch aarch64
-kernel-profile dm2q`. It uses the phone's 4 KB page size and builds
`qcom/sm8550-samsung-dm2q.dtb` from `patches/linux`. The panel has no mainline
driver, so simpledrm scans out of the framebuffer the bootloader left lit. The
Adreno 740 runs as a render-only DRM/MSM device for Mesa Turnip. The STM
FTS2BA61Y touchscreen and the S2DOS05 display PMIC sit on GPIO-driven SPI and
I2C buses. The QEMU `boot` step refuses this profile.

The GPU needs Samsung's signed zap shader, which cannot be downloaded. Extract
`a740_zap.mbn` from the stock vendor partition of the firmware on the phone and
put it in `~/.tessera-build/device/dm2q/firmware/` (`Host.dm2qFirmware`). The
SQE and GMU images come from linux-firmware.

The experimental `akari` profile targets the **regular Sony Xperia XZ2**
(Snapdragon 845, Adreno 630), not the XZ2 Compact (`apollo`) or Premium. Build
its kernel and upstream device tree with:

```sh
cd tessera-packages/tessera
kira build kernel devicetrees -arch aarch64 -kernel-profile akari
```

It uses 4 KB pages, the `qcom/sdm845-sony-xperia-tama-akari.dtb` already in
Linux 7.2, the Sony TD4353 JDI panel driver, Synaptics RMI4 touch driver and
Mesa Turnip. The GPU's `a630_sqe.fw` and `a630_gmu.bin` come from linux-firmware
with SHA-256 checks. Sony Tama firmware is available as proprietary split
`a630_zap.{mdt,b00,b01,b02}` files in TheMuppets' LineageOS vendor repository.
Keep the four files locally under
`~/.tessera-build/device/akari/firmware/sony-stock/` and reconstruct the ELF
under the DT-required firmware path by running:

```sh
python3 scripts/assemble-akari-zap.py
```

This validates the vendor file digests and produces the unmodified Qualcomm
ELF at `~/.tessera-build/device/akari/firmware/a630_zap.mbn` (SHA-256
`9e5c3828fecc98fef87c8a7c841618f28a3d258c35981d1189ac03d85b547479`).
Do not commit proprietary firmware. Tessera prefers this Sony image to the
generic SDM845 linux-firmware blob; Sony GPU startup is not hardware-tested.

**This is an experimental kernel profile, not a flashable release.**
Upstream Tama warned that UFS PURGE/UNMAP could erase the bootloader partitions.
The profile now carries Shujath Mohd's September 2026 UFS power/reset patch
(`patches/linux/0021-...`) enabling the Qualcomm UFS host/PHY with GPIO 150
reset and the regulator supplies. The author's reported boot tests do not
establish its safety on this Tessera device. The installer uses `mkfs.btrfs -K`
and mounts Btrfs with `nodiscard` to avoid the UFS discard path; this is risk
mitigation, not proof that the UFS controller or firmware is safe. The upstream
DT also enables removable microSD. Tessera's internal UFS, microSD and Btrfs
storage paths have not been physically tested on an Xperia.

### Xperia XZ2 first-device fastboot test

`scripts/package-akari-fastboot-test.py` prepares a separate **temporary RAM
boot-test ZIP**, not an Android `fastboot update` ZIP or a complete Tessera
installer. For this test, Linux 7.2 was recompiled in an isolated build
directory with `CONFIG_SCSI_UFSHCD` and `CONFIG_PHY_QCOM_QMP_UFS` disabled,
and both UFS DT nodes are disabled. This keeps the UFS driver unavailable even
if the Sony bootloader applies DTBO overrides. The image contains the Tessera
initramfs with Sony Adreno 630 firmware, but it cannot install Tessera or
mount its system/data volumes on internal UFS.

```sh
python3 scripts/package-akari-fastboot-test.py
# Extract the ZIP to an empty directory before running these helpers there.
sh akari-boot-once.sh --probe
# Only after verifying the phone and a recovery strategy:
sh akari-boot-once.sh --boot-once
```

The verified ZIP is at
`~/.tessera-build/out/Tessera-XZ2-akari-FASTBOOT-RAM-TEST-UFS-OFF-20261107.zip`
(SHA-256 `125d2e8d409d39bc33aad2cac096b91599360d3d98eeab1e21e6f3b458c18cfd`).
The script requires exactly one identified and unlocked Xperia XZ2, an A/B
boot slot, the phone's actual boot partition size, matching ZIP member hashes,
and explicit serial-number confirmation before attempting `fastboot boot`.
It **never** runs `fastboot flash`, erase, unlock, or any partition write.
Actual bootloader/DTBO acceptance, GPU startup and screen output are untested.

Do not rename Tessera's SquashFS volume to Android `system.img` or run
`fastboot update` on these archives: that would not install Tessera and could
damage Android partitions. The separate UFS-enabled installer bundle is for
offline engineering only until the Sony UFS-card quirks and recovery path are
validated on hardware.
The phone's stock boot image format, slot layout, bootloader command line,
firmware compatibility, display, USB console and recovery still need to be
verified on physical hardware. Do not flash the generated kernel or use the
dm2q update packager on the Xperia. The QEMU `boot` step rejects `akari`.

`scripts/package-akari-diagnostic.py` builds a **local, non-flashable** boot
image for inspection with an Android v1 header (the Sony Tama format), a
gzip-compressed kernel with appended Akari DTB, and a Tessera zstd initramfs.
By default it verifies the effective kernel configuration and parses the DTB
with both UFS nodes disabled. `--experimental-ufs` explicitly permits the
UFS-enabled profile, requiring GPIO 150 reset, regulator properties, matching
kernel drivers and microSD still enabled. It requires an explicit
boot-partition size, refuses overwrites and writes
`DIAGNOSTIC-NOT-FLASHABLE-boot.img` (or
`EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img`), `DO-NOT-FLASH.txt` and `SHA256SUMS`.
Neither the script nor its nine tests touches a phone. Bootloader DTBO
processing remains unverified; **do not flash this image**. Run tests with
`python3 scripts/test-package-akari-diagnostic.py -v`.

The Akari offline installer staging package includes the separate Tessera
installer initramfs, recovery system, sealed system payload and experimentally
enabled UFS with checked Sony GPU firmware:

```sh
cd tessera-packages/tessera
kira build initramfs system-volume installer-image recovery-image -arch aarch64 \
  -kernel-profile akari -symbols none -lldb off -icons skip
python3 scripts/package-akari-diagnostic.py --experimental-ufs \
  --kernel "$HOME/.tessera-build/out/aarch64/kernel/akari/arch/arm64/boot/Image" \
  --dtb "$HOME/.tessera-build/out/aarch64/kernel/akari/arch/arm64/boot/dts/qcom/sdm845-sony-xperia-tama-akari.dtb" \
  --config "$HOME/.tessera-build/out/aarch64/kernel/akari/.config" \
  --initramfs "$HOME/.tessera-build/out/initramfs/initramfs.cpio.zst" \
  --boot-partition-bytes 0x4000000 \
  --out-dir "$HOME/.tessera-build/out/aarch64/akari-ufs-gpu-boot-nodiscard-candidate"
python3 scripts/package-akari-installer.py \
  --experimental-ufs --boot-candidate \
  "$HOME/.tessera-build/out/aarch64/akari-ufs-gpu-boot-nodiscard-candidate/EXPERIMENTAL-UFS-NOT-FLASHABLE-boot.img" \
  --output "$HOME/.tessera-build/out/Tessera-XZ2-akari-UFS-GPU-experimental.zip"
python3 scripts/test-package-akari-installer.py -v
```

The `0x4000000` diagnostic capacity is taken from Sony's archived board
configuration, *not measured from this particular phone*. Verify the actual
phone's partition size, DTBO handling and recovery strategy before even
considering a physical boot test. Neither script writes to a device.

Publish `system-volume` and `recovery-image` in **the same build**: recovery
embeds `system.img` at `System/Installation/system.img`. The package validates
that those images' SHA-256 checksums match, checks the embedded fs-verity digest
and installer service, checks the Akari DTB and selected UFS kernel config, and
ships a `MANIFEST.json`, `SHA256SUMS`, and a full ZIP checksum. It refuses to
overwrite an existing output. The installer carries `/init`, the Btrfs
formatter and its libraries. It creates `boot/`, a writable `data` subvolume
and a sealed read-only `system/<version>` snapshot on a new Btrfs target.
In experimental UFS mode, it additionally verifies the Sony blob and both
linux-firmware files inside the initramfs, and the Android-v1 boot candidate's
exact kernel, appended DTB, initramfs and image ID.

**Do not flash any file from this ZIP.** `install/system.img` and
`install/recovery-system.img` are Tessera SquashFS payloads, not Android
`system.img` or `recovery.img` partitions. The installer requires separate
readable system-image and empty writable Btrfs target block devices; those
devices, physical microSD layout and a safe boot path have not been established
for the Xperia XZ2. The package is offline staging, not a ready-to-use installer.

An offline Akari ARM64 userland build can be requested with
`kira build initramfs system-volume -arch aarch64 -kernel-profile akari
-symbols none -lldb off -icons skip`. On the macOS 27 host used on
2026-11-07, prefix that command with
`KLF_USE_SYSTEM_LINKER=1 TESSERA_LLVM=$HOME/.kira/toolchains/llvm/23.1.0/aarch64-macos`.
The resulting `~/.tessera-build/out/initramfs/initramfs.cpio.zst` and
`~/.tessera-build/out/system-volume/system.img` were created and their
published SHA-256 digests verified, but **neither makes the phone bootable**.
The offline engineering archive
`~/.tessera-build/out/aarch64/tessera-akari-engineering-20261107.tar.zst`
includes these, the compiled kernel, DTB and a marked non-flashable boot-image
diagnostic. It is for inspection only. Its 37.6 MB diagnostic image fits the
64 MiB boot image limit in Sony's archived Akari BoardConfig.mk; no phone's
actual boot partition was read or checked.

To call an Akari build ready to install, the kernel, DTB, matching initramfs,
and sealed system volume must all build; Sony's matching GPU firmware must be
staged; a connected Xperia must boot a verified safe boot image with a reliable
recovery method; and the display, touch, USB diagnostics and microSD system
and data volume must be tested across a reboot without accessing internal UFS.

`scripts/package-dm2q-update.py` creates a native update directory containing
`boot.img`, `init_boot.img`, `vendor_boot.img`, `dtbo.img`, `system.img`, and
their `SHA256SUMS`. It checks boot-image sizes against the device PIT and only
writes local files. `kira build devroot stage-chunks <directory> -usb`
transfers bounded chunks and asks the device to verify the stored images. It
does not write partitions. Native apply and reboot are not implemented: the
dm2q PIT has one `BOOT` partition, and Tessera has no validated recovery path
for an interrupted boot-image update.

## Building

Tessera's host build root is always `$HOME/.tessera-build`, including when the
checkout is on a Cairn-mounted workspace. Kernel source and Kbuild outputs,
guest GPU workspaces, initramfs, and system images live under that path.

On Windows, everything builds inside a Fedora WSL2 distribution. Source lives on
the Windows filesystem where the editor can reach it; build artifacts live on the
WSL ext4 filesystem under `~/.tessera-build`, because a kernel tree built over the
9p mount is roughly an order of magnitude slower.

From a Windows shell:

```powershell
.\tessera.ps1 boot -arch x86_64 -test         # build, boot, assert userland was reached
.\tessera.ps1 boot -arch x86_64 -dev          # boot interactively
```

aarch64 cannot be booted on an x86_64 host: QEMU's TCG emulation of aarch64
produces no console output from the kernel here.

From inside WSL, `kira build` takes the same commands.

On macOS aarch64 is the only architecture:

```sh
kira build boot -arch aarch64 -test          # build what changed, boot, check
kira build boot -arch aarch64 -desktop       # boot to the desktop in a window
```

`setup` on a Mac needs the Xcode command line tools installed, and arranges three
things. The compiler and linker are the LLVM bundle Kira pins and `knvm`
installs, not Homebrew's — Homebrew's `llvm` ships no linker at all, and its
`lld` is a second formula moving on a version stream of its own, so a kernel
built with `LLVM=` would link with an `ld.lld` from a different release than the
clang that produced the objects. The Linux C library the userland links against
is staged out of Debian's `-arm64-cross` packages, because Darwin's own can never
serve a Linux program whatever the architecture. The two glibc headers the
kernel's host tools include and Darwin has no equivalent of — `<elf.h>` and
`<byteswap.h>` — are staged where those tools will find them.

Homebrew still provides GNU make, coreutils, bc, wget, xz and QEMU. Those are
build tools rather than parts of Tessera, and no version of them ends up in the
image.

## What this needs from Kira

An installed Kira compiler, and the Kira checkout beside this one for one
package.

Kira is a language of the Kira Language Framework. `klf` is the framework
binary; the compiler is a driver built from the `.klfd` definitions in the
`klf-kira` checkout and installed as `kira` under `~/.klf`:

```sh
klf build ../klf-kira/languages/kira -o kira     # the native driver
cd ../klf-kira && knvm binstall                 # build, register and install it
```

`/root/.klf/bin/kira` is a **launcher**, not the compiler. It reads
`~/.klf/toolchains/kira/current.toml` and dispatches to the channel named there,
which on this host is `dev/0.1.0`:

    channel = "dev"
    version = "0.1.0"
    primary = "kira"

`kira --version` reports what the launcher selected, so it reports the installed
channel rather than the checkout's own working state. `TESSERA_KIRA` names a
compiler outright and skips the question. The build package compiles with the
toolchain the nearest `kira-toolchain.toml` pins, else the one knvm selected.

No component imports a kernel package: libtessera's `app/Backend/Linux/` is
the only code that declares a system call, and every other component reaches
the kernel through LibTessera. An installed toolchain carries its own
Foundation, so `TESSERA_KIRA_FOUNDATION` is gone. The LLVM the kernel and the
guest GPU stack are built with is the framework's own: the newest bundle under
`~/.kira/toolchains/llvm` that carries clang, which is the one the framework
links with. `TESSERA_LLVM` names a different one.

A cross target needs a sysroot holding that target's C library, because the LLVM
bundle the framework builds with carries a compiler and none. It reads the
sysroot out of the environment: `KLF_SYSROOT_<TRIPLE>` first, with the triple's
dashes as underscores, then plain `KLF_SYSROOT` for the common case of one cross
target. The build package passes the staged sysroot as the second. Two names
because a machine building for two targets has two C libraries and neither is a
sensible default for the other, while a user with one cross target should not
have to spell the triple. Without one the build fails naming the target and the
variable to set:

    kira: error: building for `aarch64-unknown-tessera` on `x86_64-unknown-linux-gnu` needs a sysroot
    holding that target's C library; set KLF_SYSROOT_AARCH64_UNKNOWN_LINUX_GNU or KLF_SYSROOT to it

A Linux program links `-lgcc_s`, so the sysroot has to carry the target's GCC
runtime too, and the framework checks for it before the link instead of passing
`--unwindlib=none`. A sysroot is a package set the user installs, so an
incomplete one is theirs to fix and the message names the missing file; the flag
that hides it produces a binary needing a `libgcc_s.so.1` the guest does not
have, and the user finds out at boot rather than at build. `kira build setup`
arranges it on both hosts — see `HANDOFF.md` §0 for the Fedora case, where the
distribution's own cross sysroot has the static half of the GCC runtime and not
the shared half.

Tessera is a target of its own, `aarch64-unknown-tessera` and
`x86_64-unknown-tessera`, with the Linux kernel behind it. It is never the host,
so every build of the userland takes a sysroot; on a Linux host of the same
architecture that is `/`. C compiled outside Kira takes the Linux triple behind
it, which `arch_linux_target` names.

The system calls the stage-1 handover needs — `chdir` and `chroot`, which
together move PID 1 out of the initramfs and into the system volume — were once
a patch carried against Kira's syscall table. They are upstream, along with the
rest of what the userland reaches the kernel through, and nothing has to be
applied to a Kira checkout before Tessera builds.

## Layout

| Path | What it holds |
|---|---|
| `kernel/VERSION` | The pinned kernel version, and the only place it is written |
| `kernel/config/` | Config fragments merged over each architecture's defconfig |
| `patches/` | Patches to upstream projects (Mesa, QEMU, virglrenderer, Linux) |
| `roadmap/` | The design documents, including the LibTessera and DeviceKit specifications |

This repository assembles Tessera. Each component (init, libtessera, devicekit,
mosaicdisplay, the Dynamic Platforms and the rest) is its own repository in
`~/Dev/tessera-projects`, beside this one, and the scripts build whatever each
checkout holds. `build/app/Components.kira` names them.

## The kernel pin

Currently Linux 7.2, from the mainline series.

Mainline is a deliberate choice over the newest longterm: it carries the
smallest set of known vulnerabilities at any moment. The cost is that mainline
has no backport stream, so staying current means moving the pin forward to each
new release rather than receiving fixes on the one that is pinned. The pin is a
single line in `kernel/VERSION`; every script reads it from there.

## What the Kira userland can and cannot do yet

Kira cross-compiles to Tessera on aarch64. That was the blocking constraint and it is
gone. `kira build` takes `--target` and names its output with `-o`:

```sh
kira build --target aarch64-unknown-tessera -o /path/to/init ../init
```

`--sysroot`, `--relocation-model` and `--linkage` are gone, and so is the fixed
`.kira-build/<triple>/main` an older compiler wrote: `-o` says where the finished
executable goes, which is why `scripts/build-initramfs.sh` writes straight into
the staging tree instead of copying from a directory it then has to look up.

Every program is dynamically linked. There is no `--linkage static` to ask
otherwise: the framework links the target's C library rather than folding it in,
and nothing on the command line turns that into a static link. What it means is
visible in the binary — the loader path the ELF header carries, and the three
libraries it needs:

```console
$ file /root/.tessera-build/out/aarch64/rootfs/init
init: ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
      interpreter /lib/ld-linux-aarch64.so.1

$ readelf -d .../init | grep NEEDED
libm.so.6   libc.so.6   libgcc_s.so.1
```

So an image carrying Kira code has to carry the dynamic loader and the C
library, at the path the ELF header names: `/lib/ld-linux-aarch64.so.1` on
aarch64, `/lib64/ld-linux-x86-64.so.2` on x86_64. A binary whose interpreter is
missing boots to "no working init found", which reads like an absent file rather
than an absent loader. `build/app/Architecture.kira` names the loader, and the
`initramfs` and `system-volume` steps check every ELF file's interpreter.

What is not settled is what such a binary *contains*. Kira's own standard
library is Kira, but the runtime beneath it is Rust, and it brings the Rust
standard library. Tessera's PID 1 leaves 43 libc symbols undefined and eleven
`_Unwind_*` that `libgcc_s` answers, and the glibc it dynamically links is a few
megabytes beside it in the image. A hand-written `_start` making the same write
through a raw syscall is 1.5 KB.

That gap is Tessera's central question rather than an optimization: an OS that
says no to libc cannot inherit one through its language's runtime. What stands
between here and a self-contained Kira userland, in increasing size:

- the framework links the target's C library rather than folding it in, so the
  dependency is a link-line fact rather than something a flag turns off
- the runtime's optional surfaces are not optional; a program that never opens a
  database still references one
- the runtime is `std`, and a freestanding userland needs it not to be

Nothing above was a reason to wait, and PID 1 is Kira today. Measured on the
things themselves: `init` is 1.2 MB on x86_64 and 1.3 MB on aarch64, and the
initramfs it rides in is 4.0 MB and 4.4 MB compressed.

### Local host preflight

From the Tessera source root, run `scripts/verify-host.sh --tests` to check
available Kira/KLF/KSL tools, local graphics assets, advisory-lock support in
`.kira-build` and the five host regression suites. The command does not boot
Tessera, does not change source files and returns a nonzero exit code when a
required preflight check fails. Use the recommended host toolchain and a
compatible build filesystem; the Cairn workspace may not support the advisory
file locks used by the build driver. Passing host tests is not a substitute
for `kira build boot -arch aarch64 -test` on a working build host.

### Boot-build lock workaround and disk guard

A Cairn filesystem may reject Kira's advisory lock in `.kira-build/lock`.
Run `scripts/boot-with-local-lock.sh --self-test` from this component's
folder to check a disposable local lock and verify restoration of the original
lock file without starting a build. On a host with adequate space, use
`scripts/boot-with-local-lock.sh --build` to run the default aarch64 boot test.
The wrapper checks for **at least 10 GiB free** on relevant local build/cache
filesystems before starting, redirects only the lock to a local temporary file,
and restores the original on exit or interruption. It serializes wrapper
invocations with an exclusive guard directory, but do not start ordinary
`kira build` processes concurrently outside the wrapper. The wrapper is not
an alternate compiler, does not solve missing platform SDK/Browser payloads,
and does not count as a successful boot unless the underlying build and boot
tests complete.

The October 31, 2026 cold boot attempt reached step 5 of 477 with the lock
workaround, but was interrupted when the local disk approached 3 GiB free.
The original lock was restored. Host tests and Linux-target compiler checks
remain separate from full boot acceptance.

Run `scripts/test-boot-with-local-lock.sh` for isolated wrapper regressions.
The test suite copies the wrapper into a disposable local directory, exercises
preservation of an existing lock, simultaneous invocation refusal, linked
and directory lock refusal, and clean handling of an absent lock. It never
starts a real build or touches the checkout's original build lock.
