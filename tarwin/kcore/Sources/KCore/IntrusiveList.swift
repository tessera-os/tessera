/// A link embedded in a caller-owned record. -2 is detached; -1 ends a list.
public struct IntrusiveLink {
  fileprivate var next = -2
  public init() {}
}

public protocol IntrusiveNode {
  var listLink: IntrusiveLink { get set }
}

/// A singly linked list over a fixed pool. Indices are relative to this
/// pool, not stable handles. Push and pop never allocate or traverse.
public struct IntrusiveList<Node: IntrusiveNode>: ~Copyable {
  private let nodes: UnsafeMutableBufferPointer<Node>
  private var head = -1
  public var first: Int? { head == -1 ? nil : head }

  /// Pin and exclusively serialize the nodes for the list's lifetime.
  /// Only this list may change the links; drain it before reusing them.
  @unsafe public init?(nodes: UnsafeMutableBufferPointer<Node>) {
    for node in nodes where node.listLink.next != -2 { return nil }
    self.nodes = nodes
  }

  public mutating func prepend(_ index: Int) -> Bool {
    guard nodes.indices.contains(index), nodes[index].listLink.next == -2 else { return false }
    nodes[index].listLink.next = head
    head = index
    return true
  }

  public mutating func popFirst() -> Int? {
    guard let index = first else { return nil }
    head = nodes[index].listLink.next
    nodes[index].listLink = IntrusiveLink()
    return index
  }
}
