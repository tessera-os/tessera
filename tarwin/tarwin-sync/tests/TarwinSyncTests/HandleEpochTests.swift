import Dispatch
import Synchronization
import TarwinObject
import TarwinSync
import TarwinSyncObjects
import XCTest

private final class Readers: @unchecked Sendable {
  let view: HandleReadView
  let epoch = EpochDomain()
  let current = Atomic<UInt64>(0)
  let reads = Atomic<UInt64>(0)
  let stop = Atomic<Bool>(false)
  init(_ view: HandleReadView) { self.view = view }
}

final class HandleEpochTests: XCTestCase {
  func testConcurrentRepublishCannotMixGenerationsAndRights() {
    let storage = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
    var table = HandleTable(storage: storage, salt: 29)!
    let ids = KoidSource()
    let ports = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 2)
    ports.initialize(
      to: ObjectHeader(source: ids, ownerJob: 1, kind: TarwinKind.port, maximumRights: 7)!)
    (ports + 1).initialize(
      to: ObjectHeader(source: ids, ownerJob: 1, kind: TarwinKind.event, maximumRights: 7)!)
    let readers = Readers(table.reader)
    let launched = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    for _ in 0..<4 {
      DispatchQueue.global().async(group: group) {
        launched.signal()
        while !readers.stop.load(ordering: .acquiring) {
          let name = readers.current.load(ordering: .acquiring)
          if case .found(let g) = readers.view.pin(name, kind: 0, need: 0, in: readers.epoch) {
            let even = name & (1 << 20) == 0
            XCTAssertEqual(g.header.pointee.kind, even ? TarwinKind.event : TarwinKind.port)
            XCTAssertEqual(g.rights, even ? 2 : 4)
            g.drop { _ in XCTFail("boot reference still live") }
            readers.reads.wrappingAdd(1, ordering: .relaxed)
          }
        }
      }
    }
    for _ in 0..<4 { launched.wait() }
    for i in 0..<8192 {
      let bit = i & 1
      guard case .installed(let name) = table.install(ports + bit, rights: bit == 0 ? 4 : 2) else {
        XCTFail("install failed")
        break
      }
      readers.current.store(name, ordering: .releasing)
      if i == 0 {
        let timeout = DispatchTime.now() + .seconds(5)
        while readers.reads.load(ordering: .relaxed) == 0 && DispatchTime.now() < timeout {}
      }
      XCTAssertTrue(table.close(name) { _ in XCTFail("boot reference still live") })
    }
    readers.stop.store(true, ordering: .releasing)
    group.wait()
    XCTAssertGreaterThan(readers.reads.load(ordering: .relaxed), 0)
    let ticket = readers.epoch.beginGracePeriod()!
    XCTAssertTrue(readers.epoch.finishGracePeriod(ticket))
    for i in 0..<2 { XCTAssertEqual((ports + i).pointee.release(), .destroy) }
    ports.deinitialize(count: 2)
    ports.deallocate()
    storage.deinitialize()
    storage.deallocate()
  }
}
