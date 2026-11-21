import Testing

@testable import TarwinHV

@Test
func noVmOrDeviceWithWeakerIsolation() {
  let host = GuestCapabilities(
    stageTwo: true, interruptController: true, architecturalTimer: true,
    nested: true, confidential: true, attestation: true, nestedConfidential: false, addressBits: 48,
    cpuFeatures: 3)
  #expect(admitGuest(host, 48, 3, false, true, true, false, 63) == HvError.ok)
  #expect(admitGuest(host, 48, 3, true, true, true, false, 0) == HvError.featureUnavailable)
  #expect(admitGuest(host, 48, 4, false, false, true, false, 0) == HvError.featureUnavailable)
  #expect(admitGuest(host, 48, 0, false, false, false, false, 0) == HvError.accessDenied)
  #expect(admitGuest(host, 48, 0, false, false, false, true, 64) == HvError.limit)
  #expect(admitAssignment(false, true, true, false, true) == HvError.featureUnavailable)
}

@Test
func guestRangesCannotOverflowOrExceedTheMemoryGrant() {
  #expect(validMapping(16384, 0, 16384, 32768, 16384, 16384, 3, 3))
  #expect(!validMapping(16384, 0, 16384, 32768, 16384, 16384, 7, 3))
  #expect(!validGuestRange(0xffff_ffff_ffff_f000, 8192, 0xffff_ffff_ffff_ffff, 4096))
  #expect(!validGuestRange(4096, 4096, 16384, 16384))
  #expect(!overlapsGuest(0, 4096, 4096, 4096))
  #expect(overlapsGuest(8192, 8192, 4096, 8192))
  #expect(dirtyWord(64, 62, 5) == 7)
  #expect(dirtyWord(0xffff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff, 1) == 1)
}

@Test
func canceledRunAndLocalInterruptPriority() {
  var state = VirtualCpuState(creator: 11)
  #expect(state.begin(12) == RunAction.deny)
  #expect(state.begin(11) == RunAction.enter)
  #expect(state.requestExit() == true)
  #expect(state.finish(.wait) == GuestExit.canceled)
  #expect(state.requestExit() == false)
  #expect(state.begin(11) == RunAction.cancel)
  var apic = LocalApic(tpr: 32)
  #expect(apic.raise(256) == false)
  #expect(apic.raise(34) == true)
  #expect(apic.acknowledge() == 0)
  apic.tpr = 0
  #expect(apic.acknowledge() == 34)
  #expect(apic.raise(39) == true)
  #expect(apic.raise(225) == true)
  #expect(apic.acknowledge() == 225)
  #expect(apic.endOfInterrupt() == 225)
  #expect(apic.acknowledge() == 0)
  #expect(apic.endOfInterrupt() == 34)
  #expect(apic.acknowledge() == 39)
}
