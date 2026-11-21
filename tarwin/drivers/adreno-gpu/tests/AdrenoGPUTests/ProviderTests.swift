import TarwinDevice
import XCTest

@testable import AdrenoGPU

/// Every test here drives the fake device model in FakeDevice.swift. They
/// check the driver's own logic: discovery, admission, ring encoding, DMA
/// retirement order, quarantine and counters. None is evidence about real
/// Adreno hardware, a native requester or a hosted GPU.
final class AdrenoProviderTests: XCTestCase {

  private func open(_ platform: FakeAdreno, _ profile: AdrenoProfile = testProfile())
    throws -> AdrenoGPUProvider
  {
    guard let candidate = AdrenoDiscovery.match(s23PlusNode()) else {
      throw XCTSkip("node does not match")
    }
    return try AdrenoGPUProvider(candidate: candidate, profile: profile, platform: platform)
  }

  func testMatchingDeviceIsStillUnavailableWithoutATrustedProfile() {
    let platform = FakeAdreno()
    XCTAssertNotNil(AdrenoDiscovery.match(s23PlusNode()))
    guard case .unavailable(let refusal) = AdrenoGPUOpener.open(s23PlusNode(), platform: platform)
    else { return XCTFail("a matching device must not be opened") }
    XCTAssertEqual(refusal, .notAdmitted)
    // Discovery alone touched no register, no memory and no interrupt.
    XCTAssertTrue(platform.registers.isEmpty)
    XCTAssertTrue(platform.memory.isEmpty)
    XCTAssertTrue(platform.pins.isEmpty)
  }

  func testOtherDevicesDoNotMatch() {
    XCTAssertNil(AdrenoDiscovery.match(s23PlusNode(identity: 0x4305_0a02)))
    XCTAssertNil(AdrenoDiscovery.match(s23PlusNode(bytes: 4096)))
    XCTAssertNil(AdrenoDiscovery.match(s23PlusNode(interrupts: 0)))
    guard case .unavailable(.notAdreno740) = AdrenoGPUOpener.open(
      s23PlusNode(identity: 0), platform: FakeAdreno())
    else { return XCTFail("unexpected match") }
  }

  func testRingIsProgrammedAndInterruptsUnmaskedOnOpen() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let base = UInt64(platform.read32(AdrenoRegister.CP_RB_BASE))
      | UInt64(platform.read32(AdrenoRegister.CP_RB_BASE_HI)) << 32
    XCTAssertTrue(provider.facts.gpuAddresses.contains(DeviceRange(base: base, length: 16384)))
    XCTAssertEqual(base % 4096, 0)
    XCTAssertEqual(platform.read32(AdrenoRegister.CP_RB_CNTL), AdrenoPM4.ringControl(bytes: 16384))
    XCTAssertEqual(platform.read32(AdrenoRegister.RBBM_INT_0_MASK), AdrenoInterrupt.enabled)
    XCTAssertEqual(provider.facts.chipID, AdrenoDiscovery.adreno740)
  }

  func testJobsRunInOrderAndCompleteTheirTimeline() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    var ran: [UInt64] = []
    platform.execute = { address, _ in ran.append(address) }
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    let first = try provider.submit(job(commands, data, dwords: 8))
    let second = try provider.submit(job(commands, data, dwords: 12))
    XCTAssertEqual([first, second], [1, 2])
    XCTAssertEqual(platform.executed.map(\.dwords), [8, 12])
    XCTAssertEqual(ran, [commands.gpuAddress, commands.gpuAddress])
    XCTAssertTrue(try provider.waitTimeline(reaching: second, timeoutNanoseconds: 0))
    XCTAssertTrue(try provider.waitTimeline(reaching: first, timeoutNanoseconds: 0))
    XCTAssertThrowsError(try provider.waitTimeline(reaching: 3, timeoutNanoseconds: 0)) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .invalidArgument)
    }
  }

  func testGpuWritesAreVisibleThroughTheClientMapping() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    platform.execute = { [weak platform] _, count in
      platform?.host(data.gpuAddress)?.storeBytes(of: count.littleEndian, as: UInt32.self)
    }
    let value = try provider.submit(job(commands, data, dwords: 42))
    XCTAssertTrue(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 0))
    XCTAssertEqual(UInt32(littleEndian: data.cpuAddress.load(as: UInt32.self)), 42)
  }

  func testTimeoutIsNotRetirement() throws {
    let platform = FakeAdreno()
    platform.runOnDoorbell = false
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    let value = try provider.submit(job(commands, data, dwords: 4))
    XCTAssertFalse(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 1000))
    // The job never retired, so nothing may be freed or refunded.
    try provider.closeBuffer(data.handle)
    XCTAssertTrue(platform.closed.isEmpty)
    XCTAssertTrue(platform.refunded.isEmpty)
    XCTAssertEqual(platform.pins.count, 4)
  }

  func testClosedBuffersKeepTheirPinUntilTheirJobsRetire() throws {
    let platform = FakeAdreno()
    platform.runOnDoorbell = false
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    let value = try provider.submit(job(commands, data, dwords: 4))
    try provider.closeBuffer(data.handle)
    XCTAssertNotNil(platform.mappings[data.gpuAddress])
    platform.runOnDoorbell = true
    platform.write32(AdrenoRegister.CP_RB_WPTR, platform.read32(AdrenoRegister.CP_RB_WPTR))
    XCTAssertTrue(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 0))
    XCTAssertNil(platform.mappings[data.gpuAddress])
    XCTAssertTrue(platform.closed.contains(where: { platform.memory[$0]?.bytes == 4096 }))
    XCTAssertNotNil(platform.mappings[commands.gpuAddress])
  }

  func testAFailedDrainKeepsTheAddressAndChargeAndRetriesLater() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    let value = try provider.submit(job(commands, data, dwords: 4))
    XCTAssertTrue(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 0))
    platform.drainFails = true
    try provider.closeBuffer(data.handle)
    XCTAssertTrue(platform.refunded.isEmpty)
    XCTAssertTrue(platform.closed.isEmpty)
    XCTAssertEqual(platform.pins.count, 4, "a failed drain must not release the pin")
    // The same address stays reserved: a new buffer cannot take it.
    let other = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    XCTAssertNotEqual(other.gpuAddress, data.gpuAddress)
    platform.drainFails = false
    try provider.closeBuffer(other.handle)
    // The retry finishes the earlier retirement too, then refunds both.
    XCTAssertEqual(platform.pins.count, 3)
    XCTAssertEqual(platform.refunded.count, 2)
  }

  func testInvalidJobsAreRefusedBeforeTheRing() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    func refused(_ job: AdrenoGPUJob, _ status: AdrenoGPUStatus) {
      XCTAssertThrowsError(try provider.submit(job)) {
        XCTAssertEqual($0 as? AdrenoGPUStatus, status)
      }
      XCTAssertTrue(platform.executed.isEmpty)
    }
    refused(AdrenoGPUJob(commands: [], buffers: []), .invalidArgument)
    // A command buffer that is not listed with read access.
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: commands.handle, byteOffset: 0, dwordCount: 4)],
        buffers: [.init(handle: commands.handle, usage: .write)]), .invalidArgument)
    // Writing a GPU-read-only buffer.
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: commands.handle, byteOffset: 0, dwordCount: 4)],
        buffers: [
          .init(handle: commands.handle, usage: [.read, .write])
        ]), .invalidArgument)
    // Past the end of the buffer, and an unaligned offset.
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: commands.handle, byteOffset: 0, dwordCount: 4097)],
        buffers: [.init(handle: commands.handle, usage: .read)]), .invalidArgument)
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: commands.handle, byteOffset: 2, dwordCount: 4)],
        buffers: [.init(handle: commands.handle, usage: .read)]), .invalidArgument)
    // A handle that was never issued, and one listed twice.
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: 999, byteOffset: 0, dwordCount: 4)],
        buffers: [.init(handle: 999, usage: .read)]), .unknownHandle)
    refused(
      AdrenoGPUJob(
        commands: [.init(handle: commands.handle, byteOffset: 0, dwordCount: 4)],
        buffers: [
          .init(handle: commands.handle, usage: .read), .init(handle: data.handle, usage: .write),
          .init(handle: data.handle, usage: .read),
        ]), .invalidArgument)
  }

  func testUsageBitsReachTheDomainUnwidened() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let readOnly = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: true)
    XCTAssertEqual(platform.mappings[readOnly.gpuAddress]?.span.access, .deviceRead)
    let readWrite = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    XCTAssertEqual(platform.mappings[readWrite.gpuAddress]?.span.access, .both)
  }

  func testAStuckDoorbellQuarantinesTheJobsBuffers() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    platform.doorbellSticks = true
    XCTAssertThrowsError(try provider.submit(job(commands, data, dwords: 4))) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .deviceLost)
    }
    // Indeterminate: the pins, addresses and charges stay, closing frees nothing.
    try provider.closeBuffer(data.handle)
    try provider.closeBuffer(commands.handle)
    XCTAssertEqual(platform.pins.count, 4)
    XCTAssertTrue(platform.refunded.isEmpty)
    XCTAssertTrue(platform.closed.isEmpty)
    XCTAssertThrowsError(try provider.submit(job(commands, data, dwords: 4)))
  }

  func testFatalInterruptsAndDisconnectsLoseTheDeviceWithoutRefunds() throws {
    for failure in [0, 1] {
      let platform = FakeAdreno()
      platform.runOnDoorbell = false
      let provider = try open(platform)
      let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
      let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
      let value = try provider.submit(job(commands, data, dwords: 4))
      if failure == 0 {
        platform.fatalInterrupt = AdrenoInterrupt.RBBM_HANG_DETECT
      } else {
        platform.irqResult = .disconnected
      }
      XCTAssertThrowsError(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 1)) {
        XCTAssertEqual($0 as? AdrenoGPUStatus, .deviceLost)
      }
      try provider.closeBuffer(data.handle)
      XCTAssertTrue(platform.refunded.isEmpty)
      XCTAssertEqual(platform.pins.count, 4)
      XCTAssertThrowsError(try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false))
    }
  }

  func testCancelledWaitsDoNotCertifyRetirement() throws {
    let platform = FakeAdreno()
    platform.runOnDoorbell = false
    platform.irqResult = .cancelled
    let provider = try open(platform)
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    let value = try provider.submit(job(commands, data, dwords: 4))
    XCTAssertThrowsError(try provider.waitTimeline(reaching: value, timeoutNanoseconds: 1)) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .cancelled)
    }
    try provider.closeBuffer(data.handle)
    XCTAssertTrue(platform.refunded.isEmpty)
  }

  func testCounterIsReadWhenTheProfileHasOneAndRefusedOtherwise() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    platform.registers[AdrenoRegister.CP_ALWAYS_ON_COUNTER] = 0x1000
    platform.registers[AdrenoRegister.CP_ALWAYS_ON_COUNTER_HI] = 7
    XCTAssertEqual(try provider.readCounter(), 7 << 32 | 0x1000)
    let without = try open(FakeAdreno(), testProfile(counterHz: nil))
    XCTAssertNil(without.facts.counterHz)
    XCTAssertThrowsError(try without.readCounter()) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .unsupported)
    }
  }

  func testTheRingWrapsWithoutLosingAJob() throws {
    let platform = FakeAdreno()
    let provider = try open(platform, testProfile(ringBytes: 4096))
    let commands = try provider.createBuffer(length: 256, cache: .writeCombined, gpuReadOnly: true)
    let data = try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)
    var last: UInt64 = 0
    for index in 1...200 {
      last = try provider.submit(job(commands, data, dwords: UInt32(index)))
      XCTAssertTrue(try provider.waitTimeline(reaching: last, timeoutNanoseconds: 0))
    }
    XCTAssertEqual(last, 200)
    XCTAssertEqual(platform.executed.map(\.dwords), (1...200).map(UInt32.init))
  }

  func testAnUnmappableRegisterWindowFailsTheOpen() {
    let platform = FakeAdreno()
    platform.mapRegistersFails = true
    XCTAssertThrowsError(try open(platform)) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .system(AdrenoGPUProvider.EIO))
    }
    XCTAssertTrue(platform.memory.isEmpty)
  }

  func testOutOfMemoryLeavesNoChargeBehind() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    platform.allocationFails = true
    XCTAssertThrowsError(try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false)) {
      XCTAssertEqual($0 as? AdrenoGPUStatus, .outOfMemory)
    }
    XCTAssertEqual(platform.memory.values.filter(\.charged).count, 2)
  }

  func testAFailedInstallIsRetiredBeforeItsChargeIsRefunded() throws {
    let platform = FakeAdreno()
    let provider = try open(platform)
    platform.mapFails = true
    platform.drainFails = true
    XCTAssertThrowsError(try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false))
    XCTAssertTrue(platform.refunded.isEmpty, "undrained pin keeps its charge")
    XCTAssertEqual(platform.pins.count, 3)
    platform.drainFails = false
    XCTAssertThrowsError(try provider.createBuffer(length: 4096, cache: .cached, gpuReadOnly: false))
    XCTAssertEqual(platform.refunded.count, 1)
    XCTAssertEqual(platform.pins.count, 3)
  }

  private func job(_ commands: AdrenoGPUGrant, _ data: AdrenoGPUGrant, dwords: UInt32)
    -> AdrenoGPUJob
  {
    AdrenoGPUJob(
      commands: [.init(handle: commands.handle, byteOffset: 0, dwordCount: dwords)],
      buffers: [
        .init(handle: commands.handle, usage: .read), .init(handle: data.handle, usage: .write),
      ])
  }
}

final class AdrenoPacketTests: XCTestCase {
  func testType7HeadersRoundTripWithTheirParityBits() {
    for opcode in [AdrenoPM4.CP_NOP, AdrenoPM4.CP_INDIRECT_BUFFER, AdrenoPM4.CP_EVENT_WRITE7] {
      for count in [UInt32(0), 1, 3, 0x3fff] {
        let header = AdrenoPM4.pkt7(opcode, count: count)
        let decoded = AdrenoPM4.decode7(header)
        XCTAssertEqual(decoded?.opcode, opcode)
        XCTAssertEqual(decoded?.count, count)
        XCTAssertNil(AdrenoPM4.decode7(header ^ 1 << 15), "bad parity must not decode")
        XCTAssertNil(AdrenoPM4.decode7(header & 0x0fff_ffff))
      }
    }
  }

  func testRingControlEncodesTheBufferSize() {
    XCTAssertEqual(AdrenoPM4.ringControl(bytes: 4096) & 0x3f, 9)
    XCTAssertEqual(AdrenoPM4.ringControl(bytes: 16384) & 0x3f, 11)
    XCTAssertEqual(AdrenoPM4.ringControl(bytes: 4096) >> 8 & 0x3f, 2)
  }
}
