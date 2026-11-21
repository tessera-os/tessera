import Testing

@testable import TarwinProbe

@Test func ringClearsStorageAndPublishesOnlyWholeRecords() {
  var backing = [UInt8](repeating: 0xee, count: 6)
  backing.withUnsafeMutableBytes { mem in
    let shape = ProbeMapShape(kind: .ring, capacity: 3, elementSize: 2)
    guard var ring = ProbeRingMap(shape: shape, byteQuota: 6, slots: mem) else {
      Issue.record("init")
      return
    }
    #expect(mem.allSatisfy { $0 == 0 })
    var publications = [UInt64]()
    for i in 0..<3 {
      let emitted = ring.emit(hook: .audit, bytes: 2, consumed: 0, read: { UInt8(i * 2 + $0) }) {
        head in
        publications.append(head)
        #expect(mem[i * 2 + 1] == UInt8(i * 2 + 1))
      }
      #expect(emitted)
    }
    var visited = false
    for (hook, n, tail): (ProbeHook, Int, UInt64) in [
      (.audit, 2, 0), (.tracepoint, 2, 4), (.packet, 2, 1), (.audit, 1, 1),
    ] {
      let emitted = ring.emit(
        hook: hook, bytes: n, consumed: tail,
        read: { _ in
          visited = true
          return 0
        }
      ) { _ in visited = true }
      #expect(!emitted)
    }
    #expect(!visited && ring.dropped == 2 && publications == [1, 2, 3])
    let emitted = ring.emit(hook: .entry, bytes: 2, consumed: 1, read: { _ in 9 }) {
      publications.append($0)
    }
    #expect(emitted && Array(mem) == [9, 9, 2, 3, 4, 5] && publications.last == 4)
  }
}

@Test func ringRejectsWrongStorageOrShapeBeforeClearing() {
  var backing = [UInt8](repeating: 42, count: 5)
  backing.withUnsafeMutableBytes { mem in
    for shape in [
      ProbeMapShape(kind: .arrayMap, capacity: 1, elementSize: 5),
      .init(kind: .ring, capacity: 3, elementSize: 2),
      .init(kind: .ring, capacity: 5, elementSize: 2),
      .init(kind: .ring, capacity: 0, elementSize: 5),
    ] {
      if ProbeRingMap(shape: shape, byteQuota: 6, slots: mem) != nil {
        Issue.record("invalid shape")
      }
    }
    #expect(mem.allSatisfy { $0 == 42 })
  }
}
