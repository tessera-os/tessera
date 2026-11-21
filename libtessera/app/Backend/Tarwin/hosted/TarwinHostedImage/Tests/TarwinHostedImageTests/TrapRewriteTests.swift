import TarwinHostedImage
import Testing

@Test func rewritesOnlyListedSyscallsAndCatchesAllOtherSVCImmediates() throws {
  let base: UInt64 = 0x1000
  let output = try HostedTrapRewrite.rewrite(
    text: [0xd400_0001, 0xd400_0001, 0xd400_1001, 0xd503_201f],
    at: base, listedTraps: [base], veneersAt: 0x2000)
  #expect(output.text == [0x1400_0400, 0xd42f_eae0, 0xd42f_eae0, 0xd503_201f])
  #expect(output.veneers[0] == HostedTrapRewrite.gateTrap)
  #expect(Array(output.veneers.suffix(4)) == [0xf940_0231, 0xd63f_0220, 0xa8c1_7bf1, 0x17ff_fbf8])
  #expect(output.gateTrapSites == [0x2000: base])
  #expect(output.fatalTrapSites == [0x1004, 0x1008])
}

@Test func tlsVeneersPreserveX0AndLinkUnlessTheyAreTheDestination() throws {
  let output = try HostedTrapRewrite.rewrite(
    text: [0xd53b_d040, 0xd53b_d045, 0xd53b_d05e, 0xd53b_d05f],
    at: 0x1000, listedTraps: [], veneersAt: 0x2000)
  #expect(output.text == [0x1400_0400, 0x1400_040b, 0x1400_0416, 0xd503_201f])
  #expect(output.veneers.count == 36)
  #expect(output.veneers[6] == 0xf940_0631)
  #expect(Array(output.veneers[9...10]) == [0xd503_201f, 0xf841_07fe])
  #expect(Array(output.veneers[21...22]) == [0xaa00_03e5, 0xa8c1_7be0])
  #expect(Array(output.veneers[33...34]) == [0xaa00_03fe, 0xf841_07e0])
}

@Test func refusesInvalidTrapMetadataAndUnreachableVeneers() {
  #expect(throws: HostedRewriteError.invalidTrapSite(0x1000)) {
    try HostedTrapRewrite.rewrite(
      text: [0xd503_201f], at: 0x1000, listedTraps: [0x1000], veneersAt: 0x2000)
  }
  #expect(throws: HostedRewriteError.branchOutOfRange(from: 0x1000, to: 0x900_1000)) {
    try HostedTrapRewrite.rewrite(
      text: [0xd400_0001], at: 0x1000, listedTraps: [0x1000], veneersAt: 0x900_1000)
  }
}
