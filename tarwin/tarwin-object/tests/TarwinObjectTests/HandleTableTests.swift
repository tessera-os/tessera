import Dispatch
import Synchronization
import XCTest

@testable import TarwinObject

private func object(_ source: borrowing KoidSource, kind: UInt32, rights: UInt64)
  -> UnsafeMutablePointer<ObjectHeader>
{
  let p = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  p.initialize(to: ObjectHeader(source: source, ownerJob: 1, kind: kind, maximumRights: rights)!)
  return p
}

private func installed(_ result: HandleMutation) -> UInt64 {
  if case .installed(let name) = result { return name }
  XCTFail("expected installed handle")
  return 0
}

final class HandleTableTests: XCTestCase {
  func testFullTableReplacementAndReferenceLifetime() {
    let storage = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 2)
    var table = HandleTable(storage: storage, salt: 0xd3)!
    let port = object(KoidSource(), kind: TarwinKind.port, rights: 7)
    defer {
      port.deinitialize(count: 1)
      port.deallocate()
      storage.deinitialize()
      storage.deallocate()
    }
    let view = table.reader
    let name = installed(table.install(port, rights: 7))
    XCTAssertEqual(name, 0xd300_0000_0010_0000)
    let duplicate = installed(table.derive(name, rights: .max, duplicate: true))
    if case .limit = table.derive(name, rights: 7, duplicate: true) {
    } else {
      XCTFail("over quota")
    }
    if case .accessDenied = table.derive(name, rights: 8, duplicate: false) {
    } else {
      XCTFail("escalated")
    }
    if case .wrongType = view.pinWithinEpoch(name, kind: TarwinKind.thread, need: 1) {
    } else {
      XCTFail("wrong type")
    }
    if case .found(let pin) = view.pinWithinEpoch(name, kind: TarwinKind.port, need: 7) {
      XCTAssertEqual(port.pointee.release(), .stillLive)
      let narrow = installed(table.derive(name, rights: 4, duplicate: false))
      XCTAssertNotEqual(name, narrow)
      if case .invalidHandle = view.pinWithinEpoch(name, kind: 0, need: 0) {
      } else {
        XCTFail("stale")
      }
      if case .accessDenied = view.pinWithinEpoch(narrow, kind: 0, need: 2) {
      } else {
        XCTFail("rights")
      }
      if case .accessDenied = table.derive(narrow, rights: .max, duplicate: true) {
      } else {
        XCTFail("duplicate right")
      }
      XCTAssertTrue(table.close(duplicate) { _ in XCTFail("premature retirement") })
      table.drain { _ in XCTFail("pin must outlive table") }
      XCTAssertEqual(table.freeCount, 2)
      var retired = false
      pin.drop { p in
        XCTAssertEqual(p, UnsafePointer(port))
        retired = true
      }
      XCTAssertTrue(retired)
      XCTAssertFalse(port.pointee.retainIfLive())
    } else {
      XCTFail("pin missing")
    }
  }

  func testTransfersAreValidatedBeforeAnythingMoves() {
    let s = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
    let d = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
    var src = HandleTable(storage: s, salt: 8)!
    var dst = HandleTable(storage: d, salt: 9)!
    let ids = KoidSource()
    let port = object(ids, kind: TarwinKind.port, rights: 7)
    let presence = object(ids, kind: TarwinKind.presence, rights: 4)
    defer {
      src.drain { _ in XCTFail("caller still owns object") }
      dst.drain { _ in XCTFail("caller still owns object") }
      XCTAssertEqual(port.pointee.release(), .destroy)
      XCTAssertEqual(presence.pointee.release(), .destroy)
      port.deinitialize(count: 1)
      port.deallocate()
      presence.deinitialize(count: 1)
      presence.deallocate()
      s.deinitialize()
      s.deallocate()
      d.deinitialize()
      d.deallocate()
    }
    let a = installed(src.install(port, rights: 6))
    let b = installed(src.install(port, rights: 2))
    let p = installed(src.install(presence, rights: 4))
    for (batch, expected) in [
      ([a, p], HandleCheck.accessDenied), ([a, a], .invalidHandle), ([a, 0], .invalidHandle),
    ] {
      batch.withUnsafeBufferPointer { names in
        XCTAssertEqual(src.moveForChannel(names) { _ in XCTFail("partial move") }, expected)
      }
      XCTAssertEqual(src.freeCount, 1)
    }
    var names = [UInt64]()
    var closed = 0
    [a, b].withUnsafeBufferPointer { batch in
      XCTAssertEqual(
        src.moveForChannel(batch) { (g: consuming ObjectGrant) in
          switch dst.installMoved(g) {
          case .installed(let name): names.append(name)
          case .limit(let held):
            held.drop { _ in XCTFail("caller still owns object") }
            closed += 1
          }
        }, .allowed)
    }
    XCTAssertEqual(names.count, 1)
    XCTAssertEqual(closed, 1)
    XCTAssertEqual(src.freeCount, 3)
    XCTAssertFalse(src.close(a) { _ in XCTFail() })
    guard case .found(let pin) = dst.reader.pinWithinEpoch(names[0], kind: TarwinKind.port, need: 6)
    else { return XCTFail("rights lost") }
    XCTAssertEqual(pin.rights, 6)
    pin.drop { _ in XCTFail("table still owns object") }
  }
}
