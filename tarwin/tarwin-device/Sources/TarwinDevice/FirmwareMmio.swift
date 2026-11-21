import KCore
import TarwinBoot

/// Offsets in the same immutable boot-validated FDT, not MMIO or DMA addresses.
public struct FdtBytes: Equatable {
  public let at: UInt64, length: UInt64
}
public struct FirmwareMmio: Equatable {
  public let node: UInt64, parent: UInt64, registers: DeviceRange
  /// Raw binding-specific interrupt cells: the interrupt-controller driver
  /// resolves the phandle and decodes these before any vector is granted.
  public let interruptParent: UInt32?, interrupts: FdtBytes?, interruptsExtended: FdtBytes?
}

private struct Frame {
  let node: UInt64
  var enabled: Bool, interruptParent: UInt32?
  var addressCells: UInt64 = 2, sizeCells: UInt64 = 1
  var ranges: FdtBytes?, reg: FdtBytes?, interrupts: FdtBytes?, extended: FdtBytes?
  var seen: UInt16 = 0, simple = false, virtio = false
  mutating func take(_ bit: UInt16) -> Bool {
    guard seen & bit == 0 else { return false }
    seen |= bit
    return true
  }
}
private func same<S: ByteSource>(_ s: S, _ p: UInt64, _ n: UInt64, _ text: StaticString) -> Bool {
  guard n == text.utf8CodeUnitCount else { return false }
  for i in 0..<text.utf8CodeUnitCount where s.byteAt(p + UInt64(i)) != text.utf8Start[i] {
    return false
  }
  return true
}
private func number<S: ByteSource>(_ s: S, _ p: UInt64, _ n: UInt64) -> UInt64 {
  var v: UInt64 = 0
  for i in 0..<n { v = v << 8 | UInt64(s.byteAt(p + i)) }
  return v
}
private func property<S: ByteSource>(_ s: S, _ item: FdtItem, _ f: inout Frame) -> Bool {
  let p = item.valueAt
  let n = item.valueLength
  let bytes = FdtBytes(at: p, length: n)
  func isName(_ name: StaticString) -> Bool { same(s, item.nameAt, item.nameLength, name) }
  if isName("status") {
    guard f.take(1), n > 1, s.byteAt(p + n - 1) == 0 else { return false }
    f.enabled = f.enabled && (same(s, p, n - 1, "okay") || same(s, p, n - 1, "ok"))
  } else if isName("compatible") {
    guard f.take(2), n > 0 else { return false }
    var start: UInt64 = 0
    while start < n {
      var i = start
      while i < n && s.byteAt(p + i) != 0 { i += 1 }
      guard i > start, i < n else { return false }
      f.virtio = f.virtio || same(s, p + start, i - start, "virtio,mmio")
      f.simple = f.simple || same(s, p + start, i - start, "simple-bus")
      start = i + 1
    }
  } else if isName("#address-cells") {
    guard f.take(4), n == 4 else { return false }
    f.addressCells = number(s, p, 4)
  } else if isName("#size-cells") {
    guard f.take(8), n == 4 else { return false }
    f.sizeCells = number(s, p, 4)
  } else if isName("reg") {
    guard f.take(16) else { return false }
    f.reg = bytes
  } else if isName("ranges") {
    guard f.take(32) else { return false }
    f.ranges = bytes
  } else if isName("interrupt-parent") {
    guard f.take(64), n == 4 else { return false }
    let ph = UInt32(number(s, p, 4))
    guard ph != 0 && ph != .max else { return false }
    f.interruptParent = ph
  } else if isName("interrupts") {
    guard f.take(128), n > 0, n % 4 == 0 else { return false }
    f.interrupts = bytes
  } else if isName("interrupts-extended") {
    guard f.take(256), n > 0, n % 4 == 0 else { return false }
    f.extended = bytes
  }
  return true
}

private func fits(_ r: DeviceRange, cells: UInt64) -> Bool {
  if cells == 2 { return r.valid() }
  return cells == 1 && DeviceRange(base: 0, length: 1 << 32).contains(r)
}
private func physical<S: ByteSource>(_ s: S, _ stack: [Frame]) -> DeviceRange? {
  let leaf = stack.count - 1
  guard leaf > 0, let reg = stack[leaf].reg else { return nil }
  var bus = leaf - 1
  let a = stack[bus].addressCells
  let z = stack[bus].sizeCells
  guard (1...2).contains(a), (1...2).contains(z), reg.length == 4 * (a + z) else { return nil }
  var current = DeviceRange(
    base: number(s, reg.at, 4 * a), length: number(s, reg.at + 4 * a, 4 * z))
  guard fits(current, cells: a) else { return nil }
  while bus > 0 {
    let frame = stack[bus]
    let child = frame.addressCells
    let parent = stack[bus - 1].addressCells
    let size = frame.sizeCells
    guard frame.simple, let ranges = frame.ranges, (1...2).contains(parent),
      (1...2).contains(child), (1...2).contains(size)
    else { return nil }
    let stride = 4 * (child + parent + size)
    guard ranges.length % stride == 0, ranges.length / stride <= 256 else { return nil }
    if ranges.length != 0 {
      var selected: DeviceRange?
      var offset: UInt64 = 0
      while offset < ranges.length {
        let p = ranges.at + offset
        let length = number(s, p + 4 * (child + parent), 4 * size)
        let from = DeviceRange(base: number(s, p, 4 * child), length: length)
        let to = DeviceRange(base: number(s, p + 4 * child, 4 * parent), length: length)
        guard fits(from, cells: child), fits(to, cells: parent) else { return nil }
        if from.overlaps(current) {
          guard selected == nil, from.contains(current) else { return nil }
          selected = DeviceRange(base: to.base + (current.base - from.base), length: current.length)
        }
        offset += stride
      }
      guard let translated = selected else { return nil }
      current = translated
    }
    guard fits(current, cells: parent) else { return nil }
    bus -= 1
  }
  return current
}

/// A transactional registry snapshot for the virtio,mmio binding under
/// root or simple-bus nodes. No MMIO probe is performed while parsing.
/// An absent ranges property is never treated as an identity translation.
public func firmwareVirtioMmio<S: ByteSource>(_ s: S) -> [FirmwareMmio]? {
  guard s.byteCount() <= 16 * 1024 * 1024 else { return nil }
  var cursor = openTree(s)
  guard !cursor.failed else { return nil }
  var stack: [Frame] = []
  var devices: [FirmwareMmio] = []
  while !cursor.ended {
    let item = nextItem(s, c: &cursor)
    if cursor.failed { return nil }
    switch item.token {
    case 1:
      guard stack.count < 64 else { return nil }
      stack.append(
        Frame(
          node: item.nameAt, enabled: stack.last?.enabled ?? true,
          interruptParent: stack.last?.interruptParent))
    case 2:
      guard let frame = stack.last else { return nil }
      if frame.enabled && frame.virtio {
        guard devices.count < 1024, let r = physical(s, stack), r.base % 4 == 0, r.length >= 0x100,
          !devices.contains(where: { $0.registers.overlaps(r) })
        else { return nil }
        devices.append(
          FirmwareMmio(
            node: frame.node, parent: stack[stack.count - 2].node, registers: r,
            interruptParent: frame.interruptParent, interrupts: frame.interrupts,
            interruptsExtended: frame.extended))
      }
      stack.removeLast()
    case 3:
      guard !stack.isEmpty, property(s, item, &stack[stack.count - 1]) else { return nil }
    default: break
    }
  }
  return devices
}
