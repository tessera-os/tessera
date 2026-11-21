import KCore

private enum Part: Int {
  case root, cpus, cpu, intc, soc, rtc, aplic, imsic
}

/// Validate the single-hart QEMU virt board's S-mode RTC route. The board
/// owner pins the MMIO layout; the tree is corroboration, not permission to
/// map arbitrary addresses. The caller also requires a single enabled hart
/// 0 with Ssaia and firmware delegation before any CSR or MMIO access.
public func treeSupportsVirtSupervisorRTC<S: ByteSource>(_ tree: S) -> Bool {
  guard tree.byteCount() <= 16 * 1024 * 1024 else { return false }
  return withUnsafeTemporaryAllocation(of: FdtCursor?.self, capacity: 8) { nodes in
    withUnsafeTemporaryAllocation(of: Part?.self, capacity: 4) { path in
      nodes.initialize(repeating: nil)
      path.initialize(repeating: nil)
      defer { path.deinitialize(); nodes.deinitialize() }
      return supervisorRTC(tree, nodes: nodes, path: path)
    }
  }
}

private func supervisorRTC<S: ByteSource>(_ tree: S, nodes: UnsafeMutableBufferPointer<FdtCursor?>,
  path: UnsafeMutableBufferPointer<Part?>) -> Bool
{
  var c = openTree(tree)
  guard !c.failed else { return false }
  while !c.ended {
    let x = nextItem(tree, c: &c)
    guard !c.failed else { return false }
    guard x.token == 1, c.depth <= 4 else { continue }
    func name(_ key: StaticString) -> Bool { matches(tree, at: x.nameAt, length: x.nameLength, key) }
    let i = Int(c.depth) - 1
    let n: Part?
    if i == 0 { n = .root }
    else {
      switch path[i - 1] {
      case .root: n = name("soc") ? .soc : name("cpus") ? .cpus : nil
      case .cpus: n = name("cpu@0") ? .cpu : nil
      case .cpu: n = name("interrupt-controller") ? .intc : nil
      case .soc:
        if name("rtc@101000") { n = .rtc }
        else if name("interrupt-controller@d000000") { n = .aplic }
        else if name("interrupt-controller@28000000") { n = .imsic }
        else { n = nil }
      default: n = nil
      }
    }
    path[i] = n
    if let n {
      guard nodes[n.rawValue] == nil else { return false }
      nodes[n.rawValue] = c
    }
  }

  // FDT properties precede child nodes. A required property occurs exactly
  // once; even for optional fields a duplicate or invalid value is an error.
  func property(_ part: Part, _ key: StaticString, optional: Bool = false,
    _ valid: (FdtItem) -> Bool) -> Bool
  {
    treeProperty(tree, node: nodes[part.rawValue], key, optional: optional, valid)
  }
  func number(_ part: Part, _ key: StaticString, _ length: UInt64 = 4) -> UInt64? {
    var v: UInt64?
    let ok = property(part, key) { x in
      guard x.valueLength == length else { return false }
      v = big(tree, p: x.valueAt, n: length)
      return true
    }
    return ok ? v : nil
  }
  func flag(_ part: Part, _ key: StaticString) -> Bool {
    property(part, key) { $0.valueLength == 0 }
  }
  func lacks(_ part: Part, _ key: StaticString) -> Bool {
    property(part, key, optional: true) { _ in false }
  }
  func compatible(_ part: Part, _ wanted: StaticString) -> Bool {
    property(part, "compatible") { x in
      let end = x.valueAt + x.valueLength
      var i = x.valueAt, found = false
      while i < end {
        let stop = nul(tree, p: i, limit: end)
        guard i < stop, stop < end else { return false }
        if matches(tree, at: i, length: stop - i, wanted) { found = true }
        i = stop + 1
      }
      return found
    }
  }
  func reg(_ part: Part, _ base: UInt64, _ size: UInt64) -> Bool {
    property(part, "reg") { x in
      x.valueLength == 16 && big(tree, p: x.valueAt, n: 8) == base
        && big(tree, p: x.valueAt + 8, n: 8) == size
    }
  }
  for i in nodes.indices {
    guard let part = Part(rawValue: i), property(part, "status", optional: true, { x in
      matches(tree, at: x.valueAt, length: x.valueLength, "okay", cstring: true)
    }) else { return false }
  }
  guard compatible(.root, "riscv-virtio"), number(.root, "#address-cells") == 2,
    number(.root, "#size-cells") == 2, compatible(.soc, "simple-bus"),
    number(.soc, "#address-cells") == 2, number(.soc, "#size-cells") == 2, flag(.soc, "ranges"),
    number(.cpus, "#address-cells") == 1, number(.cpus, "#size-cells") == 0, number(.cpu, "reg") == 0,
    compatible(.intc, "riscv,cpu-intc"), number(.intc, "#interrupt-cells") == 1, flag(.intc, "interrupt-controller"),
    compatible(.rtc, "google,goldfish-rtc"), reg(.rtc, 0x101000, 0x1000),
    number(.rtc, "interrupts", 8) == 11 << 32 | 4, lacks(.rtc, "interrupts-extended"),
    compatible(.aplic, "riscv,aplic"), flag(.aplic, "interrupt-controller"), number(.aplic, "#interrupt-cells") == 2,
    reg(.aplic, 0xd000000, 0x8000), number(.aplic, "riscv,num-sources") == 96,
    lacks(.aplic, "interrupts-extended"), lacks(.aplic, "interrupt-map"),
    compatible(.imsic, "riscv,imsics"), flag(.imsic, "interrupt-controller"), flag(.imsic, "msi-controller"),
    reg(.imsic, 0x28000000, 0x1000), number(.imsic, "riscv,num-ids") == 255,
    number(.imsic, "#interrupt-cells") == 0, lacks(.imsic, "riscv,guest-index-bits"),
    let cpu = number(.intc, "phandle"), let file = number(.imsic, "phandle"), let domain = number(.aplic, "phandle"),
    number(.rtc, "interrupt-parent") == domain, number(.aplic, "msi-parent") == file,
    number(.imsic, "interrupts-extended", 8) == cpu << 32 | 9,
    cpu != file, file != domain, domain != cpu else { return false }

  // Never resolve a handle to the first of two conflicting controllers.
  var seen: UInt8 = 0
  c = openTree(tree)
  while !c.ended {
    let x = nextItem(tree, c: &c)
    guard !c.failed else { return false }
    guard x.token == 3 else { continue }
    if matches(tree, at: x.nameAt, length: x.nameLength, "linux,phandle") { return false }
    guard matches(tree, at: x.nameAt, length: x.nameLength, "phandle") else { continue }
    guard x.valueLength == 4 else { return false }
    let id = big(tree, p: x.valueAt, n: 4)
    guard id != 0, id != 0xffff_ffff else { return false }
    let bit: UInt8 = id == cpu ? 1 : id == file ? 2 : id == domain ? 4 : 0
    guard seen & bit == 0 else { return false }
    seen |= bit
  }
  return seen == 7
}
