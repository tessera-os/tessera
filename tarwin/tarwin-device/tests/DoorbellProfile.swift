// Compile-only concrete specialization. Indirect platform hooks prevent the
// optimizer from turning grants and their retirement into unconditional no-ops.
import TarwinABI
import TarwinIO
import TarwinObject
import TarwinSyscall

public struct ProfileDevices: GroupTeardown, DoorbellVmLifetime {
  public let hook: @convention(c) (UInt32, UInt64, UInt64) -> UInt32
  public func installWriteOnlyUcNx(
    _ mapping: DoorbellMapping, in process: UnsafePointer<ObjectHeader>
  ) -> DoorbellInstall {
    switch hook(0, mapping.physical, process.pointee.koid) {
    case 0: return .installed
    case 1: return .unchanged
    default: return .needsRevocation
    }
  }
  public func unmapAndSync(_ mapping: DoorbellMapping, in process: UnsafePointer<ObjectHeader>)
    -> Bool
  {
    hook(1, mapping.physical, process.pointee.koid) == 0
  }
  public func retire(_ header: UnsafePointer<ObjectHeader>) { _ = hook(2, header.pointee.koid, 0) }
  public func maskInterrupts(group: UInt64) -> Bool { hook(3, group, 0) == 0 }
  public func revokeMaps(group: UInt64) -> Bool { hook(4, group, 0) == 0 }
  public func retireDma(group: UInt64) -> Bool { hook(5, group, 0) == 0 }
  public func reset(group: UInt64) -> Bool { hook(6, group, 0) == 0 }
}

public func profileDoorbellGrant(
  _ query: DoorbellGrantQuery, process: inout ProcessExecution, tree: borrowing JobTree,
  registry: borrowing HardwareRegistry,
  resources: inout DoorbellResources<ProfileDevices, ProfileDevices>
) -> CallResult {
  resources.issue(query, to: &process, tree: tree, registry: registry)
}

public func profileDoorbellUnmap(
  _ group: UInt64, resources: inout DoorbellResources<ProfileDevices, ProfileDevices>
) -> Bool {
  resources.revokeMaps(group: group)
}
