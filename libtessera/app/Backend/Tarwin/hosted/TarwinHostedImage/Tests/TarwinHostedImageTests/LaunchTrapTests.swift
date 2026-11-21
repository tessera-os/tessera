import Foundation
import TarwinHostedImage
import Testing

@Test func rewritesLoaderSegmentsWithImageRelativeTrapMetadata() throws {
  #expect(HostedTrapRewrite.isSyscallInstruction(0xd400_0001))
  #expect(!HostedTrapRewrite.isSyscallInstruction(0xd400_1001))
  #expect(!HostedTrapRewrite.isSyscallInstruction(HostedTrapRewrite.gateTrap))
  let output = try HostedTrapRewrite.rewrite(
    Data([1, 0, 0, 0xd4, 1, 0, 0, 0xd4]), 0x2000, 0x1000_0000, 0x1000_8000,
    verifiedTrapRVAs: [0x2000, 0x4000])
  #expect(output.text.count == 8)
  #expect(Array(output.text.suffix(4)) == [0xe0, 0xea, 0x2f, 0xd4])
  #expect(Array(output.veneers.prefix(4)) == [0xc0, 0xea, 0x2f, 0xd4])
  #expect(output.siteMap == [0x1000_8000: 0x1000_2000])
}

@Test func trapEnrollmentBindsTheProcessThreadAndVeneerPC() throws {
  let registry = VerifiedTrapRegistry<Int>()
  let veneer: UInt64 = 0x4000
  let original: UInt64 = 0x2000
  let registers = (0..<29).map(UInt64.init)
  try #require(registry.enroll(1, siteMap: [veneer: original], threads: [99: 5]))
  #expect(registry.match(process: 2, kernelThreadID: 99, pc: veneer, registers: registers) == nil)
  #expect(registry.match(process: 1, kernelThreadID: 98, pc: veneer, registers: registers) == nil)
  #expect(registry.match(process: 1, kernelThreadID: 99, pc: original, registers: registers) == nil)
  #expect(!registry.enroll(1, siteMap: [veneer: 0x3000], threads: [100: 6]))
  #expect(registry.match(process: 1, kernelThreadID: 100, pc: veneer, registers: registers) == nil)
  #expect(!registry.enroll(1, siteMap: [:], threads: [100: 5]))
  try #require(registry.enroll(1, siteMap: [veneer: original], threads: [100: 6]))
  #expect(registry.match(process: 1, kernelThreadID: 100, pc: veneer, registers: registers)?.threadID == 6)
  let trap = try #require(registry.match(
    process: 1, kernelThreadID: 99, pc: veneer, registers: registers))
  #expect(trap.originalPC == original)
  #expect(trap.resumePC == veneer + 4)
  #expect(trap.threadID == 5)
  #expect(trap.number == 16)
  #expect((0..<8).allSatisfy { trap.arguments[$0] == UInt64($0) })
  registry.removeProcess(1)
  #expect(registry.match(process: 1, kernelThreadID: 99, pc: veneer, registers: registers) == nil)
}
