import Testing

@testable import TarwinHV

private func extent(_ permissions: UInt64 = 3) -> GuestExtent {
  var e = GuestExtent()
  precondition(
    e.map(
      0x4000, 0, 4096, 0x10000, 4096, 4096, permissions, 7,
      { _, _ in 73 }, { _, _, _, _ in true }, { _ in }))
  return e
}

@Test func trappingCannotElevateGuestRightsOrReleaseUntrackedWrites() {
  for rights: UInt64 in [1, 5] {
    var e = extent(rights)
    let elevated = e.trapWrites(
      true,
      detach: { _, _ in
        Issue.record("unexpected detach")
        return true
      },
      invalidate: { _, _ in true }, install: { _, _, _, _ in true })
    #expect(!elevated)
  }
  var e = extent()
  let log = DirtyPages(first: 3, pages: 2)
  var bits: UInt64 = 0
  var installs = [UInt64]()
  func install(_ start: UInt64, _ size: UInt64, _ pin: UInt64, _ permissions: UInt64) -> Bool {
    installs.append(permissions)
    return start == 0x4000 && size == 4096 && pin == 73
  }
  func retry(_ ipa: UInt64) -> Bool {
    log.retryWrite(
      ipa: ipa, pageSize: 4096, extent: &e, load: { _ in bits },
      store: { _, v in bits = v }, detach: { _, _ in true }, invalidate: { _, _ in true },
      install: install)
  }
  #expect(!retry(0x4000))
  let armed = e.trapWrites(
    true, detach: { _, _ in true }, invalidate: { _, _ in true }, install: install)
  #expect(armed)
  #expect(!retry(0x3fff) && !retry(0x5000))
  #expect(retry(0x4fff))
  #expect(bits == 2 && installs == [1, 3] && !e.writeTrapped && e.pin == 73)
  #expect(!retry(0x4000))
}

@Test func writeProtectionFailureQuarantinesPinUntilShootdown() {
  for failure in 1...4 {
    var e = extent()
    var operations = 0
    var release: UInt64 = 0
    var detaches = 0
    func step() -> Bool {
      operations += 1
      return operations != failure
    }
    let armed = e.trapWrites(
      true, detach: { _, _ in step() }, invalidate: { _, _ in step() },
      install: { _, _, _, _ in step() })
    #expect(!armed)
    #expect(operations == failure && e.pin == 73 && !e.writeTrapped)
    #expect(e.phase == (failure == 1 ? .mapped : failure == 4 ? .quarantinedMapped : .detached))
    let first = e.retire(
      { _, _ in
        detaches += 1
        return true
      }, { _, _ in false }, { release = $0 })
    #expect(!first)
    #expect(release == 0 && e.pin == 73 && e.phase == .detached)
    let second = e.retire(
      { _, _ in
        detaches += 1
        return false
      }, { _, _ in true }, { release = $0 })
    #expect(second)
    #expect(
      release == 73 && e.phase == .empty && detaches == (failure == 1 || failure == 4 ? 1 : 0))
  }
}
