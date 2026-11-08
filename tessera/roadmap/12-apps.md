# 12 — Applications

The one place foreign code runs on Tessera. Everything else in the system is
Tessera's own ([01](01-principles.md)); an application is not, and the whole of
this document is about what follows from that.

Application identities and user-selected Open With / custom-link defaults are
modeled in `app-registry` ([36](36-app-lifecycle.md)). They are not yet wired
to PID 1's image-based launcher. A saved association cannot confer image trust,
filesystem access or permission to claim a web domain.

## The definition

**An application is a signed, read-only image that a person installed, mounted
and verified at launch, and run in a sandbox.**

Not a directory of files. An image — a small squashfs volume, the same shape as
the system volume and for the same reasons: it is immutable once written, a
signature over it means something, and code never lives in a mount anything can
write to.

    /Applications/notes.app       the image, as a file
    /Applications/notes.sig       its signature
    /data/appdata/notes/          its data, and nothing else's

`/Applications` is at the root, with no prefix, as on macOS. The root is the
read-only system volume, so the bytes live on the writable volume, and init
binds that volume's `Applications` directory onto `/Applications` at boot,
the way macOS firmlinks `/Applications` to its Data volume.

    inside notes.app, mounted read-only at launch:
      manifest                    what it is, what it needs
      bin                         the program
      share/                      its own assets

The data volume is `noexec` ([05](05-storage-and-state.md)) and the image file
sitting on it is data. What is executed is the *mount*, which is read-only and
verified. That separation is the point: the writable volume never holds anything
the kernel will run.

## Why not a directory

It is the obvious design and it fails on all three counts:

- **Nothing to sign.** A signature over a directory is a signature over a
  manifest of hashes, which someone has to write, verify and keep in step with
  the filesystem. A signature over an image is a signature over some bytes.
- **Writable code.** An application's files on a writable volume can be modified
  after they were verified. Verifying at install and running later is verifying
  the wrong thing.
- **No atomic install.** Half a directory is a broken application. Half a file
  is a file that fails its signature check.

## Installation

macOS's model: a person opens a container and opens the `.app` inside it.

1. A container arrives: a signed, read-only image (the `.dmg` of this
   system), sideloaded from a volume or downloaded
   ([06](06-devices-and-input.md) on why network is now on the path).
2. **Opening the container checks what it is and tells the owner.** Signed by a
   key they have accepted before: open it. Signed by a new key, or not signed at
   all: say so, name the key or say there is none, and let them decide. Bytes
   that no longer match something already accepted: refuse, because that is the
   one case where something changed behind their back.
3. The container is mounted read-only and shown in a window, as a Finder window
   shows a mounted `.dmg`: one or more `.app` bundles, each a directory with its
   manifest, program and assets.
4. **Opening a `.app` runs it** from the mounted container. Dragging it to
   Applications installs it: the container is written to `/Applications/`
   atomically ([05](05-storage-and-state.md)), the manifest is read from inside
   it, and the application is recorded as installed along with the key it was
   accepted under. From then on it is in the launcher and opens without the
   container.

What exists today is step 4, unsigned: a SquashFS or EROFS image plugged in
as a volume is mounted read-only in `/Volumes` with its programs runnable
(every other volume is `noexec`), the desktop offers the bundles at its top
the moment the volume is mounted and drops them when it goes, and PID 1 opens
one only when the volume it is on is read-only. Insert on such an application
installs it, standing in for the drag until the desktop has a pointer: PID 1
copies the image the volume was mounted from to `/Applications/<Name>.app`
atomically, and from then on opens it by mounting that file read-only through
a loop device at `/run/Applications/<Name>`, with or without the image
plugged in. `kira build container <name> <bundle.app>...` packs bundles into such
an image and plugs it into a running machine. Delete on an installed application uninstalls it:
PID 1 refuses while it is open, unmounts it and deletes the file, and leaves
its data. Installing records the image's SHA-256 in
`/data/system/applications/<Name>.sha256`, and every launch reads the file
again and refuses an image whose bytes changed since, the one refusal step 2
asks for. PID 1 answers each of these requests with a sentence the desktop
shows, such as that an image changed and cannot be opened.

Signatures say who made the bytes. The `container` step signs an image
with the developer's own Ed25519 key, or the one `-container-key` names,
unless told `-container-signed no`: a last
4096-byte block holds a magic, the public key and the signature over
everything before it, which SquashFS never reads. Before installing, PID 1
checks it with LibTessera's `signatureVerifyEd25519`. A signature that does
not match the bytes is refused as damaged. A key the owner accepted before
installs at once. A new key, shown as the first 16 hexadecimal digits of its
SHA-256, or no signature at all, is said in a sentence, and the image
installs when the owner asks again (Insert on the desktop, Install in
Inlay, which shows the sentence as an alert); that key is then remembered in
`/data/system/keys`. Opening an application straight from a disk image is
checked the same way, with Return pressed again to go ahead; an unsigned
image the owner chose to open is not asked about again until the machine
restarts, as a Mac asks once about an application from an unidentified
developer. Each opened image is shown in a window
of its own above the applications, as Finder shows a mounted `.dmg`, holding
the applications on it that are not installed. Inlay is a split view, as on
a Mac: Applications under Favorites and each opened image under Locations in
the sidebar, and the chosen place beside them. An image lists every
application on it, each opening from the image, and those already installed
say so in place of Install. Opening an application that is
already open brings it to the front, as on a Mac: PID 1 asks MosaicDisplay,
which leaves the decision to the platform.

The `.app` is a directory, as on macOS, but never a directory on a writable
volume: it only ever exists inside a read-only, signed image. That keeps
everything below true.

Uninstall is: unmount if running, delete the image and signature, and — only if
asked explicitly — the data directory. Deleting somebody's data because they
removed an application is a decision the person makes, not the system.

**Installation is the only writable operation in the system's lifetime that
introduces executable code.** It deserves to be the most carefully written path
in the machine — which means careful about *telling the truth*, not careful about
withholding permission. There is no key Tessera requires and no way for the
project to refuse somebody else's software. See
[13](13-security-and-updates.md).

## The manifest

Inside the image, so it is covered by the signature. A file per field, for the
reason in [05](05-storage-and-state.md).

    name                 Notes
    id                   notes
    exec                 bin
    needs                display input data
    version              1

`needs` is the capability list. The default is nothing: an application that does
not ask for input does not get an input channel. It is inside the signature, so
an application cannot change what it asks for after it was approved.

Keep the vocabulary short and meaningful — `display`, `input`, `data`,
`network` when there is one. A capability every application has is not a
capability.

## The sandbox

With shipped-in-the-image applications this was a later refinement. With
installed ones it is a precondition, and the roadmap order changes accordingly.

Three layers, each independently worth having.

### Descriptors — available today

The launcher passes exactly the channels the manifest asked for and closes
everything else. An application has a display connection because one was handed
to it and a data directory because a descriptor to it was passed in.

Nothing has to be denied, because nothing was given. This is real confinement
with no kernel machinery, and it is the first thing to build.

Its limit is honest: the application can still `openat` an absolute path. It was
not *given* a path to the system volume; it can still *name* one.

### A mount namespace — required before untrusted code

`CLONE_NEWNS`, and in the child a filesystem view that is:

    /              the application's own image, read-only
    /data          its own data directory, read-write, noexec
    /run/…         the sockets it was granted

and nothing else. No system volume, no other application's image, no other
application's data. `pivot_root` into it, the same manoeuvre PID 1 already does
for the system volume ([03](03-processes.md)) — the code exists and is proven.

This turns "was not given a path" into "cannot name one", and it is the
difference between confining an accident and confining an adversary.

### seccomp, and a uid

`seccomp` so an application cannot make a syscall it has no business making. The
allowed set is small and knowable, because an application's whole interface is a
socket and a data directory.

A separate uid per application, so the kernel's own permission checks agree with
the model. Needs the `setuid` family ([02](02-kernel-and-syscalls.md)), and it is
the point at which [13](13-security-and-updates.md)'s privilege-separation
question stops being theoretical.

**Order: descriptors, then namespace, then seccomp and uid.** The first is
enough to build against; the second is required before anything downloaded is
run for real; the third is defence in depth.

## Launching

1. The platform asks init to launch `notes` ([11](11-adaptive-desktop.md)).
2. Init finds `/Applications/notes.app`, **verifies its signature again**, and
   loop-mounts it read-only.
3. `clone` with the namespace flags; in the child: build the filesystem view,
   drop privileges, install the seccomp filter, plumb the granted descriptors,
   `setsid`, `execve`.
4. The application connects on the descriptor it was given.

Step 2 verifies at *launch* and not only at install, because the file lives on a
writable volume and could have changed. Once dm-verity exists
([13](13-security-and-updates.md)) the same tree can back the mount and the check
becomes continuous rather than a moment — every block verified as it is read,
which also catches a disk going bad rather than only an attacker.

Loop devices are on (`CONFIG_BLK_DEV_LOOP`), with none made ahead.

## The application's own shape

    connect to the display server on the descriptor it was given
    receive configure — this is how big you are
    build a Kira UI tree
    ask for a frame; on frame_done, render and present
    receive input; update; mark dirty
    on the connection dropping, reconnect and rebuild

That is the runner from [10](10-toolkit.md), and it should be a library every
application links rather than something each one writes. **The first application
and the library are the same piece of work** — the library is whatever the first
application needed, and the second application proves whether it was right.

## Lifecycle

- **Start.** On launch. Takes focus.
- **Not visible.** With one application in front ([11](11-adaptive-desktop.md)) the
  others are not shown, get no `frame_done`, and idle. That falls out of the
  protocol rather than being designed.
- **Stop.** `SIGTERM`, a deadline, `SIGKILL`. An application saving state on
  `SIGTERM` needs `signalfd4` and needs the deadline to be generous enough to
  finish a write and short enough not to hang a shutdown.
- **Crash.** The supervisor does **not** restart applications, only services
  ([03](03-processes.md)). An application that died says so on screen and waits.
  Restarting something that crashes on startup, in a loop, in front of a person,
  is worse than not.
- **Misbehaviour.** An application that floods the protocol, or holds buffers it
  was told to release, is disconnected ([08](08-display-server.md)). Foreign code
  makes this a requirement rather than a nicety.

## State

An application writes to its own directory and nowhere else, atomically
([05](05-storage-and-state.md)).

No shared database, no settings service, no synchronisation between
applications. Two applications that want to exchange data need a mechanism that
does not exist yet, and inventing one before something needs it would be
inventing the part of the system most likely to be got wrong.

## Distribution

The planned [App Store](25-app-store.md) adds discovery, installation and
updates. An application image remains a file that the owner can install
directly. Store listing policy governs its catalogue; it does not determine
which applications the operating system permits a person to install.

- **Sideloading** — an image on a volume — needs no network and is enough to
  develop against. It should work first, and it should never become the
  second-class path.
- **Network distribution** includes the App Store and direct downloads. The
  store is one distribution path; its catalogue does not replace image signing
  or the owner's choice of publisher.
- **Self-signing is normal.** A developer generates a key, signs their images,
  and anyone who accepts that key installs them. No enrolment, no fee, no
  review.

The sandbox is what makes this safe to say ([13](13-security-and-updates.md)):
confinement does not depend on who signed anything, so an unknown application is
contained by the same mechanism as a known one. **That is the reason the
permission gate is unnecessary** — the isolation was never what the signature was
buying.

## The first application

Small, useful, and exercising the whole stack: text, input, layout, persistence.
A notes editor — type, see it, close it, reopen it, it is still there.

That last clause is the checkpoint for this entire roadmap. It touches a process,
a socket, a buffer, a GPU, a font, a keymap, a widget tree, a signature, a
sandbox, a writable volume and an atomic write. **When a person can type a
sentence into Tessera, reboot it, and read the sentence back, the foundation is
done.**

The first application should be built into the system's own set — Tessera's
software, on the system volume — precisely so that the application model and the
installation model can be brought up separately. The *second* application is the
one that arrives from outside, and it is what proves the boundary works.

Where it stands: Notes is a page that keeps what is typed in it, in
`/data/appdata/Notes/Notes.txt`, saved after every change and on quitting.
PID 1 makes `/data/appdata/<Name>` the first time an application opens. Notes
has been typed into after arriving on a disk image and being installed, and
the text was there again after a reboot.

Applications run confined. PID 1 launches each with `LaunchFlags.confined`
and hands it its bundle and its data folder; LibTessera clones it into a
mount namespace of its own, and before the exec it pivots into an in-memory
root holding the platform's runtime read-only (`/lib`, `/usr`,
`/System/Library`, with `/dev`, `/proc` and `/sys`), the bundle read-only,
the data folder writable and without exec, and an empty `/tmp`, then sets
no-new-privileges. A step that fails ends the child with 126, so nothing
runs unconfined. Inlay, Settings and Disk Utility are the exceptions: the
system's own tools for installing, settings and disks. In a services boot
Display Check, confined, logs `checked the application's view` with
`applications: false`, `systemState: false`, `settings: false`,
`frameworks: true`, `wroteData: true` and `wroteRuntime: false`.

The view still holds the platform's runtime, which is on the system volume,
because a program links against it by path. seccomp, a uid per application
and a pid namespace are not done.

## Checkpoints

- [x] An application image is built by the build scripts, and can be signed with
      any key. `scripts/build-image.sh [--unsigned | --key <key.pem>]` builds
      and signs one with no machine running; `scripts/container.sh` builds
      through it and plugs the result in. An image signed with a freshly made
      key was refused once with its fingerprint in Inlay's alert, then
      installed on the second Install ("the owner accepted a signing key",
      "installed an application").
- [x] An application opens from a read-only image plugged in as a volume, and
      not from a volume that can be written.
- [x] An unsigned image installs after the owner is told it is unsigned.
- [x] An image that changed after being accepted is refused, and says so.
- [x] An installed application is loop-mounted read-only and launched.
- [ ] It is given exactly the descriptors its manifest asked for and nothing
      else. There is no manifest yet. A confined launch gives its parent
      channel, executable, entitlements, arguments, standard streams,
      bundle and data folder, and marks everything else close-on-exec. It
      does not give the parent's root Node, and its entitlements are only
      the defaults (16 §11.6), not the system's `*`. Display Check logs
      `rootGiven: false`, `everyEntitlement: false` and
      `defaultEntitlements: true`, and the boot test requires them.
- [x] It cannot name a path outside its own image and data directory. It
      cannot name another application, another's data, `/data/system` or
      `/etc`; it can still name the platform's runtime it links against.
      LibTessera's `Confine.kira` gives it a root of its own: the runtime
      read-only, its bundle and data, an in-memory `/tmp`, a `/dev` with
      only null, zero, full, random, urandom and the GPU, and a `/proc` of
      its own PID namespace; it execs with no capabilities. Display Check
      logs `applications: false`, `systemState: false`, `settings: false`,
      `frameworks: true`, `disk: false` (`/dev/vda`), `initRoot: false`
      (`/proc/1/root/data/system`) and `capabilities: false`, and the boot
      test requires each.
- [x] It renders a Kira UI tree through the display server.
- [x] It writes to its data directory and nowhere else. Display Check,
      confined, writes `/data/appdata/Display Check/view` and is refused
      `/System/Library/view` (`wroteData: true`, `wroteRuntime: false`);
      its `/tmp` is its own, in memory.
- [x] It survives the display server restarting. In `-services-restart`
      PID 1 kills MosaicDisplay with SIGKILL; the KiraUI application logs
      `took a replacement display link`, opens a new session with the server
      PID 1 starts again, and puts its first frame on the new scanout.
- [x] A sentence typed into it is still there after a reboot.
- [x] An application that misbehaves is disconnected and the machine carries on.
      In `-services` the display check sends a malformed display packet;
      MosaicDisplay logs `a display client disconnected or sent an invalid
      frame` for surface 2 and `an application surface went`, keeps the
      scanout, and the platform and the machine run on.

## Installer integrity follow-up (2026-10-31)

PID 1's existing Ed25519 consent check still verifies disk images prior to
installation. Its installed-image path now refuses a launch when no SHA-256
record exists, rather than launching unchecked legacy bytes. New installs
refuse to overwrite an existing display-name image; replacing an app by name
is not a safe update transaction or proof of publisher identity. A failed
integrity-record write no longer reports the new image as successfully
installed, and subsequent launch is refused. Existing installations that
predate digest records require reinstalling through the trusted installer.
The necessary versioned image slots, atomic image/metadata activation,
registry adoption, safe migration and boot tests remain unresolved; these
source changes are not an end-to-end verified installer.
