import TarwinDevice

@testable import AdrenoGPU

/// FAKE DEVICE MODEL, not Adreno hardware and not a Tarwin platform. It keeps
/// a register file and host allocations, executes the ring when the doorbell
/// is written and reports its own interrupts. Nothing here is evidence about
/// a real GPU, a native requester or the hosted Metal driver.
final class FakeAdreno: AdrenoPlatform, @unchecked Sendable {
  struct Allocation {
    var bytes: UInt64
    var pointer: UnsafeMutableRawPointer
    var cache: AdrenoCacheMode
    var charged = false
  }
  struct Pin {
    var memory: UInt64
    var span: DmaSpan
  }

  // Register and memory state.
  var registers: [UInt32: UInt32] = [:]
  var memory: [UInt64: Allocation] = [:]
  var pins: [UInt64: Pin] = [:]
  var mappings: [UInt64: Pin] = [:]
  var closed: Set<UInt64> = []
  var refunded: Set<UInt64> = []
  var nextKoid: UInt64 = 0
  var nextPin: UInt64 = 0
  var words: [UInt64] = [0x1234_5678_9abc_def0, 0x0fed_cba9_8765_4321, 0x2222_3333_4444_5555]
  var wordIndex = 0

  // Failure injection.
  var mapRegistersFails = false
  var allocationFails = false
  var doorbellSticks = false
  var drainFails = false
  var mapFails = false
  var detachFails = false
  var irqResult: AdrenoIrqWait?
  var fatalInterrupt: UInt32?
  var runOnDoorbell = true
  var counter: UInt64 = 0
  var executed: [(address: UInt64, dwords: UInt32)] = []
  /// Called for every indirect buffer the ring executes, so a test can write
  /// to the buffers the way the GPU would.
  var execute: ((UInt64, UInt32) -> Void)?

  func mapRegisters(_ registers: DeviceRange) -> Bool { !mapRegistersFails }
  func read32(_ register: UInt32) -> UInt32 { registers[register] ?? 0 }

  func write32(_ register: UInt32, _ value: UInt32) {
    if register == AdrenoRegister.RBBM_INT_CLEAR_CMD {
      registers[AdrenoRegister.RBBM_INT_0_STATUS] = read32(AdrenoRegister.RBBM_INT_0_STATUS) & ~value
      return
    }
    if register == AdrenoRegister.CP_RB_WPTR, doorbellSticks { return }
    registers[register] = value
    if register == AdrenoRegister.CP_RB_WPTR, runOnDoorbell { run(upTo: value) }
  }

  func createMemory(bytes: UInt64, cache: AdrenoCacheMode) -> AdrenoMemory? {
    guard !allocationFails else { return nil }
    nextKoid += 1
    let pointer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(bytes), alignment: 4096)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(bytes))
    memory[nextKoid] = Allocation(bytes: bytes, pointer: pointer, cache: cache)
    return AdrenoMemory(koid: nextKoid, bytes: bytes, cpuAddress: pointer)
  }

  func charge(_ memory: UInt64, bytes: UInt64) -> Bool {
    guard self.memory[memory]?.bytes == bytes else { return false }
    self.memory[memory]!.charged = true
    return true
  }

  func refund(_ memory: UInt64, bytes: UInt64) {
    self.memory[memory]?.charged = false
    refunded.insert(memory)
  }

  func closeMemory(_ memory: UInt64) { closed.insert(memory) }

  func randomWord() -> UInt64 {
    defer { wordIndex += 1 }
    return words[wordIndex % words.count] &+ UInt64(wordIndex)
  }

  func pin(_ memory: UInt64, _ span: DmaSpan) -> UInt64 {
    guard self.memory[memory] != nil else { return 0 }
    nextPin += 1
    pins[nextPin] = Pin(memory: memory, span: span)
    return nextPin
  }

  func mapPinned(_ domain: UInt64, _ iova: UInt64, _ pin: UInt64, _ span: DmaSpan) -> Bool {
    guard !mapFails, let entry = pins[pin] else { return false }
    mappings[iova] = entry
    return true
  }

  func detach(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool {
    if detachFails { return false }
    mappings[iova] = nil
    return true
  }
  func invalidateIo(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool { true }
  func invalidateAtcs(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool { true }
  func drainWrites(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool { !drainFails }
  func releasePin(_ pin: UInt64) -> Bool {
    pins[pin] = nil
    return true
  }

  func waitInterrupt(timeoutNanoseconds: UInt64) -> AdrenoIrqWait {
    if let irqResult { return irqResult }
    if let fatalInterrupt {
      registers[AdrenoRegister.RBBM_INT_0_STATUS] = fatalInterrupt
      return .raised
    }
    return read32(AdrenoRegister.RBBM_INT_0_STATUS) != 0 ? .raised : .timedOut
  }

  func completeInterrupt() {}

  /// Host view of a GPU address.
  func host(_ address: UInt64) -> UnsafeMutableRawPointer? {
    for (base, pin) in mappings where address >= base && address - base < pin.span.bytes {
      guard let allocation = memory[pin.memory] else { return nil }
      return allocation.pointer.advanced(by: Int(pin.span.offset + (address - base)))
    }
    return nil
  }

  func load(_ address: UInt64) -> UInt32? {
    host(address).map { UInt32(littleEndian: $0.load(as: UInt32.self)) }
  }

  /// Runs the ring from the last read pointer to the written one, as the CP would.
  private func run(upTo wptr: UInt32) {
    let base = UInt64(read32(AdrenoRegister.CP_RB_BASE))
      | UInt64(read32(AdrenoRegister.CP_RB_BASE_HI)) << 32
    guard let ring = host(base), let size = mappings.first(where: { $0.key == base })?.value.span.bytes
    else { return }
    let dwords = UInt32(size / 4)
    var rptr = read32(AdrenoRegister.CP_RB_RPTR)
    func next() -> UInt32 {
      let word = UInt32(littleEndian: ring.load(fromByteOffset: Int(rptr) * 4, as: UInt32.self))
      rptr = (rptr + 1) % dwords
      return word
    }
    while rptr != wptr {
      guard let packet = AdrenoPM4.decode7(next()) else { break }
      switch packet.opcode {
      case AdrenoPM4.CP_NOP:
        rptr = (rptr + packet.count) % dwords
      case AdrenoPM4.CP_INDIRECT_BUFFER:
        let address = UInt64(next()) | UInt64(next()) << 32
        let count = next()
        executed.append((address, count))
        execute?(address, count)
      case AdrenoPM4.CP_EVENT_WRITE7:
        let control = next()
        let address = UInt64(next()) | UInt64(next()) << 32
        let payload = next()
        if let destination = host(address) {
          destination.storeBytes(of: payload.littleEndian, as: UInt32.self)
        }
        if control & (1 << 31) != 0 {
          registers[AdrenoRegister.RBBM_INT_0_STATUS] =
            read32(AdrenoRegister.RBBM_INT_0_STATUS) | AdrenoInterrupt.CP_CACHE_FLUSH_TS
        }
      default:
        rptr = (rptr + packet.count) % dwords
      }
    }
    registers[AdrenoRegister.CP_RB_RPTR] = rptr
    counter += 97
    registers[AdrenoRegister.CP_ALWAYS_ON_COUNTER] = UInt32(truncatingIfNeeded: counter)
    registers[AdrenoRegister.CP_ALWAYS_ON_COUNTER_HI] = UInt32(truncatingIfNeeded: counter >> 32)
  }
}

func s23PlusNode(identity: UInt64 = AdrenoDiscovery.adreno740, bytes: UInt64 = 1 << 20, interrupts: UInt16 = 1)
  -> HardwareDevice
{
  HardwareDevice(
    location: .firmware(0x3d00000), parent: nil, stable: StableDeviceID(high: 1, low: 2),
    identity: identity, deviceClass: 0x30000, group: 4,
    mmio: [MmioAperture(range: DeviceRange(base: 0x3d00000, length: bytes), frameBuffer: false)],
    wiredInterrupts: interrupts, powerStates: 2, wakeCapable: false)
}

func testProfile(ringBytes: UInt32 = 16384, counterHz: UInt64? = 19_200_000) -> AdrenoProfile {
  AdrenoProfile(
    chipID: AdrenoDiscovery.adreno740, domain: 77,
    gpuAddresses: DeviceRange(base: 0x1_0000_0000, length: 1 << 22), page: 4096,
    ringBytes: ringBytes, counterHz: counterHz)
}
