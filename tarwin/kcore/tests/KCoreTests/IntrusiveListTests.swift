import KCore
import Testing

private struct Record: IntrusiveNode {
  var listLink = IntrusiveLink()
  var payload: Int
}

@Test func listRejectsInvalidOrLinkedIndicesAndPreservesPayloads() {
  var nodes = (0..<5).map { Record(payload: $0 * 17) }
  nodes.withUnsafeMutableBufferPointer { storage in
    guard var list = IntrusiveList(nodes: storage) else { Issue.record(); return }
    for i in [-1, storage.count, Int.max] {
      let inserted = list.prepend(i)
      #expect(!inserted)
    }
    for i in [2, 4, 0] {
      let inserted = list.prepend(i)
      #expect(inserted)
    }
    for i in [0, 4, 2] {
      let duplicate = list.prepend(i)
      #expect(!duplicate)
    }
    let refused = IntrusiveList(nodes: storage) == nil
    #expect(refused)
    var popped = list.popFirst()
    #expect(popped == 0)
    let inserted = list.prepend(0)
    #expect(inserted)
    for i in [0, 4, 2] {
      #expect(list.first == i)
      popped = list.popFirst()
      #expect(popped == i)
    }
    popped = list.popFirst()
    #expect(popped == nil && list.first == nil)
    for i in storage.indices { #expect(storage[i].payload == i * 17) }
    let reusable = IntrusiveList(nodes: storage) != nil
    #expect(reusable)
  }
}
