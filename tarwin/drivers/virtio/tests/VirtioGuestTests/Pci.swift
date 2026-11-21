import XCTest

@testable import VirtioGuest

final class PciTests: XCTestCase {
  func pciConfig() -> [UInt8] {
    var b: [UInt8] = []
    for _ in 0..<256 { b.append(0) }
    b[0] = 0xf4
    b[1] = 0x1a
    b[2] = 0x42
    b[3] = 0x10
    b[6] = 16
    b[0x34] = 0x40
    for i in 0..<3 {
      let at = 64 + 20 * i
      b[at] = 9
      b[at + 1] = i == 2 ? 0 : UInt8(at + 20)
      b[at + 2] = 20
      b[at + 3] = UInt8(i + 1)
      b[at + 4] = UInt8(i)
      b[at + 12] = 64
    }
    b[100] = 4
    return b
  }

  func testModernPciRequiresBoundedCapabilitiesAndAcyclicList() {
    var b = pciConfig()
    let bars: [UInt64] = [64, 64, 64, 0, 0, 0]
    switch discoverVirtioPci(b, bars, 2) {
    case .invalid: XCTAssertTrue(false)
    case .found(let w): XCTAssertTrue(w.multiplier == 4 && w.config.length == 0 && w.isr.bar == 2)
    }
    b[105] = 64
    XCTAssertTrue(discoverVirtioPci(b, bars, 2) == PciDiscovery.invalid)
    b[105] = 0
    b[96] = 65
    XCTAssertTrue(discoverVirtioPci(b, bars, 2) == PciDiscovery.invalid)
  }

  func testNotifyAddressMustFitBeforeTheQueueIsEnabled() {
    let w = PciWindow(bar: 0, offset: 0, length: 64)
    let t = TransportWindows(common: w, notify: w, isr: w, config: w, multiplier: 4)
    var offset: UInt32 = 16
    var enabled: UInt32 = 0
    let read: (UInt32, UInt32) -> UInt32 = { reg, width in
      if reg == 20 { return 11 }
      if reg == 18 { return 1 }
      if reg == 24 { return 4 }
      if reg == 30 { return offset }
      if reg == 28 { return enabled }
      return 0
    }
    let write: (UInt32, UInt32, UInt32) -> Void = { reg, width, v in if reg == 28 { enabled = v } }
    let memory = QueueMemory(count: 4, descriptors: 4096, available: 8192, used: 12288)
    XCTAssertTrue(setupPciQueue(0, memory, t, read, write) == QueueNotify.invalid)
    XCTAssertTrue(enabled == 0)
    offset = 15
    XCTAssertTrue(setupPciQueue(0, memory, t, read, write) == QueueNotify.offset(60))
    XCTAssertTrue(enabled == 1)
  }
}
