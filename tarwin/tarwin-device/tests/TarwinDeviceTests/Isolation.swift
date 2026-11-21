import XCTest

@testable import TarwinDevice

final class IsolationTests: XCTestCase {
  func testRandomAllocationExcludesRetiringPages() {
    let aperture = DeviceRange(base: 0x8000, length: 0x4000)
    let held = [DeviceRange(base: 0x9000, length: 4096)]
    XCTAssertTrue(chooseDmaAddress(aperture, 4096, 4096, 1, held) == DmaAddress.unavailable)
    switch chooseDmaAddress(aperture, 4096, 4096, 3, held) {
    case .selected(let address): XCTAssertTrue(address == 0xb000)
    case .unavailable: XCTAssertTrue(false)
    }
    XCTAssertTrue(chooseDmaAddress(aperture, 4095, 4096, 0, held) == DmaAddress.unavailable)
  }

  func testRetirementWaitsForBothCaches() {
    var r = DmaRetirement(domain: 9, pin: 7, base: 4096, bytes: 4096, phase: .mapped)
    var order: Int = 0
    let dropPte: (UInt64, UInt64, UInt64) -> Bool = { d, a, n in
      order = order * 10 + 1
      return d == 9 && a == 4096 && n == 4096
    }
    let flush: (UInt64, UInt64, UInt64) -> Bool = { d, a, n in
      order = order * 10 + 2
      return true
    }
    let timeout: (UInt64, UInt64, UInt64) -> Bool = { d, a, n in return false }
    let unpin: (UInt64) -> Void = { pin in order = order * 10 + Int(pin) }
    XCTAssertTrue(!r.retire(dropPte, flush, timeout, unpin))
    XCTAssertTrue(order == 12 && r.phase == DmaRetirePhase.ioFlushed)
    XCTAssertTrue(r.retire(dropPte, flush, flush, unpin))
    XCTAssertTrue(r.retire(dropPte, flush, flush, unpin))
    XCTAssertTrue(order == Int(1227))
  }

  func testFullPortAndOldSlotCannotUnmask() {
    var irq = DriverInterrupt(slotEpoch: 3, state: .armed)
    var calls: Int = 0
    let bump: () -> Void = { calls = calls + 1 }
    XCTAssertTrue(!irq.deliver(bump, { return false }))
    XCTAssertTrue(irq.deliver(bump, { return true }))
    XCTAssertTrue(!irq.complete(2, bump))
    irq.revoke(bump)
    XCTAssertTrue(!irq.complete(3, bump))
    XCTAssertTrue(calls == 2)
  }

  func testFiltersApplyToWholeConfigWriteAndApiWindow() {
    XCTAssertTrue(!pciConfigWriteAllowed(0x10, 4, 0xffff_ffff, 0xffff_ffff, 0, true))
    XCTAssertTrue(!pciConfigWriteAllowed(0x102, 2, 1, 1, 0, true))
    XCTAssertTrue(!pciConfigWriteAllowed(0x41, 2, 1, 1, 0, true))
    XCTAssertTrue(!pciConfigWriteAllowed(0x40, 1, 3, 1, 0, true))
    XCTAssertTrue(pciConfigWriteAllowed(0x40, 1, 3, 1, 2, true))
    XCTAssertTrue(inDriverApiWindow(27, 10, 26, 11))
    XCTAssertTrue(!inDriverApiWindow(27, 11, 26, 11))
    XCTAssertTrue(!inDriverApiWindow(26, 11, 26, 10))
    XCTAssertTrue(!inDriverApiWindow(26, 11, 26, 12))
  }
}
