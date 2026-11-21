import Testing

@testable import TVMM

func oneAvailable() -> UInt64 { return 1 }
func first(_ slot: UInt64) -> UInt64 { return 0 }
func descriptors() -> [UInt8] { return [0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0, 2, 0, 0, 0] }
func transfer(_ segments: [Segment]) -> UInt64 { return segments[0].length }
func overrun(_ segments: [Segment]) -> UInt64 { return 33 }
nonisolated(unsafe) private var published: UInt64 = 0
nonisolated(unsafe) private var usedLength: UInt64 = 0
func used(_ slot: UInt64, _ head: UInt64, _ length: UInt64) { usedLength = length }
func publish(_ next: UInt64) { published = next }
func drained() -> Bool { return true }

@Test
func publishesUsedAfterExecutionAndBreaksOnOverrun() {
  var pump = QueuePump(slots: 1)
  let ram = GuestAperture(base: 0, length: 4096)
  #expect(
    pump.serviceOne(ram, oneAvailable, first, descriptors, transfer, used, publish)
      == PumpResult.progress)
  #expect(published == 1)
  #expect(usedLength == 32)
  #expect(
    pump.serviceOne(ram, oneAvailable, first, descriptors, transfer, used, publish)
      == PumpResult.drained)
  var bad = QueuePump(slots: 1)
  #expect(
    bad.serviceOne(ram, oneAvailable, first, descriptors, overrun, used, publish)
      == PumpResult.broken)
  #expect(bad.nextUsed == 0)
  #expect(bad.broken)
}

@Test
func modernTransportRequiresVersionAndNegotiationBeforeDriverOk() {
  var state = ModernVirtio(offered: 0x1_0000_0004)
  #expect(state.writeStatus(15, drained) == false)
  #expect(state.writeStatus(1, drained) == true)
  #expect(state.writeStatus(3, drained) == true)
  #expect(state.negotiate(4) == false)
  #expect(state.negotiate(0x1_0000_0008) == false)
  #expect(state.negotiate(0x1_0000_0004) == true)
  #expect(state.writeStatus(11, drained) == true)
  #expect(state.writeStatus(15, drained) == true)
  #expect(state.ready() == true)
  #expect(state.writeStatus(0, drained) == true)
  #expect(state.ready() == false)
}
