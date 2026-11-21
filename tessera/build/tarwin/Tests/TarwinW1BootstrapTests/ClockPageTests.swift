import TarwinArchAarch64
import TarwinTime
import Testing
@testable import TarwinW1Bootstrap

@Test func sharedClockRejectsAliasesAndWrongOwner() {
  let page = 16384
  let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 8 * page, alignment: page)
  let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: page, alignment: page)
  defer { memory.deallocate(); buffer.deallocate() }
  buffer.initializeMemory(as: UInt8.self, repeating: 0xa7)
  let va: UInt64 = 0xffff800000000000, pa: UInt64 = 0x200000
  guard var kernel = ArmKernelTranslation(backing: .init(rebasing: memory[..<(4 * page)]), physical: 0x100000),
    let mapping = W1ClockReservation(physical: pa, kernelVA: va, host: &kernel),
    var user = ArmUserTranslation(backing: .init(rebasing: memory[(4 * page)...]), physical: 0x180000)
  else { Issue.record("roots"); return }
  #expect(mapping.install(in: &user, privatePool: 0x180000..<pa + 16384) == false)
  #expect(mapping.install(in: &user, privatePool: 0x181000..<pa) == false)
  #expect(mapping.install(in: &user, privatePool: 0x180000..<pa) == true)
  #expect(mapping.install(in: &user, privatePool: 0x180000..<pa) == false)
  let otherMem = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * page, alignment: page)
  defer { otherMem.deallocate() }
  guard var other = ArmKernelTranslation(backing: otherMem, physical: 0x400000),
    other.insert(virtual: va, physical: 0x800000, write: true, execute: false),
    let wrong = other.finish(), let clock = SystemClocks(frequency: 1, counter: 0)
  else { Issue.record("wrong host"); return }
  let refused = mapping.startMapped(in: wrong, clock: clock, bytes: buffer) == nil
  #expect(refused && buffer.allSatisfy { $0 == 0xa7 })
}

@Test func matchingUninstalledHostCannotStartTheClockPublisher() {
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16384)
  defer { bytes.deallocate() }
  guard var kernel = ArmKernelTranslation(backing: bytes, physical: 0x100000, layout: .guarded),
    let reservation = W1ClockReservation(physical: 0x200000, kernelVA: 0xffff800000000000, host: &kernel),
    let root = kernel.finish(), let clock = SystemClocks(frequency: 1, counter: 0)
  else { Issue.record("clock mapping"); return }
  let refused = reservation.start(in: root, clock: clock) == nil
  #expect(refused)
}
