# devroot

Installs a component's build over a running development machine, as a root
does on a Mac, and takes it off again. It runs only on a machine booted with
`tessera.dev`, as a service PID 1 starts.

A root is the install root of one component build (`scripts/build-component.sh`
in the tessera repository), packed by `scripts/devroot.sh`, which also carries
it into the machine on a volume labelled `devroot`. The volume holds a
`request` file, an `id` line and then `install <name> [force]` or
`uninstall <name> [force]` lines, and a `<name>.root` archive for each root it
installs.

For a phone connected to a Mac, append `-usb` to use the removable USB disk
instead of QEMU's ext4 image:

```sh
kira build devroot wait -usb
kira build devroot install mosaicdisplay -usb
kira build devroot uninstall mosaicdisplay -usb
kira build devroot sample 3 997 -usb
kira build devroot crashes -usb
kira build devroot kernel -usb
```

The dm2q boot image must pass `g_multi.removable=1` to the kernel, before
the `--` separator. The gadget binds before devroot creates its exchange
image. Without that parameter Linux treats the empty LUN as non-removable
and rejects the composite gadget, so neither its disk, serial console nor
network interface can enumerate. `scripts/package-dm2q-odin.py` in the
tessera package sets this for both system and installer boots. Updating
userspace alone cannot repair a boot image missing this parameter; that
boot image needs a one-time update. Subsequent component installs use USB.

The packaging regression can be run from the monorepo root with
`python3 tessera-packages/tessera/scripts/test-package-dm2q-odin.py`.
It packages synthetic inputs and checks `boot.img` inside both Odin
archives; it does not access a phone. It requires `zstd` and `lz4`.

The phone keeps a 512 MiB FAT16 image at `/var/db/devroots/exchange.img` and
exposes it through its USB mass-storage LUN. The Mac writes the request and
archives to `/Volumes/devroot`, then ejects the disk. The phone mounts the
image through a loop device, carries out the request, writes `response`,
unmounts it, and returns the image to the LUN. The Mac remounts it so the
build can read the response and any sample, crash, or kernel-log files. The
kernel request saves the current ring buffer to
`~/.tessera-build/logs/kernel-<id>.log`. Dev boots keep the kernel console at
its boot verbosity. Start `scripts/capture-dm2q-console.sh <log-file>` before
rebooting to capture that live stream; it waits for the ACM port and reconnects
after a USB disconnect.

Roots form an ordered stack, newest on top, kept in `/var/db/devroots`: each
root's archive and its manifest (path, kind, mode and SHA-256 of every entry),
and a base layer holding the files that no root owned before one replaced them.

- Installing backs up every file it replaces that no root owns into the base
  layer, then writes its own.
- Uninstalling, path by path: a path a higher root also has only loses this
  root's record. Otherwise the next lower layer's version is put back, from a
  lower root or the base layer, or the file is removed when no layer has it.
  The order roots are removed in does not change what is left.
- A file whose contents no longer match the manifest of the root that wrote it
  is not replaced or removed unless the request says `force`.

After each change the service sends PID 1 the paths it changed, and PID 1
restarts every process that has one of them mapped.

The system's `/init` can also be installed as a root. It is loaded from the
persistent dev system at the next boot, so reboot after the request completes;
the other roots remain installed. This does not update the initramfs or kernel.

Build it with the tessera repository's scripts.
