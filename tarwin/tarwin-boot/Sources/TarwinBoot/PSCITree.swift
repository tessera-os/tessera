import KCore

/// A firmware tree for an EL2 PSCI caller must describe the SMC conduit.
/// Only the standardized 0.2+ function IDs are usable; PSCI_VERSION must
/// still meet the architecture floor before starting a CPU. Ignore nested
/// nodes, parse the entire blob before accepting anything.
public func treeSupportsEL2PSCI<S: ByteSource>(_ tree: S) -> Bool {
  var c = openTree(tree)
  var node = false, found = false, compatible = false, smc = false, status = false
  while !c.ended {
    let x = nextItem(tree, c: &c)
    guard !c.failed else { return false }
    func name(_ key: StaticString) -> Bool {
      matches(tree, at: x.nameAt, length: x.nameLength, key)
    }
    if x.token == 1 && c.depth == 2 {
      node = name("psci")
      if node { guard !found else { return false }; found = true }
    }
    if x.token == 2 && c.depth == 1 { node = false }
    guard node, c.depth == 2, x.token == 3 else { continue }
    if name("compatible") {
      guard !compatible else { return false }
      let limit = x.valueAt + x.valueLength
      var pos = x.valueAt
      while pos < limit {
        let end = nul(tree, p: pos, limit: limit)
        guard pos < end, end < limit else { return false }
        if matches(tree, at: pos, length: end - pos, "arm,psci-1.0")
          || matches(tree, at: pos, length: end - pos, "arm,psci-0.2") { compatible = true }
        pos = end + 1
      }
      guard compatible else { return false }
    } else if name("method") {
      guard !smc, matches(tree, at: x.valueAt, length: x.valueLength, "smc", cstring: true)
      else { return false }
      smc = true
    } else if name("status") {
      guard !status, matches(tree, at: x.valueAt, length: x.valueLength, "okay", cstring: true)
      else { return false }
      status = true
    }
  }
  return found && smc && compatible
}
