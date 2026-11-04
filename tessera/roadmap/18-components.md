# 18 Components and dev roots

How Tessera is built, and how a developer changes one part of a running
machine. The goal: change one component, rebuild only that component, and try
it on a running system.

## 1. Components

A component is one project with its own build: a library, a program, a
driver or an application. The list is `tesseraComponents` in
`build/app/Components.kira`, which says which each is.

- A component uses another only through that component's installed `.ridl`
  contract and its shared library. It never reads another component's sources
  or build tree, and nothing is linked statically between components.
- A library is built with `kira build --emit shared` into
  `/System/Library/Frameworks/<Module>.framework/<Module>`, with its contract
  beside it in `Resources/<Module>.ridl`. A library only the system itself
  uses, DeviceKit ([17](17-devicekit.md) §2.3), AppKit
  ([10](10-toolkit.md)) or PlatformUI ([15](15-form-factors.md)), is a private
  framework in `/System/Library/PrivateFrameworks/` instead, as on macOS.
- A dependent imports a library by its module name and nothing else: Kira
  finds the framework in the SDK it builds against, reads its contract in
  place and links it, with a run path of the framework's installed directory
  (KLF-RIDL §27.7). Its `package.kira` names no native library for it, and no
  bindings are written into its sources.

## 2. Three roots per build

`scripts/build-component.sh <component> <arch>` builds one component into
`out/<arch>/roots/<component>/`:

- `install`: the files at their final paths on the machine, stripped.
- `symbols`: the debug information split from each binary, in
  `<path>.dSYM/Contents/Resources/DWARF/<name>` as on macOS.
- `contracts`: for a library, its `.ridl` and its stripped shared library as
  the stub a dependent links against; empty otherwise.

Components build against an SDK, as a Mac's build against `MacOSX.sdk`.
There are two, assembled under `out/<arch>/`:

    Tessera.sdk/
      SDKSettings.json              name, version, architecture, target triple
      System/Library/Frameworks/
        <Module>.framework/
          <Module>                  the stripped library, linked against
          Resources/<Module>.ridl   its contract
    Tessera.Internal.sdk/           Tessera.sdk, and also
      System/Library/PrivateFrameworks/<Module>.framework/

- `Tessera.sdk` is what a program outside the system builds against. It has
  every public framework and nothing private. It is Kira and RIDL: a program
  reaches a framework through its contract, and there are no headers, because
  no component compiles C or binds it. The one native library a program may
  link besides the frameworks is Vulkan ([14](14-tooling-and-ports.md)), and
  WebKit under the exception in `AGENTS.md`.
- `Tessera.Internal.sdk` is what the system's own components build against:
  `Tessera.sdk` with the private frameworks. Only a component on the system
  volume list builds against it.
- The frameworks are the union of every library's contracts root. What the
  linker needs below them, the target's C library and the Vulkan loader, is
  the build's sysroot (`KLF_SYSROOT`, [14](14-tooling-and-ports.md)), not
  part of either SDK.
- `SDKSettings.json` names the SDK, so a tool can tell which system and
  architecture it builds for without reading the path.

A component's build runs with its SDK as the working directory, and passes it
to Kira with `--sdk`.

A build is keyed on the toolchain, the component's sources, its Kira
dependencies, and the contracts it uses. A component whose key has not
changed is not rebuilt. `TESSERA_REBUILD=1` rebuilds it anyway.

## 3. Contracts decide what is rebuilt

A dependent is rebuilt only when a contract it uses changes. When a library
is built, its new contract is compared with the installed one in the SDKs:

- unchanged: the build says so and no dependent needs rebuilding;
- changed: the build prints the difference and the dependents to rebuild, the
  components whose sources import the library.

A changed implementation behind an unchanged contract needs no other
component rebuilt: every dependent loads the new shared library when it next
starts.

## 4. The release

A release is the union of every install root, with the platform roots: the
directory skeleton (`platform-base`), the C library (`platform-runtime`) and
the GPU stack (`platform-graphics`). `union_roots` assembles it. A path owned
by two roots is a build error that names both. `scripts/build-initramfs.sh`
builds every component, then the union, then packs it.

## 5. Dev roots

Dev mode is a machine booted with `kira build boot -dev`. It is the
desktop with `tessera.dev` on PID 1's command line, which boots `system/dev`,
a writable btrfs snapshot of the current system
([05](05-storage-and-state.md)), and starts the `devroot` service. A machine
without the flag boots its sealed system, has no such service, and nothing can
change its files.

`kira build devroot install|uninstall <component>... [-force]` builds the
install root of each component it names in the build graph, and nothing else,
packs each as an archive, puts the archives and a request on a small ext4
volume labelled `devroot`, and plugs it into the running machine through
QEMU's monitor. The service carries out the request, the build waits for its
answer on the serial line, then pulls the volume out. `kira build devroot --
wait` waits for the service to be running.

On macOS, append `-usb` to use the phone's removable USB disk. The phone
exposes a 512 MiB FAT16 image through its mass-storage LUN; the host writes the
archives and request to `/Volumes/devroot` and ejects it. The devroot service
mounts the image through a loop device, carries out the request, writes its
answer, unmounts the image, and returns it to the LUN. The host then reads the
answer and any sample or crash reports from the remounted volume. `wait -usb`
waits for that volume to appear.

The service keeps its state in `/var/db/devroots`, on the dev snapshot:

- `stack`: the installed roots, an ordered stack, bottom first.
- `roots/<name>/archive` and `roots/<name>/manifest`: each root's archive,
  and its manifest of path, type, mode and SHA-256 digest.

The base layer, what was on the machine before any root replaced it, is the
sealed system the dev snapshot was taken from, which is mounted read-only
beside it. Nothing is backed up.

The rules:

1. Install. A root goes on top of the stack. Installing a root that is
   already on the stack uninstalls it first.
2. Uninstall, per path. If a higher root also has the path, only the record is
   dropped. Otherwise the next lower layer's version is restored: a lower
   root's, else the sealed system's, reflinked from it. If no layer has the
   path, the file is deleted. Directories are handled after the files in them,
   deepest first, and only removed when empty. The result does not depend on
   the order roots are removed in.
3. Changed files. Before touching a path, the digest of the file on disk is
   compared with the manifest of the layer that put it there. A mismatch means
   something else changed the file, and the request is refused unless forced.
4. Restart. After an install or uninstall, the service sends PID 1 the paths
   that changed. PID 1 restarts every service it supervises whose process maps
   one of them, read from the kernel's map of the process
   (`Process.loads`). PID 1 itself is never restarted; a changed `/init`
   needs a reboot, and the log says so.
5. Reset. `kira build devroot reset` drops every root at once: the machine
   deletes `system/dev` and takes it again from the sealed system on its next
   boot.

## 6. The cycle

```
# edit ../date/app/main.kira
kira build boot -dev                         # once, in another terminal
kira build devroot install date              # only date, onto the machine
kira build devroot uninstall date            # the release's date again
```

A full build of the images and a reboot is for what a root cannot change:
PID 1, the boot splash, the kernel.

## Release train workspaces

`Kira-projects/` contains `development/`, `staging/`, and `worktree-name/`.
`development` and `staging` are normal clones on their own branches;
`worktree-*` are linked worktrees of development. Each contains a flat set of
sibling repositories: `tessera/`, `desktop/`, `kira-ui/`, and the rest of
Tessera's Kira dependencies. Unrelated repositories are excluded. Development
integrates changes; staging is the weekly release, cut every Thursday. Source
edits happen in worktree workspaces. Staging shares development's Git objects
and the Build content store. VM state belongs to one workspace.

`kira build train` captures an immutable artifact snapshot, identified by its
SHA-256. It records the target, build settings, component artifact indices,
boot artifact roles and repository revisions. Only committed sources may be
captured. The snapshot pins its artifacts and required action records against
cache collection, without placing another full output tree.

`kira build -base <snapshot> boot -dev` boots the pinned train through shared
artifact views and installs the workspace's changed roots when devroot is
ready. It does not rebuild or copy unchanged train artifacts into the workspace.
Component builds continue using the shared action cache. Relocatable compile
keys use source identities relative to the workspace, and discovered inputs
are checked against that workspace. A changed source invalidates its action;
only changed output digests invalidate downstream actions.

A worktree overlay compares component install and symbol digests with its
base snapshot. It packs and installs only different roots through devroot.
Components needed before devroot starts require a derived boot image rather
than a live overlay. The base snapshot is never advanced implicitly.

The installed train volume is shared as well. The first train boot installs a
read-only raw base in the system artifact's shared view. Each workspace uses
its own qcow2 disk backed by that volume, so guest writes allocate only delta
blocks. A workspace disk cannot silently switch to another train. Source
workspaces reject full train/image build steps and boots without a base;
those full builds belong to development or staging.
