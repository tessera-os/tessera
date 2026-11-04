# DeviceKit Specification 1.0

Date: 2026-11-01. Driver API version: 26.11. Status: normative draft 1.0. Audience: every agent and engineer who implements the DeviceKit manager, a DeviceKit family, a driver, or a system service that consumes devices.

Contents

1. Status, scope and rules for implementers
2. Terminology
3. Goals, non-goals and related work
4. Architecture
5. The registry
6. Matching
7. Driver packages
8. Driver lifecycle
9. The core driver interface
10. Families: buses
11. Families: storage and networking
12. Families: graphics, display, compute and media
13. Families: audio, input, sensors and haptics
14. Families: power, platform and security
15. Families: connectivity and other devices
16. Power management
17. Firmware
18. Security and sandboxing
19. Driver API versioning
20. Development, simulation and testing
21. Logging and diagnostics
22. Conformance
23. Implementation plan
24. Appendix A: manifests, match dictionaries and properties
25. Appendix B: decision log

---

## 1. Status, scope and rules for implementers

This document is the single normative specification of DeviceKit, Tessera's driver model. It defines the device registry, how drivers are matched to devices, driver packages, the driver lifecycle including transparent restart, the core interface every driver uses, the families (device classes) and the protocols between drivers and the system, power management, firmware handling, driver security, the Driver API's versioning, and the tools to build and test drivers. A conforming implementation satisfies every MUST in this document.

### 1.1 Normative language

- MUST, MUST NOT, SHOULD, SHOULD NOT and MAY carry their RFC 2119 meanings.
- Sections or paragraphs titled "Rationale" or "Example" are informative. Everything else is normative.
- Where prose and a table disagree, the table wins. Where a RIDL declaration and prose disagree, the declaration wins.

### 1.2 Relationship to other documents

| Document | Relationship |
| --- | --- |
| `Tarwin.md` | The kernel mechanisms drivers use: device slots, MMIO, interrupts, DMA and the IOMMU, rings, driver restart (Tarwin.md section 19), the block and network data paths (sections 20 and 21), GPU memory, fences and doorbells (section 22) |
| `TIR.md` | The driver profile (TIR.md section 31.2): languages, license, source reproducibility, firmware resources, the 52-train window |
| `LibTessera.md` | The system interface every driver links |
| `Ember.md` | The GPU driver contract (Ember.md section 29.3) the GPU family implements |
| `TVISA.md` | GPU family identifiers (TVISA.md section 31.1) GPU drivers report |
| `MosaicDisplay.md` | The consumer of the display and input families |
| `KLF.md` | RIDL, in which every DeviceKit interface is declared |

### 1.3 Scope

DeviceKit covers every device a Tessera system can have, through families for every device class (sections 10 to 15). Device drivers run only in user space; the boot-critical devices the kernel drives itself are listed in Tarwin.md section 4.2. This document fixes each family's model, operations, data paths and clients; each family's complete RIDL protocol is published as `DeviceKit/Families/<Family>.ridl`, normative and versioned with the Driver API (section 19).

### 1.4 Rules for implementing agents

1. Implement behavior exactly as written. Where the document is silent, choose the behavior that keeps the device usable after a driver failure and record the choice in `docs/decisions.md` in the format of Appendix B.
2. Every family has a conformance suite (section 22). A family or driver is implemented when its suite passes on real hardware and on the device simulator (section 20.3).
3. The manager and the families are written in Kira. Drivers are written in Kira, Rust, Zig, C or C++ under TIR's driver profile (TIR.md section 31.2).

---

## 2. Terminology

| Term | Meaning |
| --- | --- |
| Manager | The DeviceKit manager service (`devicekit.manager`), which owns the registry, matching, driver processes and power policy |
| Registry | The tree of devices the system knows (section 5) |
| Node | One entry of the registry: a device, a function of a device, or a logical device a driver publishes |
| Provider | The node (and its driver) a node hangs from: a bus controller for its devices, a device for its functions |
| Family | A device class with a RIDL protocol between its drivers and the system (sections 10 to 15) |
| Driver | A process that drives one or more nodes and implements one or more families |
| Client | The system service or application that uses a family's protocol (for example the block layer, MosaicDisplay, the audio service, Ember) |
| Slot | The kernel `DeviceSlot` granting access to one hardware device (Tarwin.md section 19.2) |
| Driver API version | The `YY.M` version of all DeviceKit interfaces drivers use (section 19) |

---

## 3. Goals, non-goals and related work

### 3.1 Goals

1. Every device driver runs in user space, isolated by the IOMMU and the sandbox, and restarts transparently after a failure.
2. A modern, typed driver model: a registry with typed properties, declarative matching, RIDL protocols per family, completion-based I/O, shared-memory rings for data.
3. Coverage of every device class a phone, tablet, laptop, desktop, console, home device, server or virtual machine has.
4. Drivers are open source (GPLv3), reproducible from source, and shipped as TIR, so every driver runs on every architecture and is audited by the pipeline.
5. A stable Driver API for twelve months at a time, so vendors update yearly while Tessera moves weekly.
6. Performance equal to in-kernel drivers on the data path: no system call or IPC per I/O in the steady state.

### 3.2 Non-goals

- Binary-only drivers, kernel drivers, or Linux driver compatibility.
- Driver code in languages other than those of TIR.md section 31.2.

### 3.3 Related work (informative)

| System | What DeviceKit shares | Where it differs |
| --- | --- | --- |
| IOKit and DriverKit (Apple) | Registry, matching dictionaries, families, user-space drivers | Every driver in user space, open source, RIDL interfaces |
| Fuchsia driver framework | Component-based user-space drivers, capabilities | Families are fixed system protocols; rings shared with the kernel's data paths |
| Windows UMDF | User-space drivers, restart | IOMMU confinement mandatory; no kernel-mode alternative |
| Linux driver model | Device tree and ACPI matching, runtime power management | User space, restartable, capability-based |

---

## 4. Architecture

```
clients: block layer and network stack (kernel), MosaicDisplay, audio service, camera service,
         sensor service, input service, Ember (in applications), Bluetooth service, …
            │ family protocols (RIDL over channels; rings and shared memory for data)
            ▼
driver processes ── each in its own job and sandbox, holding its slots and family endpoints
            │ DeviceKit core interface (section 9)
            ▼
devicekit.manager ── registry, matching, launching, restart, power policy, Driver API compatibility
            │ DeviceRoot resource
            ▼
Tarwin ── device registry, slots, MMIO, interrupts, DMA and IOMMU, rings (Tarwin.md section 19)
```

1. The manager is a system-critical service started from the boot set (Tarwin.md section 6.3). It holds the kernel's `DeviceRoot` resource.
2. For each hardware device, the kernel creates a registry entry; the manager matches a driver (section 6), launches it (section 8) and grants it the device's slot.
3. A driver publishes the nodes it creates (child devices on a bus, functions, logical devices) and registers family endpoints for them.
4. Clients find devices through the registry and connect to their families' endpoints through the manager, which checks the client's authority (section 18.4).

---

## 5. The registry

### 5.1 Nodes

Every node has:

| Field | Meaning |
| --- | --- |
| Identifier | A 64-bit identifier unique for the boot |
| Stable identifier | A 128-bit value stable across boots for the same device in the same position (derived from bus path, serial number where the device has one, and the system's device salt) |
| Name | A short name for diagnostics |
| Provider | The parent node |
| Families | The families the node offers, each with its endpoint once a driver registers it |
| Properties | Typed key–value pairs (section 5.2) |
| State | `Discovered`, `Matching`, `Starting`, `Running`, `Suspended`, `Restarting`, `Failed`, `Removed` |
| Power state | Section 16.1 |
| Driver | The driver process and its version, when bound |

### 5.2 Properties

Property values are RIDL values of these types: `Bool`, `I64`, `U64`, `F64`, `String`, `[U8]`, arrays of these, and dictionaries of string keys to these. Well-known keys are namespaced by bus or family (Appendix A.3), for example `pci.vendor`, `pci.device`, `pci.class`, `usb.vendor`, `usb.product`, `usb.interfaceClass`, `acpi.hid`, `acpi.cid`, `dt.compatible`, `hid.usagePage`, `display.edid`, `storage.model`, `net.macAddress`, `power.wakeCapable`.

### 5.3 Planes

Nodes are linked in two planes:

| Plane | Edges |
| --- | --- |
| Provider plane | From each node to its provider: the tree of buses and devices |
| Power plane | From each node to every node it depends on for power, clocks, resets or interconnect bandwidth (from firmware descriptions and from drivers' declarations) |

Power operations (section 16) follow the power plane; removal follows the provider plane.

### 5.4 Queries and notifications

```
struct RegistryQuery {
    let families: [String] = []
    let properties: [(String, PropertyValue)] = []
    let states: [NodeState] = []
}

extend Registry {
    function find(borrow self, query: borrow RegistryQuery) -> [NodeInfo]
    function watch(borrow self, query: borrow RegistryQuery, port: Handle<Port>, key: U64) -> Result<Handle<Watch>, Error>
}
```

Registry access requires the system role or a family client grant; applications see only nodes of the families they are entitled to use, with properties filtered to those the family publishes to applications.

---

## 6. Matching

### 6.1 Match dictionaries

A driver package declares, for each driver it contains, one or more match dictionaries (Appendix A.2): the properties a node must have, with exact values, value lists, ranges or masks, and the families the driver will offer.

### 6.2 Scoring

For a node, the manager considers every installed driver whose Driver API version is supported (section 19) and whose dictionary matches. Candidates are ranked by:

1. Specificity: a dictionary with more matched properties outranks a less specific one; bus identities (vendor and device, vendor and product) outrank class matches.
2. Declared score, from 0 to 1,000, within the same specificity.
3. Origin: a driver of the device's vendor outranks a generic driver with the same specificity and score.
4. Recency: a newer Driver API version outranks an older one.

### 6.3 Probing

The best candidate is launched and asked to probe (section 8.2); a driver that declines (for example, because the device's firmware is too old) is stopped, and the next candidate is tried. A node that no driver accepts stays `Discovered` and is reported once at level Notice.

### 6.4 Generic drivers

Tessera ships generic class drivers that match by class: NVMe, AHCI, UFS, xHCI, USB hubs, USB HID, USB mass storage, USB audio class, USB video class, USB communication classes (CDC-ECM, CDC-NCM), CCID smart cards, HID over I2C, virtio devices, the paravirtual GPU, standard ACPI devices (batteries, buttons, lids, fans, thermal zones), and platform devices described by standard device-tree bindings. Vendor drivers outrank them where they exist.

### 6.5 Overrides

The system's device policy (set by the device's maker for certified devices, or by the user in developer mode) may pin a node to a driver, exclude a driver, or prefer generic drivers. Overrides are recorded in the registry and logged.

---

## 7. Driver packages

### 7.1 Form

A driver package is a TIR package of kind `driver` (TIR.md section 29.1) with:

| Content | Requirement |
| --- | --- |
| Modules | TIR modules in the driver profile (TIR.md section 31.2) |
| Manifest field `deviceKit` | The Driver API version the package targets |
| Manifest field `drivers` | For each driver: name, executable module, match dictionaries, families offered, families used (for drivers that consume other drivers, such as USB class drivers using the USB family), power capabilities, process model (section 8.6) |
| `license` | `GPL-3.0-only` or `GPL-3.0-or-later` |
| `source.json` | Source reproducibility record (TIR.md section 31.2) |
| Resources of kind `firmware` | Firmware images (section 17) |

### 7.2 Signing and distribution

Driver packages go through the pipeline like other packages: intake, verification, source-reproducibility rebuild, analysis, review, build, signing (TIR.md section 30). Certified devices accept only pipeline-signed driver packages and the device maker's drivers signed by the pipeline on the maker's behalf. In developer mode, development-signed drivers are accepted for devices the developer selects.

### 7.3 Installation

Drivers for a device are installed with the system image (for built-in hardware) or on demand when an unmatched device appears and a matching driver exists in the distribution catalog (for peripherals), subject to the user's consent for peripherals that need a non-generic driver.

---

## 8. Driver lifecycle

### 8.1 Launch

For each node it binds, the manager:

1. Creates a job for the driver under the manager's driver job, with the driver policy of its families (memory limit, QoS ceiling, kill on close).
2. Launches the driver's executable through the Launcher with the driver's identity and sandbox (section 18), giving it a bootstrap channel to the manager.
3. Over that channel, grants the node's `DeviceSlot` (when the node is hardware), the endpoints of the families the driver uses, and a restart-state region (section 8.5).

### 8.2 The `Driver` protocol

Every driver implements:

```
enum ProbeResult {
    Accept(U32)                 // score
    Decline(String)
}

enum StopReason { Unbind  Removed  Update  Shutdown  RestartRequested }

struct RestartInfo {
    let count: U32
    let lastFailure: String
    let state: Optional<Handle<Memory>>
}

trait Driver {
    async function probe(borrow mut self, node: borrow NodeInfo) -> ProbeResult
    async function start(borrow mut self, context: DriverContext, restart: Optional<RestartInfo>) -> Result<Void, DriverError>
    async function stop(borrow mut self, reason: StopReason) -> Result<Void, DriverError>
    async function suspend(borrow mut self, target: PowerState) -> Result<Void, DriverError>
    async function resume(borrow mut self) -> Result<Void, DriverError>
    async function prepareForRemoval(borrow mut self) -> Result<Void, DriverError>
    function diagnostics(borrow self, topic: borrow String) -> String
}
```

### 8.3 States

| From | Event | To |
| --- | --- | --- |
| `Discovered` | A candidate driver exists | `Matching` |
| `Matching` | `probe` accepts | `Starting` |
| `Matching` | Every candidate declines | `Discovered` |
| `Starting` | `start` succeeds | `Running` |
| `Starting` | `start` fails | `Matching` with the next candidate, or `Failed` |
| `Running` | `suspend` succeeds | `Suspended` |
| `Suspended` | `resume` succeeds | `Running` |
| `Running`, `Suspended` | Driver crash or hang | `Restarting` |
| `Restarting` | New instance started | `Running` |
| `Restarting` | Restart budget exhausted | `Failed` |
| Any | Device removed | `Removed` |

### 8.4 Health

The manager pings each driver's bootstrap channel at an interval set by its family (2 s by default, 500 ms for display, audio and input drivers). A driver that does not answer within the interval twice in a row is declared hung, killed and restarted. Drivers answer pings from a thread whose QoS the family sets, so a busy driver still answers.

### 8.5 Restart

1. On a crash or hang, the kernel quiesces and resets the device and keeps its kernel data paths' requests (Tarwin.md section 19.6). The manager starts a new instance of the same driver with `RestartInfo`.
2. The restart-state region is a Memory object of up to 1 MiB that the manager holds across instances; a driver may keep recovery state there (for example, which firmware is loaded and the device's negotiated configuration). It is zeroed when the driver's version changes.
3. Families whose data paths are in the kernel (block, network) resume without their clients noticing. For families whose clients talk to drivers directly, the family's client library reconnects to the new instance and restores the session (stream formats, open handles, subscriptions), reporting any data gap with the family's gap signal (`OVERRUN` on streams). Applications see no failure unless the device is gone.
4. Restart budget: the first restart is immediate, the next after 100 ms, then 1 s, then 10 s. After five failures within ten minutes, the node becomes `Failed`: its family endpoints report `DeviceUnavailable`, the manager tries the next matching driver (typically the generic driver), and the system shows the user a notice for user-visible devices.
5. Budgets from failure to resumed service: storage 500 ms, network 1 s, display 250 ms (MosaicDisplay keeps the last frame), audio 100 ms, input 100 ms.

### 8.6 Process model

By default, each bound node runs in its own driver process. A driver may declare the `shared` model in its manifest, in which one process serves every node it binds on the system (for example a USB class driver serving many identical devices); its slots and endpoints remain per node, and a crash restarts all its nodes. A family may forbid `shared` (the GPU and display families do).

### 8.7 Removal and hot-plug

Orderly removal (an eject, a Thunderbolt disconnect request) calls `prepareForRemoval` from the leaves of the provider plane upward, then `stop(.Removed)`. Surprise removal skips `prepareForRemoval`; the kernel fails outstanding requests with `DeviceRemoved` and the manager stops the subtree. Hot-plugged devices are matched like any other.

### 8.8 Driver updates

When a new version of a bound driver is installed, the manager replaces the running instance at the node's next idle point (no outstanding requests for 100 ms) using the restart path with `StopReason.Update`, so the update is invisible to clients. Drivers of the boot storage device are replaced the same way.

---

## 9. The core driver interface

### 9.1 The driver context

```
struct DriverContext

extend DriverContext {
    function node(borrow self) -> NodeInfo
    function slot(borrow self) -> Optional<Handle<DeviceSlot>>
    function restartState(borrow self) -> Handle<Memory>
    function firmware(borrow self, name: borrow String) -> Result<Handle<Memory>, DriverError>
    function publish(borrow self, child: borrow NodeDescription) -> Result<NodeHandle, DriverError>
    function unpublish(borrow self, child: NodeHandle)
    function setProperty(borrow self, key: borrow String, value: PropertyValue)
    function register<F: Family>(borrow self, node: NodeHandle, implementation: Any F) -> Result<FamilyEndpoint, DriverError>
    async function connect<F: Family>(borrow self, node: NodeHandle) -> Result<F.Client, DriverError>
    function declareDependency(borrow self, on: NodeHandle, kind: DependencyKind)
    function power(borrow self) -> PowerControl
    function log(borrow self) -> DriverLog
}
```

### 9.2 Device access

DeviceKit's library wraps the kernel's device objects (Tarwin.md section 19) in typed interfaces:

| Interface | Over | Provides |
| --- | --- | --- |
| `Registers<Layout>` | `MmioRange` | Typed register blocks declared as Kira structs with field offsets and widths; reads and writes compile to TIR `mmio.load` and `mmio.store` with the declared orderings |
| `InterruptSource` | `Interrupt` | Binding to a port, `complete()`, MSI-X vector management, moderation helpers |
| `DmaPool` | `DmaBuffer`, `IommuDomain` | Allocation of DMA-visible memory with alignment and boundary constraints, I/O virtual addresses, scatter lists; on platforms with non-coherent DMA, `prepareForDevice` and `completeFromDevice` perform the cache maintenance (aarch64 `dc cvac`, `dc ivac` allowed from user space for these mappings) |
| `ConfigSpace` | `DeviceSlot` | PCIe configuration access within the kernel's filter |
| `PowerControl` | `DeviceSlot` and platform services | Device power states, clocks, regulators, resets (section 16) |

### 9.3 Driver threads

Drivers create threads through LibTessera. A family sets the QoS ceiling of its drivers: `UserInteractive` for display, input and audio drivers, `UserInitiated` for storage, network, GPU, camera and sensors, `Utility` for the rest. Audio and display drivers may use the `Deadline` class within the budget their family's policy allows.

### 9.4 Errors

```
@Open enum DriverError {
    DeviceNotResponding
    DeviceRemoved
    FirmwareMissing(String)
    FirmwareRejected(String)
    Unsupported(String)
    InvalidRequest(String)
    OutOfMemory
    Hardware(U32, String)
}
```

---

## 10. Families: buses

### 10.1 PCI Express

The kernel enumerates PCIe hierarchies (Tarwin.md section 19.1). Each function is a node with `pci.*` properties and a slot. Additional family services:

| Feature | DeviceKit behavior |
| --- | --- |
| MSI and MSI-X | Through `InterruptSource` |
| Advanced error reporting | Errors are delivered to the driver as events; recoverable errors trigger the driver's recovery, fatal errors a restart |
| SR-IOV | A physical-function driver may enable virtual functions, which become nodes that can be bound to drivers or assigned to virtual machines (Tarwin.md section 23.5) |
| ASPM and L1 substates | Set by the manager's power policy per device class |
| ATS, PRI, PASID | Enabled when the device's family needs shared virtual addressing (Tarwin.md section 13.12) |
| Resizable BARs | Configured by the manager at enumeration to the largest size the platform allows |

### 10.2 USB

1. The xHCI driver (generic) implements the `UsbHost` family and contains DeviceKit's USB core: enumeration, hubs, configuration selection, bandwidth and power budgeting, link power management, and USB3 and USB2 port handling.
2. Each USB interface (and each device, for device-level drivers) becomes a node with `usb.*` properties. Class and vendor drivers connect to it through the `UsbDevice` family: control, bulk, interrupt and isochronous transfers submitted through a ring, with completion timestamps from the controller's frame counter.
3. USB4 and Thunderbolt routers have their own driver, which establishes USB3, DisplayPort and PCIe tunnels. A new PCIe tunnel to a device the system has not seen is established only after the user approves the device while the system is unlocked; DMA from tunneled devices is confined by the IOMMU in every case.

### 10.3 Low-speed buses

| Family | Controllers | Consumers |
| --- | --- | --- |
| `I2C`, `I3C` | SoC and PCH controllers | Touch controllers, sensors, power controllers, audio codecs |
| `SPI` | SoC controllers | Flash, displays, sensors, fingerprint sensors |
| `UART` | SoC and USB serial controllers | Bluetooth, GNSS, modems, debug consoles |
| `GPIO` | SoC and expander controllers | Every driver needing lines, with interrupt capability |
| `SDIO` | SD host controllers | Wi-Fi, Bluetooth |

Controller drivers implement the family; device drivers connect through the node's provider. Transfers are asynchronous, with completion through ports.

### 10.4 Platform devices

Devices described by the device tree or ACPI without a discoverable bus are platform nodes with `dt.*` or `acpi.*` properties, matched by `compatible` strings or `_HID` and `_CID`.

---

## 11. Families: storage and networking

### 11.1 Block

Storage drivers (NVMe, UFS, SD, USB mass storage, virtio-blk) implement the `Block` family by registering block devices with the kernel's block layer through block rings (Tarwin.md section 20.1). Each block device declares:

| Property | Content |
| --- | --- |
| Geometry | Logical and physical block size, capacity, optimal transfer size |
| Queues | Number and depth of hardware queues |
| Features | Flush, forced unit access, discard, write zeroes, atomic write size, zoned model and zone sizes, write-cache presence |
| Encryption | Inline encryption with hardware-wrapped keys, if supported (Tarwin.md section 20.3) |
| Health | Wear, temperature, media errors, self-test results |

Namespaces (NVMe) and logical units (UFS) are child nodes. Power management uses the device's autonomous power states where it has them.

### 11.2 Network interfaces

Network drivers implement the `NetworkInterface` family by registering interfaces with the kernel's network stack through network rings (Tarwin.md section 21.4): hardware address, MTU range, queues, offloads, link state and speed, statistics, wake-on-pattern support.

### 11.3 Wi-Fi

Wi-Fi drivers additionally implement the `Wifi` family, which the wireless service uses:

1. Station operation with Wi-Fi 6, 6E and 7 including multi-link operation; WPA3 (SAE, including external authentication where the firmware delegates it to the host), OWE, enterprise authentication (802.1X performed by the wireless service), protected management frames.
2. Scanning with randomized addresses, connection management commands, roaming events, link-quality reporting, regulatory domain from the regulatory service, power save, wake on wireless.
3. Optional: access point and peer-to-peer (Wi-Fi Direct, NAN) modes, monitor mode for developer tools with an entitlement.

### 11.4 Cellular

Modem drivers implement the `Cellular` family: SIM and eSIM management (through the security service for profile installation), network registration, data sessions (each a network interface), SMS, voice calls (audio through the audio family), emergency services, and modem power. The telephony service is the family's only client.

---

## 12. Families: graphics, display, compute and media

### 12.1 GPU

GPU drivers implement the `Gpu` family, which is the driver contract of Ember.md section 29.3: contexts per process, memory allocation, mapping and residency, sparse binding, user-mode or mediated queues, timelines, fault reporting, performance counters, video and protected contexts. In addition the driver:

1. Reports the GPU's family code and revision (TVISA.md section 31.3) and its capabilities.
2. Loads and manages the GPU's firmware scheduler and power management firmware.
3. Implements reset and recovery per hardware context, then per engine, then for the whole GPU.
4. Runs DVFS for the GPU with the platform's thermal limits.
5. Contains no shader compiler: GPU code arrives only as binaries from Tessera's family backends (TVISA.md section 22).

### 12.2 Display

Display controller drivers implement the `Display` family, MosaicDisplay's interface to the hardware:

| Object | Content |
| --- | --- |
| Connector | Physical output (eDP, DSI, DisplayPort, HDMI, USB-C alternate mode, wireless display), EDID and DisplayID, modes, HDR and color capabilities, variable refresh range, DSC support, link status |
| Pipe | A timing generator: mode, variable refresh, frame timing |
| Plane | Primary, overlay and cursor planes with formats and modifiers, scaling, rotation, blending, per-plane color pipeline (degamma, 3×3 matrix, gamma, 3D LUT, HDR tone mapping where present) |
| Writeback | Writeback connectors for screen capture |

1. Configuration is atomic: MosaicDisplay builds a complete state and either tests it or commits it. A commit names, per plane, the Ember texture to scan out and the shared-event value it must wait for, and returns, per pipe, the time the frame is first shown.
2. Variable refresh, panel self-refresh, adaptive sync and frame pacing are controlled per commit.
3. Foldable and multi-segment panels expose each segment and the hinge relationship; the hinge angle comes from the sensors family.
4. Backlights are a separate `Backlight` family on the panel's node.
5. Output protection (HDCP) is negotiated by the driver for protected content and reported to MosaicDisplay (Ember.md section 24).

### 12.3 NPU

NPU drivers implement the `Npu` family: contexts, memory, queues, timelines, firmware, performance states, and the NPU's family code for the ML compiler (Ember.md section 23). Like GPUs, NPUs run only code compiled by Tessera's backends.

### 12.4 Video engines

Standalone video encoders and decoders (separate from a GPU) implement the `VideoEngine` family, whose sessions and operations are Ember's explicit video model (Ember.md section 22), so Ember exposes them through the same API whatever engine performs the work.

### 12.5 Camera

1. Camera sensor drivers (`CameraSensor`) control sensors over I2C or I3C and describe their modes, controls (exposure, gain, focus, stabilization) and CSI-2 links.
2. Image signal processor drivers (`ImageSignalProcessor`) expose the processing pipeline: inputs from sensors, statistics outputs, parameter blocks, and output streams into Ember textures.
3. The camera service runs auto-exposure, auto-white-balance and auto-focus algorithms (open source) over the statistics and programs parameters each frame. Applications reach cameras only through the camera service, which enforces grants and reports activity to the system's privacy indicators; drivers cannot deliver frames to any other client.
4. Secure face authentication paths route frames directly to the security service's protected memory (section 14.4).

---

## 13. Families: audio, input, sensors and haptics

### 13.1 Audio

1. Audio drivers (integrated codecs and DSPs, USB audio class, Bluetooth audio through the Bluetooth service, HDMI and DisplayPort audio, virtio-sound) implement the `Audio` family: endpoints for playback and capture with supported formats, sample rates and channel layouts; jack and connection detection; volume and mute controls exposed by the hardware.
2. Data moves through DMA ring buffers mapped into the audio service; the driver reports the hardware position with timestamps on the monotonic clock at least once per period, so the audio service computes latency and drift exactly.
3. DSP offload is optional: compressed playback, voice processing, and wake-word detection that wakes the system (section 16.4).
4. The audio service is the family's only client; applications reach audio through LibTessera streams.

### 13.2 Input

1. Every input device is presented as HID. Drivers of HID devices (USB, Bluetooth through the Bluetooth service, I2C) pass report descriptors and reports through unchanged; drivers of non-HID input hardware (touch controllers, keyboards on embedded controllers, game controllers with proprietary protocols) translate to HID with the standard usage pages.
2. The `Input` family delivers reports with hardware or interrupt-time timestamps through a ring to the input service, which belongs to MosaicDisplay. Touch-to-ring latency: ≤ 1 ms after the device's report.
3. Output reports carry keyboard lights, controller rumble and adaptive-trigger effects, and pen haptics.
4. Precision touchpads, multi-touch screens with palm and contact data, pens with pressure, tilt, rotation and hover, and game controllers are first-class, with conformance tests per kind.

### 13.3 Sensors

1. Sensor drivers (and sensor hubs) implement the `Sensors` family: accelerometer, gyroscope, magnetometer, barometer, ambient light (illuminance and color), proximity, hinge angle, lid and tablet-mode switches, temperature and humidity, and additional types registered per Driver API version.
2. Each sensor declares ranges, resolution, rates and its hardware FIFO; the sensor service configures rates and batching and receives timestamped samples through a ring.
3. Wake-up sensors (significant motion, lid open) can wake the system.
4. The sensor service enforces permissions and rate limits for applications.

### 13.4 Haptics

Haptic actuator drivers implement the `Haptics` family: actuator characteristics (type, resonant frequency, bandwidth), predefined effects, and a real-time stream of amplitude and frequency samples synchronized with audio. The haptics service is the only client.

---

## 14. Families: power, platform and security

### 14.1 Power supplies

| Family | Content |
| --- | --- |
| `Battery` | Capacity, charge, voltage, current, temperature, health, cycle count, time estimates |
| `Charger` | Input limits, charge state, charge-limit control for battery health (for example stopping at 80%), fast-charge negotiation |
| `UsbTypeC` | Port controller and Power Delivery: data and power roles, contracts, alternate modes (DisplayPort, USB4), accessory detection, cable identity |
| `WirelessCharging` | Receiver state and negotiation |

The power service is the client of all of them.

### 14.2 Thermal

Thermal sensor and cooling-device drivers implement the `Thermal` family: zone temperatures, trip points from firmware, fans and their curves, skin temperature estimates. Tarwin's thermal policy (Tarwin.md section 26.4) consumes them through the power service.

### 14.3 Platform services

Platform drivers implement the families other drivers depend on in the power plane:

| Family | Content |
| --- | --- |
| `Clock` | Enabling, disabling and setting rates of clocks |
| `Regulator` | Voltages and enable state of supplies |
| `Reset` | Asserting and deasserting resets |
| `PinControl` | Pin multiplexing and electrical configuration |
| `PowerDomain` | Domain on and off with dependencies |
| `Interconnect` | Bandwidth and latency votes on SoC interconnects |
| `Mailbox` | Messages to co-processors and firmware (SCMI and vendor protocols) |
| `RealTimeClock` | Wall-clock persistence for the time service |

Consumers reach them through `PowerControl` (section 9.2), never directly by register access.

### 14.4 Security devices

1. TPMs, the SoC secure element's mailbox and the platform watchdog are boot-critical and driven by Tarwin itself (Tarwin.md section 4.2); DeviceKit does not bind drivers to them.
2. Biometric sensors implement the `Biometric` family: fingerprint sensors with match-on-chip or a secure path to the secure element, and face-authentication cameras whose frames go only to protected memory. Templates never leave the sensor or the secure element; the security service is the only client.
3. Smart-card readers (CCID) implement the `SmartCard` family for the security service.

---

## 15. Families: connectivity and other devices

| Family | Drivers | Client |
| --- | --- | --- |
| `Bluetooth` | HCI transports over UART, USB, SDIO, PCIe | The Bluetooth service, which runs the host stack (Classic, LE, LE Audio, mesh) |
| `Nfc` | NCI controllers | The NFC service (tags, payments through the secure element) |
| `Gnss` | GNSS receivers: positions, raw measurements, assistance-data injection | The location service |
| `Uwb` | Ultra-wideband controllers (FiRa) | The ranging service |
| `Serial` | USB CDC-ACM and other serial devices | Applications with the serial entitlement (developer tools, hardware projects) |
| `Virtio` | Generic drivers for every virtio device type, mapped onto the families above | As per family |
| `FirmwareUpdate` | Device firmware update paths: UEFI capsules, NVMe firmware commit, USB DFU, vendor mailboxes | The update service |
| `Printer` | IPP over USB (generic driver); network printers need no driver | The print service |

Devices of a class with no family in the current Driver API version cannot be supported by a driver; new families are added by Driver API versions (section 19.3).

---

## 16. Power management

### 16.1 Device power states

| State | Meaning |
| --- | --- |
| `On` | Fully operational |
| `Idle` | Operational with reduced power; resumes in under 1 ms |
| `Standby` | Context retained by the device; resumes in under 10 ms |
| `Off` | Context lost; requires re-initialization |

Drivers map these to bus states (PCI D0 to D3cold, USB suspend, ACPI and power-domain states).

### 16.2 Runtime power management

1. Each family defines when a device is idle (no open sessions, no outstanding requests, no active streams). After the family's idle delay, the manager asks the driver to suspend to the deepest state whose resume latency the device's clients tolerate.
2. Clients that need low latency hold a power assertion through their family session, which the manager honors.
3. Suspension follows the power plane: a provider suspends only after all its dependents, and resumes before any of them.

### 16.3 System sleep

On system suspend (Tarwin.md section 26.1), the manager suspends every device in power-plane order, leaving wake-capable devices armed, and resumes them in reverse order. Suspend and resume of all devices together take ≤ 300 ms each on reference devices.

### 16.4 Wake

Drivers declare which events can wake the system (input, network wake patterns, lid, power button, sensors, audio wake word, cellular). The power service decides which are armed for each sleep.

### 16.5 Performance states

Devices with performance states (GPUs, NPUs, display engines, storage, interconnects) publish their operating points; drivers select them under the power service's policy and Tarwin's thermal caps.

---

## 17. Firmware

1. Firmware images are resources of kind `firmware` in driver packages (TIR.md section 31.2). They may be proprietary. They are never executed by the CPU and are loaded into devices only by their drivers, through DMA buffers, mailboxes or register writes.
2. Vendor signatures on firmware are preserved; devices that verify firmware signatures do so as their vendors designed.
3. `DriverContext.firmware(name)` returns a sealed, read-only Memory object of the image; the manager verifies its hash against the package before handing it over.
4. Device firmware stored on the device itself (flash on the device) is updated through the `FirmwareUpdate` family, with the update service's policy and the user's consent where the device is user-owned.

---

## 18. Security and sandboxing

### 18.1 Isolation

1. Each driver process reaches only what it was granted: its slots, its family endpoints, its restart-state region and its package's firmware. It has no file system access beyond its package resources, no network endpoints, no presence and no access to other processes.
2. DMA is confined by the IOMMU to buffers the driver mapped (Tarwin.md section 19.4).
3. Drivers run with synchronous memory-tag checking where the CPU has MTE (TIR.md section 31.2).
4. A driver's job limits its memory and threads; exceeding the limit restarts it.

### 18.2 Authority of drivers over clients

Drivers never receive clients' handles beyond what the family protocol passes (memory to read or write for I/O, timelines). Family protocols are designed so that a malicious driver can corrupt only the data of its own device's clients, never escalate.

### 18.3 Source and identity

Drivers are open source under GPLv3, reproducible from the source named in `source.json` (TIR.md section 31.2), and signed by the pipeline. The manager records each bound driver's package digest and version in the registry, and attestation statements can include the driver set.

### 18.4 Clients' authority

Clients reach families through the manager, which checks:

| Family kind | Who may connect |
| --- | --- |
| Kernel-backed (`Block`, `NetworkInterface`) | The kernel only |
| System-service families (`Display`, `Input`, `Audio`, `Sensors`, `Camera`, `Bluetooth`, `Wifi`, `Cellular`, `Battery` and the other power families, `Biometric`, `Gnss`, `Nfc`, `Uwb`, `Haptics`) | The one system service the family names |
| `Gpu`, `Npu`, `VideoEngine` | Any process, through Ember, with Ember's entitlements enforced |
| `Serial`, `UsbDevice` for vendor devices | Applications with the device-access entitlement for the matching vendor and product, after user consent |

### 18.5 Privacy

Camera, microphone and location activity is visible to the system because the services that broker those devices are the families' only clients; the system shows indicators for them, and no driver can deliver their data elsewhere.

---

## 19. Driver API versioning

### 19.1 Versions

1. The Driver API comprises every RIDL interface of this document, the kernel mechanisms drivers use (Tarwin.md sections 19 to 22), and the parts of LibTessera available to drivers.
2. A new Driver API version is released with the first train of every month and named `YY.M` (TVISA.md section 32.1). The first version is 26.11.
3. A driver package targets one version (manifest field `deviceKit`).

### 19.2 Window

1. A Tessera train supports the twelve Driver API versions ending with its own month. The manager and the kernel implement every version in the window; differences between versions are bridged by compatibility layers in the manager and the families, never by the drivers.
2. A driver whose version has left the window cannot be bound.
3. A device keeps running the train it has while an installed driver's version is still in that train's window. The update service refuses to install a train whose window excludes the Driver API version of a driver that a built-in device of this system requires, and reports which driver blocks the update. If such a train is forced onto the device, the new slot fails to bring up the required device, exhausts its boot tries, and the system falls back to the previous slot (Tarwin.md section 6.5).
4. TIR's 52-train window for driver packages (TIR.md section 24.4) and the twelve-month Driver API window coincide.

### 19.3 What a version may change

| Change | Allowed |
| --- | --- |
| New families, new protocol operations, new properties | Yes |
| Changed or removed operations | Yes; the previous behavior is kept for older versions by the compatibility layers until those versions leave the window |
| Semantics of an existing operation for drivers targeting an older version | No |

### 19.4 Abandoned drivers

Tessera does not maintain drivers on a maker's behalf after the maker stops updating them. Tessera helps makers stay current: `devicekit migrate` updates a driver's source to the next Driver API version automatically wherever the change is mechanical and reports what is left; the change log of every version lists every change with its migration; and the pipeline notifies makers three months before a version leaves the window.

---

## 20. Development, simulation and testing

### 20.1 Tools

`devicekit` creates driver projects from family templates, builds and packages them through `tirc`, runs the family conformance suites, installs development-signed drivers on a developer-mode device, attaches to driver processes, and streams their logs and traces.

### 20.2 Recording

On developer-mode devices, the kernel can record a driver's register accesses, interrupts and DMA mappings with timestamps (`devicekit record`). Recordings are used to debug, to build regression tests, and to drive simulations.

### 20.3 Simulation

The device simulator runs a driver against a device model: register-level models written in Kira that implement a device's behavior, recordings replayed with response matching, or virtual devices of `tvmm` (Tarwin.md section 24). Every generic driver and every family conformance suite runs in simulation in continuous integration.

### 20.4 Fuzzing

Drivers are fuzzed on two sides in continuous integration: family protocol messages from clients, and device responses (register values, DMA contents, interrupt timing) from simulated devices. A driver must never corrupt memory outside its process, hang without the watchdog recovering it, or deliver data to the wrong client under fuzzing.

---

## 21. Logging and diagnostics

1. The manager logs under subsystem `tessera.devicekit` with categories `registry`, `match`, `launch`, `lifecycle`, `restart`, `power`, `firmware`, `security`, `update`, `family.<name>`; each driver logs under `tessera.driver.<package>` with categories it defines. Log lists control both (Ember.md section 6.4 describes the mechanism).
2. Every state change of section 8.3, every restart with its cause and duration, and every failed match are logged at Info or above.
3. Driver crashes produce crash reports like application crashes, attributed to the driver package, and are delivered to its maker through the pipeline with the user's consent.
4. `devicekit status` lists the registry with states, drivers, versions, power states and restart counts.

Diagnostic codes have the form `DK-<NNNN>`:

| Code | Meaning |
| --- | --- |
| `DK-0001` | No driver matches a node |
| `DK-0002` | Driver declined in probe (with reason) |
| `DK-0003` | Driver start failed |
| `DK-0010` | Driver restarted (with cause and duration) |
| `DK-0011` | Restart budget exhausted; node failed |
| `DK-0020` | Driver API version outside the window |
| `DK-0021` | Update blocked by a driver's Driver API version |
| `DK-0030` | Firmware missing or hash mismatch |
| `DK-0040` | Client refused: not authorized for the family |
| `DK-0050` | Device removed with outstanding requests |
| `DK-0060` | Thunderbolt or USB4 PCIe tunnel awaiting user approval |

---

## 22. Conformance

| Suite | Content |
| --- | --- |
| Manager | Registry, matching and scoring, overrides, lifecycle transitions, restart budgets, removal, updates, compatibility layers across the version window |
| Per family | Every operation of the family protocol, error behavior, power transitions, restart transparency to clients, data-path performance |
| Per driver | Its families' suites on real hardware and in simulation, fuzzing (section 20.4), suspend–resume cycles, hot-plug |
| Performance | Block and network data paths within the budgets of Tarwin.md section 34.2; input latency (section 13.2); audio position accuracy; display commit timing |

Drivers for certified devices pass their families' suites and source-reproducibility checks before they are signed for those devices.

---

## 23. Implementation plan

| Milestone | Content | Exit test |
| --- | --- | --- |
| D0 | Manager core: registry, matching, launch, lifecycle; virtio drivers | Manager suite in `tvmm` |
| D1 | Restart path with kernel data-path preservation; block and network families | Restart transparency tests with fault injection |
| D2 | GPU family with the paravirtual GPU; display and input families for MosaicDisplay | Ember and MosaicDisplay running on `tvmm` |
| D3 | PCIe and USB (xHCI, hubs, HID, mass storage, audio, video classes) | USB suites on hardware |
| D4 | NVMe, Ethernet, Wi-Fi, Bluetooth transports | Suites on hardware |
| D5 | Power management, platform families, sensors, power supplies, thermal | Power suites; 1,000 suspend–resume cycles |
| D6 | First hardware GPU family; display hardware | Ember and MosaicDisplay suites on hardware |
| D7 | Camera, audio DSPs, cellular, NFC, GNSS, UWB, biometrics | Suites on phone-class hardware |
| D8 | Simulator, recording, fuzzing infrastructure, `devicekit migrate` | Every generic driver in simulation; migration across two versions |

---

## 24. Appendix A: manifests, match dictionaries and properties

### A.1 Manifest excerpt

```json
{
  "kind": "driver",
  "identifier": "com.example.nvme-x",
  "deviceKit": "26.11",
  "license": "GPL-3.0-or-later",
  "drivers": [
    {
      "name": "NvmeX",
      "executable": "NvmeX.Main",
      "match": [
        { "pci.vendor": "0x1e0f", "pci.device": ["0x0011", "0x0013"], "score": 800 },
        { "pci.class": "0x010802", "pci.vendor": "0x1e0f", "score": 600 }
      ],
      "offers": ["Block", "FirmwareUpdate"],
      "uses": [],
      "processModel": "perDevice",
      "power": { "runtimeIdleMilliseconds": 50, "wake": [] }
    }
  ],
  "resources": [
    { "path": "firmware/nvmex-1.4.bin", "kind": "firmware" }
  ]
}
```

### A.2 Match dictionaries

A match dictionary is a JSON object whose keys are property names and whose values are:

| Form | Matches |
| --- | --- |
| Scalar | Equality |
| Array of scalars | Any of them |
| `{ "range": [low, high] }` | A numeric value in the inclusive range |
| `{ "mask": value, "bits": bits }` | A numeric value whose masked bits equal `bits` |
| `{ "prefix": "text" }` | A string with that prefix |
| `{ "present": true }` | The property exists |

The key `score` (0 to 1,000) is the declared score of section 6.2. Every other key MUST be a registered property name (A.3); unknown keys are rejected at packaging.

### A.3 Well-known properties

| Prefix | Keys |
| --- | --- |
| `pci.` | `vendor`, `device`, `subsystemVendor`, `subsystemDevice`, `class`, `revision`, `segment`, `bus`, `slot`, `function` |
| `usb.` | `vendor`, `product`, `bcdDevice`, `deviceClass`, `deviceSubclass`, `deviceProtocol`, `interfaceClass`, `interfaceSubclass`, `interfaceProtocol`, `interfaceNumber`, `speed` |
| `acpi.` | `hid`, `cid`, `uid`, `adr` |
| `dt.` | `compatible`, `model`, `path` |
| `hid.` | `usagePage`, `usage`, `vendor`, `product` |
| `display.` | `edid`, `displayId`, `connectorType` |
| `storage.` | `model`, `serial`, `firmwareRevision`, `capacity` |
| `net.` | `macAddress`, `linkSpeeds` |
| `gpu.` | `familyCode`, `revision` |
| `power.` | `wakeCapable`, `removable`, `selfPowered` |
| `node.` | `stableId`, `location`, `physicalSlot` |

---

## 25. Appendix B: decision log

| Id | Decision | Reason |
| --- | --- | --- |
| DK-D01 | Every device driver runs in user space; only boot-critical devices are driven by the kernel | Isolation, restartability, and a small kernel |
| DK-D02 | Registry with typed properties, provider and power planes, and declarative matching with scores | IOKit's proven model with modern typing |
| DK-D03 | One driver process per device by default; `shared` only when declared and allowed | A failure affects one device |
| DK-D04 | Transparent restart: kernel data paths keep requests; family client libraries restore sessions | Driver crashes are invisible to applications |
| DK-D05 | Families are fixed RIDL protocols with named system-service clients | Clear authority and a stable surface for each device class |
| DK-D06 | All input is HID; all audio uses DMA rings with timestamped positions | One input model and exact audio timing |
| DK-D07 | 3A algorithms run in the open-source camera service, not in drivers | Image quality and privacy are under system control |
| DK-D08 | Driver API versions are monthly (`YY.M`) with a twelve-month window bridged by compatibility layers in the system | Vendors update yearly while Tessera ships weekly |
| DK-D09 | Updates that would strand a required driver are refused; forced installs fall back through A/B slots | A device never ends up without its drivers |
| DK-D10 | Tessera does not maintain abandoned drivers; it provides migration tools and notices | Clear responsibility for vendors |
| DK-D11 | Drivers are GPLv3, reproducible from source, shipped as TIR; firmware may be proprietary and never runs on the CPU | Open, auditable drivers on every architecture |
| DK-D12 | New PCIe tunnels over Thunderbolt and USB4 require user approval | Defense in depth beyond the IOMMU for external devices |
| DK-D13 | Device simulation, recording and two-sided fuzzing are part of the model | Drivers are testable without hardware |

