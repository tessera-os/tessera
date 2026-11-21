import KCore

/// Corroborates the two kernel-only counter-clocked SBSA watchdog frames
/// in the pinned virt-11.1 layout. Only the trusted board profile authorizes
/// mappings. WDAT's millisecond counter requires a different backend.
public func treeSupportsVirtWatchdog<S: ByteSource>(_ tree: S) -> Bool {
  guard tree.byteCount() <= 16 * 1024 * 1024 else { return false }
  var root: FdtCursor?, node: FdtCursor?
  var c = openTree(tree)
  while !c.ended {
    let x = nextItem(tree, c: &c)
    guard !c.failed else { return false }
    if x.token == 1, c.depth == 1 { root = c }
    if x.token == 1, c.depth == 2,
      matches(tree, at: x.nameAt, length: x.nameLength, "watchdog@f001000") {
      guard node == nil else { return false }
      node = c
    }
  }
  func string(_ n: FdtCursor?, _ key: StaticString, _ value: StaticString,
    optional: Bool = false) -> Bool {
    treeProperty(tree, node: n, key, optional: optional) { x in
      matches(tree, at: x.valueAt, length: x.valueLength, value, cstring: true)
    }
  }
  func twoCells(_ key: StaticString) -> Bool {
    treeProperty(tree, node: root, key) { x in x.valueLength == 4 && big(tree, p: x.valueAt, n: 4) == 2 }
  }
  return string(root, "compatible", "linux,dummy-virt") && string(root, "status", "okay", optional: true)
    && twoCells("#address-cells") && twoCells("#size-cells")
    && string(node, "status", "okay", optional: true) && string(node, "compatible", "arm,sbsa-gwdt")
    && treeProperty(tree, node: node, "reg") { x in
      x.valueLength == 32 && big(tree, p: x.valueAt, n: 8) == 0x0f00_1000
        && big(tree, p: x.valueAt + 8, n: 8) == 0x1000
        && big(tree, p: x.valueAt + 16, n: 8) == 0x0f00_0000
        && big(tree, p: x.valueAt + 24, n: 8) == 0x1000
    }
}
