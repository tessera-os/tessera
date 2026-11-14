# tessera-packages

Tessera OS: an operating system on the Linux kernel with its own userland,
written as Kira packages. `tessera/` builds the system; the rest are its
services, drivers, tools and apps.

## The system

| Folder | What it is |
| --- | --- |
| `tessera/` | The OS build: `kernel/`, `patches/`, `sysroot/`, `scripts/`, `build/`, `roadmap/` and `ROADMAP.md`. `HANDOFF.md` tracks work in progress |
| `system/` | The system volume's package: the init Tessera runs from its read-only system volume |
| `init/` | Init |
| `bootstrap/` | The service broker every named service checks in with |
| `libtessera/` | LibTessera, the services library apps link against |
| `recovery/` | Recovery: install Tessera, Disk Utility, Startup Disk and Terminal |
| `installer/` | Installs a system onto a volume |
| `devroot/` | Installs a component's build over a running development machine |

## Display and UI

| Folder | What it is |
| --- | --- |
| `mosaicdisplay/` | MosaicDisplay, the compositor |
| `kcore-surface/` | The types the display protocol is spoken in |
| `display-client/` | The display client |
| `display-check/` | The display check the boot tests use |
| `tessera-ui/` | TesseraUI: how a Kira UI program runs on Tessera's display |
| `appkit/` | AppKit: the bridge between an application and the platform |
| `platform-kit/` | PlatformKit: the contract every Dynamic Platform builds on |
| `platform-ui/` | PlatformUI: the components every Dynamic Platform draws with |
| `adaptive-desktop/`, `adaptive-mobile/`, `media/` | The desktop, mobile (phone, tablet, fold) and TV platforms |
| `core-icon/` | CoreIcon, the icon pipeline for `.tessicon` documents |

## Services

| Folder | What it is |
| --- | --- |
| `settingsd/` | The settings service, `tessera.settings` |
| `devicekit/` | DeviceKit, the driver interface |
| `devicekitd/` | The device manager, the one process that opens device nodes |
| `devices/` | Device lists and streams: audio, cameras and more |
| `power/` | Power: the power page, wake locks and scheduled wakes |
| `volume/` | Volumes, as diskarbitrationd does on macOS |
| `pasteboard/` | The pasteboard |
| `presence/` | Verifies that an interaction came from a person |
| `trash/` | The Trash |
| `reportcrash/` | The crash reporter |
| `tessera-auth/` | Cognito sign-in for Tessera-owned apps |
| `app-registry/` | Application identity, staged installation and permissions |
| `app-catalog/` | The App Store catalog and filtering |
| `calculation/` | The arithmetic behind Calculator and system search |

## Drivers

| Folder | What it is |
| --- | --- |
| `ccid-driver/` | A sample user-space smart-card driver |
| `tablet-driver/` | A sample user-space driver for QEMU's tablet |

## Command-line tools

| Folder | What it is |
| --- | --- |
| `caffeinate/`, `date/`, `diskutil/`, `ioreg/`, `pmset/` | After the macOS tools of the same names |
| `debugserver/` | The debug server |

## Apps

| Folder | What it is |
| --- | --- |
| `desktop/` | The desktop: the surface under every app, and the app launcher |
| `settings/` | Settings |
| `inlay/` | Inlay, the file manager |
| `disk-utility/` | Disk Utility |
| `about/` | About: the system version and the machine |
| `welcome/` | Welcome, shown at first start |
| `calculator/`, `clock/`, `notes/` | Calculator, Clock, Notes |
| `tessera-browser/` | A minimal web browser |
| `tessera-sign-in/` | The first-party sign-in UI |
