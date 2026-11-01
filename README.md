# Tessera

Tessera is an operating system built on the Linux kernel, with a userland
written entirely in [Kira](https://github.com/kira-lang-com/kira).

Tessera provides its own init, service broker, display server, UI toolkit,
system services and applications, designed together as one system. Components
communicate through typed RIDL contracts, graphics run on Vulkan, and the
system image is a sealed, read-only volume kept separate from installed
applications and user data.

This repository contains every Tessera component, from PID 1 to the apps.


## Features

- **Kira userland.** Every system component is written in Kira. The developer
  SDK consists of Kira, RIDL and Vulkan.
- **RIDL IPC.** Services and applications communicate only through typed RIDL
  contracts, brokered by `bootstrap`.
- **MosaicDisplay.** A GPU display server handling surfaces, composition, input
  routing and frame pacing.
- **Dynamic Platforms.** Adaptive Desktop, Adaptive Mobile, Console and Media
  run on the same OS and share PlatformKit.
- **Vulkan graphics.** Rendering goes through Ember on Vulkan across the stack.
- **Sealed system volume.** The system image is a read-only squashfs volume;
  applications and data live on a separate writable volume.
- **aarch64 and x86_64.** aarch64 is the primary architecture; x86_64 is
  supported alongside it.


## Status

Tessera boots to its desktop and runs applications. The full path through the
system is in place: system calls, process supervision, IPC, GPU composition,
text rendering, the UI toolkit, and a desktop that launches applications. Data
written in Notes persists across reboots on an installed system.

Planned work includes Home and personalisation, an App Store, networking,
audio, power management, additional applications, accessibility, backups, and
the security and confinement model for third-party applications.

See [tessera/ROADMAP.md](tessera/ROADMAP.md) and its 38 chapters in
[tessera/roadmap/](tessera/roadmap/) for details.


## Repository layout

Each directory is one component with its own `package.kira`.

### Core system

| Component | Description |
|---|---|
| [tessera](tessera/) | OS build, kernel configuration, roadmap and design documents |
| [init](init/) | PID 1: mounts volumes, starts and supervises services, handles shutdown |
| [bootstrap](bootstrap/) | Service broker through which services register and clients connect |
| [system](system/) | Init stage that runs once the system volume is the root |
| [installer](installer/) | Installs Tessera onto a volume from recovery media |
| [recovery](recovery/) | Recovery environment with installer, Disk Utility, Startup Disk and Terminal |

### Libraries and frameworks

| Component | Description |
|---|---|
| [libtessera](libtessera/) | System interface; the only component that declares system calls |
| [devicekit](devicekit/) | Driver interface beneath LibTessera services and Ember |
| [appkit](appkit/) | Application integration with the platform: menus, lifecycle, links |
| [tessera-ui](tessera-ui/) | Connects Kira UI programs to MosaicDisplay: surfaces, input, reconnection |
| [platform-kit](platform-kit/) | State, model and presentation contract shared by Dynamic Platforms |
| [platform-ui](platform-ui/) | Shared UI components for Dynamic Platforms |
| [display-client](display-client/) | Client library for the display protocol |
| [kcore-surface](kcore-surface/) | Display protocol types: handles, bands, buffers, textures |
| [calculation](calculation/) | Exact decimal arithmetic, used by Calculator and system search |
| [core-icon](core-icon/) | Icon pipeline that renders `.tessicon` documents on the GPU |

### Display and platforms

| Component | Description |
|---|---|
| [mosaicdisplay](mosaicdisplay/) | Display server: surfaces, composition, input routing, frame pacing |
| [adaptive-desktop](adaptive-desktop/) | Desktop platform with pointer input, windows and multiple displays |
| [adaptive-mobile](adaptive-mobile/) | Platform for phones, tablets and foldables |
| [media](media/) | Platform for televisions and streaming devices |
| [desktop](desktop/) | Base surface that lists and opens installed applications |

### Applications

| Component | Description |
|---|---|
| [notes](notes/) | Text notes persisted between launches |
| [calculator](calculator/) | Exact decimal calculator with history |
| [clock](clock/) | Clock, stopwatch and timers |
| [settings](settings/) | System preferences |
| [about](about/) | System version and hardware information |
| [inlay](inlay/) | File manager for documents, folders, volumes, disk images and app installation |
| [disk-utility](disk-utility/) | Volume management |
| [welcome](welcome/) | First-run experience |
| [tessera-browser](tessera-browser/) | Web browser based on WebKit WPE, rendering through Vulkan |

### Services

| Component | Description |
|---|---|
| [devicekitd](devicekitd/) | Device manager: opens devices, checks entitlements, passes descriptors |
| [settingsd](settingsd/) | Settings service backed by the data volume |
| [pasteboard](pasteboard/) | Clipboard service; reads require a verified interaction token |
| [presence](presence/) | Verifies interaction tokens before actions taken on the user's behalf |
| [trash](trash/) | Trash service with Put Back |
| [volume](volume/) | Disk discovery, file system probing, mounting and ejecting |
| [power](power/) | Power state, wake locks and scheduled wakes |
| [devices](devices/) | Audio, camera, sensor and haptics device access |
| [reportcrash](reportcrash/) | Crash reporter that writes diagnostic reports from core dumps |

### Drivers

| Component | Description |
|---|---|
| [ccid-driver](ccid-driver/) | Sample user-space driver for CCID smart card readers |
| [tablet-driver](tablet-driver/) | Sample user-space driver for USB tablets |

### Command-line tools

| Component | Description |
|---|---|
| [diskutil](diskutil/) | Disk and volume operations |
| [ioreg](ioreg/) | Prints the device registry |
| [pmset](pmset/) | Reports power state |
| [caffeinate](caffeinate/) | Holds a wake lock for a duration or while a command runs |
| [date](date/) | Prints or sets the system time |

### Development

| Component | Description |
|---|---|
| [devroot](devroot/) | Installs and removes component builds on a running development machine |
| [debugserver](debugserver/) | Debug server for development builds |
| [display-check](display-check/) | Boot test that draws frames and logs key input |


## Building

Requirements: the [Kira](https://github.com/kira-lang-com/kira) toolchain and
its LLVM bundle. Cross builds also require a target sysroot. See
[tessera/](tessera/) for full setup instructions.

**Windows** (builds inside a Fedora WSL2 distribution):

```powershell
.\tessera\tessera.ps1 boot -arch x86_64 -test    # build, boot, verify userland starts
.\tessera\tessera.ps1 boot -arch x86_64 -dev     # boot interactively
```

**macOS** (aarch64):

```sh
cd tessera
kira build boot -arch aarch64 -test              # build changed components, boot, verify
kira build boot -arch aarch64 -desktop           # boot to the desktop in a window
```

Tessera currently targets Linux 7.2 (mainline).


## Contributing

Read [tessera/AGENTS.md](tessera/AGENTS.md) before contributing. It covers the
repository layout, verification, and how changes are reviewed and landed.

Key rules: all code is written in Kira, components communicate only through
RIDL, and WebKit WPE (used by the browser) is the only foreign engine.
