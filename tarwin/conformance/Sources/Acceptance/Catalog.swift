import Foundation

func nativeStorageCases(_ transports: [String]?) -> [String] {
  guard let transports else { return ["storage.native.inventory"] }
  return ["storage.native.unenrolled-denied"]
    + transports.flatMap { transport in
      [
        "bounded-read-bytes", "isolated-requester", "protected-pages-denied",
        "adjacent-pages-denied",
        "wrong-direction-denied", "stale-generation-denied", "failed-invalidation-quarantine",
        "queue-specific-authority", "revoke-before-reuse",
      ].map { "storage.native.\(transport).\($0)" }
    }
}

// Each key is an independently required result, not a suite-wide "pass".
func cases() -> [String] {
  return [
    "objects.types-rights-signals", "objects.handle-lifetime", "ipc.channel", "ipc.port",
    "ipc.ring", "ipc.call", "ipc.cancel", "ipc.peer-death",
    "syscall.valid-index", "syscall.invalid-index", "syscall.continuous-fuzz",
    "ring.continuous-fuzz",
    "sched.fairness", "sched.precedence-starvation", "sched.deadline-admission-budget",
    "sched.inheritance-donation", "sched.work-interval", "sched.heterogeneous-placement",
    "memory.cow", "memory.file", "memory.compression-swap", "memory.purge-jetsam",
    "memory.large-pages", "memory.tags", "memory.sva", "allocator.type-isolation",
    "allocator.zero-tag-quarantine", "allocator.failure", "loader.relocations",
    "loader.image-integrity", "loader.page-integrity", "loader.expiry-revocation",
    "loader.train-target", "security.control-flow", "security.shadow-stack",
    "security.user-memory", "security.gated-writer", "security.speculation-cpu-model",
    "device.dma-isolation", "device.interrupts", "device.restart-under-load",
    "device.hotplug-removal", "storage.trfs-format-reference", "storage.power-cut",
    "storage.encryption", "storage.qos", "net.packetdrill", "net.ipv6", "net.offloads",
    "net.filters", "net.vpn", "hv.guest-tessera", "hv.guest-linux", "hv.guest-android",
    "hv.guest-windows", "hv.architecture-suite", "hv.device-assignment", "hv.dirty-log",
    "tvmm.snapshot-restore", "tvmm.migration", "tvmm.hotplug", "tvmm.job-limits",
    "tvmm.venus", "tvmm.tvgpu-metal", "tvmm.console", "android.per-window-surfaces",
    "android.grant-isolation",
    "power.10000-cycles", "power.wake", "power.thermal", "boot.ab-fallback", "boot.rollback",
    "boot.recovery", "boot.soft-reboot", "boot.live-update", "probes.verifier-positive",
    "probes.verifier-negative", "probes.hooks", "trace.log-filter-ring", "trace.perfetto",
    "trace.counters-ownership", "trace.panic-warm-reset", "trace.debug-only",
    "train.native-abi", "train.driver-window", "train.bib-window", "train.limits",
    "train.diagnostics", "train.kernel-profile", "train.layers",
    "security.capability-only", "security.measured-firmware", "security.cpu-admission",
    "security.return-control-flow", "security.indirect-control-flow",
    "security.code-pointer-integrity",
    "platform.driver-boundary", "platform.completion-rings", "platform.no-loadable-modules",
    "hv.access", "hv.creator-thread", "hv.register-sets", "hv.cancel-running",
    "hv.map-protect-unmap", "hv.remote-shootdown", "hv.interrupt-routing", "hv.timer-offset",
    "hv.assignment-iommu", "hv.assignment-interrupt", "hv.assignment-mmio",
    "hv.exit.mmio", "hv.exit.hypercall", "hv.exit.system-register", "hv.exit.wait",
    "hv.exit.exception", "hv.exit.debug", "hv.exit.shutdown-reset",
    "hv.guest.pv-clock", "hv.guest.steal-time", "hv.guest.spin-yield", "hv.guest.detect",
    "tvmm.pci-msi-msix", "tvmm.cpu-topology", "tvmm.direct-boot-tbib", "tvmm.secure-uefi-vtpm",
    "tvmm.block-multiqueue", "tvmm.net-nat-bridge", "tvmm.rng", "tvmm.vsock", "tvmm.input",
    "tvmm.audio", "tvmm.fs-grant-dax", "tvmm.iommu", "tvmm.balloon", "tvmm.pmem", "tvmm.ptp",
    "tvmm.scanout-surfaces", "tvmm.snapshot-incremental", "tvmm.cpu-hotplug",
    "android.input", "android.clipboard", "android.notifications", "android.audio",
    "android.camera-grant", "android.file-grant", "android.job-sandbox",
    "probes.signed-native", "probes.resource", "probes.maps-and-rings", "probes.helper-isolation",
    "trace.per-cpu-events", "trace.user-ring", "trace.monotonic", "trace.counter-callchains",
    "trace.crash-report", "trace.debug-dump", "trace.stop-all", "trace.release-no-debugger",
    "train.hv-version", "train.changelog", "train.decisions", "train.external-contracts",
    "security.attestation-challenge", "security.key-isolation", "device.metal-paravirtual-gpu",
    "tvmm.metal-context-grants", "tvmm.metal-clear-blit", "tvmm.metal-ordered-release",
    "tvmm.metal-quarantine", "tvmm.mosaic-present-deadline",
  ] + limitCases + diagnosticCases + probeHooks
    + (1...22).map {
      String(format: "decision.TW-%03d", $0)
    }
}

private let limitCases = [
  "cpus", "physical-memory", "numa-nodes", "processes", "threads-default", "threads-policy",
  "handles-default", "handles-policy", "channel-bytes", "channel-handles", "queue-default",
  "queue-option", "port-packets", "ring-range-and-power-of-two", "mappings", "memory-object-bytes",
  "timers", "virtual-machines", "vcpus", "probe-instructions", "probe-map-entries",
].map { "limits." + $0 }

private let diagnosticCases = [
  "K0001", "K0002", "K0003", "S0001", "S0002", "S0003", "S0004", "S0010", "B0001",
  "B0002", "B0003", "B0004", "D0001", "D0002", "D0003", "H0001", "P0001", "P0002",
  "P0003", "P0004", "P0005", "P0006", "P0007",
].map { "diagnostic.TARWIN-" + $0 }

private let probeHooks = [
  "tracepoint", "function", "scheduler", "syscall", "block-file", "packet", "endpoint", "audit",
].map { "probes.hook." + $0 }

func platformCases(_ arch: String, backend: String?) -> [String] {
  switch arch {
  case "aarch64":
    return [
      "hv.vhe-stage2", "hv.vgic-its", "hv.vgic-ack-eoi", "hv.vgic-masked-pending",
      "hv.cntvoff", "hv.virtual-timer-ppi", "hv.arm-scalar-mmio",
    ]
  case "rv64":
    return [
      "hv.hs-gstage", "hv.imsic", "hv.imsic-guest-file", "hv.imsic-claim",
      "hv.htimedelta", "hv.vstimecmp", "hv.rv-scalar-mmio", "hv.rv-compressed-mmio",
    ]
  case "x64":
    let common = ["hv.exit.port-io", "hv.tsc-offset-scale"]
    if backend == "vmx" { return common + ["hv.vmx-ept", "hv.apicv"] }
    if backend == "svm" { return common + ["hv.svm-npt", "hv.avic"] }
    return common + ["hv.vmx-ept", "hv.apicv", "hv.svm-npt", "hv.avic"]
  default: return []
  }
}

struct Budget {
  let name: String
  let baseline: String
  let limit: Double
  let lower: Bool
}

func budgets(_ battery: Bool) -> [Budget] {
  var all: [Budget] = []
  for key in ["switch", "wake", "ipc.pipe", "ipc.unix-socket", "ipc.futex"] {
    all.append(Budget(name: key, baseline: "linux", limit: 1, lower: true))
  }
  for key in ["fault.anon", "fault.file", "launch.main"] {
    all.append(Budget(name: key, baseline: "linux", limit: 1.05, lower: true))
  }
  for key in [
    "fio.read4k.q1", "fio.write4k.q1", "fio.read4k.q32", "fio.write4k.q32",
    "fio.read1m.seq", "fio.write1m.seq",
  ] {
    all.append(Budget(name: key, baseline: "linux-io_uring", limit: 0.95, lower: false))
  }
  for key in ["create", "lookup", "rename", "delete"] {
    all.append(Budget(name: "metadata." + key, baseline: "best-fs", limit: 0.95, lower: false))
  }
  for key in ["iperf3.tcp", "netperf.tcp_rr", "udp.pps", "tirc.corpus"] {
    all.append(Budget(name: key, baseline: "linux", limit: 0.95, lower: false))
  }
  for key in ["spec2017.rate", "spec2017.speed"] {
    all.append(Budget(name: key, baseline: "linux", limit: 0.99, lower: false))
  }
  all.append(Budget(name: "guest.kernel-build.rate", baseline: "kvm", limit: 0.95, lower: false))
  if battery {
    for key in ["power.idle", "power.video"] {
      all.append(Budget(name: key, baseline: "linux", limit: 1, lower: true))
    }
  }
  all.append(Budget(name: "interactive.wake-p99-us", baseline: "absolute", limit: 50, lower: true))
  all.append(Budget(name: "deadline.release-p999-us", baseline: "absolute", limit: 20, lower: true))
  all.append(Budget(name: "switch.same-process-us", baseline: "absolute", limit: 0.8, lower: true))
  all.append(Budget(name: "switch.cross-process-us", baseline: "absolute", limit: 1.2, lower: true))
  all.append(Budget(name: "hv.mmio-us", baseline: "absolute", limit: 2, lower: true))
  all.append(Budget(name: "hv.hypercall-us", baseline: "absolute", limit: 0.5, lower: true))
  all.append(Budget(name: "hv.cpu-bound", baseline: "bare-metal", limit: 0.98, lower: false))
  all.append(Budget(name: "probe.trivial-ns", baseline: "absolute", limit: 50, lower: true))
  return all
}
