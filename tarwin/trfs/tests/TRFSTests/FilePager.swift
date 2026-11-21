import TarwinMM
import XCTest

@testable import TRFS

private final class MemoryStore: TrfsPageStore {
  var frames: [UInt64: [UInt8]] = [:]
  var file = [UInt8](repeating: 0x44, count: 17)
  var loads = 0, stores = 0, releases = 0
  var writebackWorks = false
  func mayFault(object: UInt64, write: Bool) -> Bool { object == 8 || (!write && object == 9) }
  func acquireFrame(bytes: UInt64) -> UInt64? {
    guard frames[0x4000] == nil else { return nil }
    frames[0x4000] = .init(repeating: 0xee, count: Int(bytes))
    return 0x4000
  }
  func load(object: UInt64, offset: UInt64, valid: UInt64, into frame: UInt64) -> Bool {
    guard offset == 0, valid == file.count, frames[frame] != nil else { return false }
    loads += 1
    frames[frame]!.replaceSubrange(0..<Int(valid), with: file)
    return true
  }
  func clear(frame: UInt64, from: UInt64, to: UInt64) {
    for i in Int(from)..<Int(to) { frames[frame]![i] = 0 }
  }
  func store(object: UInt64, offset: UInt64, valid: UInt64, from frame: UInt64) -> Bool {
    guard writebackWorks else { return false }
    stores += 1
    file = Array(frames[frame]!.prefix(Int(valid)))
    return true
  }
  func releaseFrame(_ frame: UInt64, bytes: UInt64) {
    releases += 1
    frames.removeValue(forKey: frame)
  }
}

final class FilePagerTests: XCTestCase {
  func testVMLeasesShareCacheEnforceWritableExclusionAndRetainFailedWriteback() {
    let store = MemoryStore()
    withUnsafeTemporaryAllocation(of: CachedFilePage.self, capacity: 1) { pages in
      withUnsafeTemporaryAllocation(of: FileLeaseRecord.self, capacity: 2) { leases in
        pages.initialize(repeating: CachedFilePage())
        leases.initialize(repeating: FileLeaseRecord())
        defer {
          pages.deinitialize()
          leases.deinitialize()
        }
        var state = TrfsPagerState(store: store, pages: pages, leases: leases)
        withUnsafeMutablePointer(to: &state) { pointer in
          var a = TrfsFilePager(state: pointer)
          var b = a
          let read = faultFilePage(&a, object: 8, size: 17, offset: 0, pageSize: 4096, write: false)
          let second = faultFilePage(
            &b, object: 8, size: 17, offset: 0, pageSize: 4096, write: false)
          XCTAssertNotEqual(read.token, 0)
          XCTAssertNotEqual(read.token, second.token)
          XCTAssertEqual(read.physical, second.physical)
          XCTAssertEqual(store.loads, 1)
          XCTAssertTrue(store.frames[read.physical]!.dropFirst(17).allSatisfy { $0 == 0 })
          a.unpinFilePage(read.token, dirty: true)
          a.unpinFilePage(read.token, dirty: true)
          XCTAssertEqual(
            faultFilePage(&a, object: 8, size: 17, offset: 0, pageSize: 4096, write: true).token, 0)
          b.unpinFilePage(second.token, dirty: false)
          XCTAssertTrue(a.flush(object: 8))
          let write = faultFilePage(&a, object: 8, size: 17, offset: 0, pageSize: 4096, write: true)
          XCTAssertNotEqual(write.token, 0)
          XCTAssertFalse(b.shutdown())
          store.frames[write.physical]![0] = 0x61
          store.frames[write.physical]![17] = 0xbb
          b.unpinFilePage(write.token, dirty: true)
          XCTAssertEqual(store.frames[write.physical]![17], 0)
          XCTAssertFalse(a.flush(object: 8))
          XCTAssertFalse(a.shutdown())
          XCTAssertEqual(
            faultFilePage(&a, object: 9, size: 17, offset: 0, pageSize: 4096, write: false).token, 0
          )
          XCTAssertEqual(store.releases, 0)
          store.writebackWorks = true
          XCTAssertTrue(a.shutdown())
          XCTAssertEqual(store.file.count, 17)
          XCTAssertEqual(store.file[0], 0x61)
          XCTAssertEqual(store.stores, 1)
          XCTAssertEqual(store.releases, 1)
        }
      }
    }
  }
}
