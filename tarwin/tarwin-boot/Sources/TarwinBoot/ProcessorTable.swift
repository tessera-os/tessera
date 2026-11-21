import KCore

public enum ProcessorFamily { case arm64, x64, rv64 }

public struct FirmwareProcessor {
  public let hardwareID: UInt64
  public let acpiUID: UInt32?
  public static var empty: Self { .init(hardwareID: 0, acpiUID: nil) }
}

private struct StagedCPUs {
  let family: ProcessorFamily
  let storage: UnsafeMutableBufferPointer<FirmwareProcessor>
  var count = 0

  mutating func append(_ id: UInt64, uid: UInt32?) -> Bool {
    guard count < storage.count else { return false }
    switch family {
    case .arm64: guard id & ~UInt64(0xff00_ffffff) == 0 else { return false }
    case .x64: guard id < UInt32.max else { return false }
    case .rv64: guard id != .max else { return false }
    }
    for i in 0..<count
    where storage[i].hardwareID == id || (uid != nil && uid == storage[i].acpiUID) {
      return false
    }
    storage[count] = .init(hardwareID: id, acpiUID: uid)
    count += 1
    return true
  }
}

/// ACPI MADT (signature APIC). Counts firmware-enabled processors only; an
/// online-capable but disabled processor is not an already usable CPU.
/// The caller provides private scratch and discards all records on failure.
public func madtProcessors<S: ByteSource>(
  _ s: S, family: ProcessorFamily,
  into storage: UnsafeMutableBufferPointer<FirmwareProcessor>
) -> Int? {
  guard s.byteCount() >= 44, little(s, at: 0, bytes: 4) == 0x4349_5041 else { return nil }
  let end = little(s, at: 4, bytes: 4)
  guard end >= 44, end <= s.byteCount() else { return nil }
  var sum: UInt8 = 0
  for i in 0..<end { sum &+= s.byteAt(i) }
  guard sum == 0 else { return nil }
  var cpus = StagedCPUs(family: family, storage: storage)
  var pos: UInt64 = 44
  while pos < end {
    guard end - pos >= 2 else { return nil }
    let n = UInt64(s.byteAt(pos + 1))
    guard n >= 2, n <= end - pos else { return nil }
    let flags: UInt64
    let id: UInt64
    let uid: UInt32
    switch s.byteAt(pos) {
    case 0:  // Local APIC
      guard family == .x64, n == 8 else { return nil }
      flags = little(s, at: pos + 4, bytes: 4)
      uid = UInt32(s.byteAt(pos + 2))
      id = UInt64(s.byteAt(pos + 3))
      if flags & 1 != 0 && id == 255 { return nil }
    case 9:  // Local x2APIC
      guard family == .x64, n == 16, little(s, at: pos + 2, bytes: 2) == 0 else { return nil }
      flags = little(s, at: pos + 8, bytes: 4)
      uid = UInt32(little(s, at: pos + 12, bytes: 4))
      id = little(s, at: pos + 4, bytes: 4)
    case 11:  // GICC: ACPI 5.1+ form with MPIDR
      guard family == .arm64, n >= 76 else { return nil }
      flags = little(s, at: pos + 12, bytes: 4)
      uid = UInt32(little(s, at: pos + 8, bytes: 4))
      id = little(s, at: pos + 68, bytes: 8)
    case 24:  // RISC-V hart interrupt controller, version 1
      guard family == .rv64, n >= 36, s.byteAt(pos + 2) == 1 else { return nil }
      flags = little(s, at: pos + 4, bytes: 4)
      uid = UInt32(little(s, at: pos + 16, bytes: 4))
      id = little(s, at: pos + 8, bytes: 8)
    default:
      pos += n
      continue
    }
    if flags & 1 != 0 && !cpus.append(id, uid: uid) { return nil }
    pos += n
  }
  return cpus.count == 0 ? nil : cpus.count
}

private func matches<S: ByteSource>(
  _ s: S, at: UInt64, length: UInt64,
  _ name: StaticString, cstring: Bool = false
) -> Bool {
  let n = name.utf8CodeUnitCount
  guard length == UInt64(n + (cstring ? 1 : 0)) else { return false }
  for i in 0..<n where s.byteAt(at + UInt64(i)) != name.utf8Start[i] { return false }
  return !cstring || s.byteAt(at + UInt64(n)) == 0
}

/// DTSpec /cpus: one complete reg tuple per enabled CPU. Non-CPU children
/// (cpu-map, idle-states, caches) and subnodes of a CPU never create a CPU.
public func treeProcessors<S: ByteSource>(
  _ s: S, family: ProcessorFamily,
  into storage: UnsafeMutableBufferPointer<FirmwareProcessor>
) -> Int? {
  guard family != .x64 else { return nil }
  var cpus = StagedCPUs(family: family, storage: storage)
  var c = openTree(s)
  var parent = false
  var found = false
  var cpu = false
  var enabled = true
  var addressCells: UInt64 = 0
  var sizeCells = false
  var id: UInt64?
  var status = false
  var deviceType = false
  var parentStatus = false
  while !c.ended {
    let x = nextItem(s, c: &c)
    guard !c.failed else { return nil }
    if x.token == 1 && c.depth == 2 {
      parent = matches(s, at: x.nameAt, length: x.nameLength, "cpus")
      if parent {
        guard !found else { return nil }
        found = true
      }
    }
    guard parent else { continue }
    if x.token == 1 && c.depth == 3 {
      cpu = x.nameLength > 4 && big(s, p: x.nameAt, n: 4) == 0x6370_7540
      if cpu {
        guard addressCells != 0 && sizeCells else { return nil }
        id = nil
        status = false
        deviceType = false
        enabled = true
      }
    }
    if x.token == 3 {
      func prop(_ name: StaticString) -> Bool {
        matches(s, at: x.nameAt, length: x.nameLength, name)
      }
      if c.depth == 2 {
        if prop("#address-cells") {
          guard x.valueLength == 4, addressCells == 0 else { return nil }
          addressCells = big(s, p: x.valueAt, n: 4)
          guard addressCells == 1 || addressCells == 2 else { return nil }
        } else if prop("#size-cells") {
          guard !sizeCells, x.valueLength == 4, big(s, p: x.valueAt, n: 4) == 0 else { return nil }
          sizeCells = true
        } else if prop("status") {
          guard !parentStatus,
            matches(s, at: x.valueAt, length: x.valueLength, "okay", cstring: true)
          else { return nil }
          parentStatus = true
        }
      } else if c.depth == 3 && cpu {
        if prop("reg") {
          guard id == nil, x.valueLength == addressCells * 4 else { return nil }
          id = big(s, p: x.valueAt, n: x.valueLength)
        } else if prop("device_type") {
          guard !deviceType, matches(s, at: x.valueAt, length: x.valueLength, "cpu", cstring: true)
          else { return nil }
          deviceType = true
        } else if prop("status") {
          guard !status, x.valueLength >= 2,
            nul(s, p: x.valueAt, limit: x.valueAt + x.valueLength) == x.valueAt + x.valueLength - 1
          else {
            return nil
          }
          status = true
          enabled = matches(s, at: x.valueAt, length: x.valueLength, "okay", cstring: true)
          if !enabled {
            guard
              matches(s, at: x.valueAt, length: x.valueLength, "disabled", cstring: true)
                || matches(s, at: x.valueAt, length: x.valueLength, "reserved", cstring: true)
                || matches(s, at: x.valueAt, length: x.valueLength, "fail", cstring: true)
                || (x.valueLength >= 7 && big(s, p: x.valueAt, n: 5) == 0x66_6169_6c2d)
            else { return nil }
          }
        }
      } else if c.depth == 3 && prop("device_type")
        && matches(s, at: x.valueAt, length: x.valueLength, "cpu", cstring: true)
      {
        return nil  // A CPU with a reg tuple needs a cpu@<address> node.
      }
    }
    if x.token == 2 {
      if c.depth == 2 && cpu {
        guard let id, deviceType else { return nil }
        if enabled && !cpus.append(id, uid: nil) { return nil }
        cpu = false
      } else if c.depth == 1 {
        parent = false
      }
    }
  }
  return cpus.count == 0 ? nil : cpus.count
}
