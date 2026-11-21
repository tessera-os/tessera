import Darwin
import Foundation
import TarwinLoaderHosted
import TarwinMMHosted
import Testing

private enum Failure: Error { case untrusted, unexpectedRecord, map }

private func elf(train: UInt8) -> Data {
  let page = Int(hostedPageSize)
  var file = Data(count: 3 * page + 16)
  func put<T: FixedWidthInteger>(_ x: T, _ at: Int) {
    var word = x.littleEndian
    withUnsafeBytes(of: &word) { file.replaceSubrange(at..<(at + $0.count), with: $0) }
  }
  put(UInt32(0x464c_457f), 0)
  file[4...6] = Data([2, 1, 1])[...]
  put(UInt16(3), 16)
  put(UInt16(183), 18)
  put(UInt32(1), 20)
  put(UInt64(page), 24)
  put(UInt64(64), 32)
  put(UInt16(64), 52)
  put(UInt16(56), 54)
  put(UInt16(4), 56)
  func header(_ index: Int, _ type: UInt32, _ flags: UInt32, _ offset: Int,
    _ address: Int, _ bytes: Int, _ size: Int
  ) {
    let p = 64 + index * 56
    put(type, p)
    put(flags, p + 4)
    put(UInt64(offset), p + 8)
    put(UInt64(address), p + 16)
    put(UInt64(bytes), p + 32)
    put(UInt64(size), p + 40)
    put(UInt64(page), p + 48)
  }
  var note = 512
  for kind in 1...7 {
    let size = kind == 1 ? 32 : 1
    put(UInt32(8), note)
    put(UInt32(size), note + 4)
    put(UInt32(kind), note + 8)
    file[(note + 12)..<(note + 20)] = Data("Tessera\0".utf8)[...]
    if kind == 4 { file[note + 20] = train }
    note += 20 + ((size + 3) & ~3)
  }
  header(0, 4, 0, 512, 0, note - 512, 0)
  header(1, 1, 5, page, page, 8, 8)
  header(2, 1, 6, 2 * page, 2 * page, page + 16, 2 * page)
  header(3, 0x6474_e552, 4, 2 * page, 2 * page, 1, 1)
  put(UInt32(0x5280_0540), page)
  put(UInt32(0xd65f_03c0), page + 4)
  file[2 * page] = 12
  file[3 * page] = 13
  return file
}

private final class Task: HostedTaskMappings {
  var mapped = [HostedMapCommand]()
  var failAt: Int?
  func map(_ command: HostedMapCommand) throws {
    if mapped.count == failAt { throw Failure.map }
    mapped.append(command)
  }
  func unmap(address: UInt64, size: UInt64) throws {
    mapped.removeAll { $0.address == address }
  }
}

private let window: Range<UInt64> = (1 << 36)..<(1 << 37)

@Test func placementChoosesExecutableFromRemainingAlignedGap() throws {
  let page = hostedPageSize
  var random = SystemRandomNumberGenerator()
  let low = window.lowerBound
  let occupied = [low..<(low + page), (low + 4 * page)..<window.upperBound]
  let base = try HostedImagePlacement.choose(
    window: window, occupied: occupied, span: 2 * page, alignment: 2 * page, using: &random)
  #expect(base == low + 2 * page)
  #expect(throws: HostedImageError.noPlacement) {
    try HostedImagePlacement.choose(
      window: window, occupied: occupied, span: 4 * page, alignment: page, using: &random)
  }
}

@Test func loaderSharesExecutableAndSealsRelroButKeepsPrivateDataCopy() throws {
  #expect(throws: Failure.untrusted) {
    try HostedVerifiedImage.admit(elf(train: 1), requiresEntry: true) { _, _ in
      throw Failure.untrusted
    }
  }
  let image = try HostedVerifiedImage.admit(elf(train: 1), requiresEntry: true) { _, _ in }
  let newTrain = try HostedVerifiedImage.admit(elf(train: 2), requiresEntry: true) { _, _ in }
  let cache = HostedImageCache()
  func load(_ verified: HostedVerifiedImage, _ task: Task) throws -> HostedLoadedImage {
    let space = try HostedAddressSpace(window: window, task: task)
    let loader = HostedImageLoader(space: space, cache: cache)
    return try loader.load(verified, resolve: { _, _, _, _ in throw Failure.unexpectedRecord }) {
      code, _, _ in code
    }
  }
  let one = Task(), two = Task(), third = Task()
  let first = try load(image, one)
  _ = try load(image, two)
  _ = try load(newTrain, third)
  #expect(first.entry == first.range.lowerBound + hostedPageSize)
  #expect(one.mapped.count == 3)
  #expect(one.mapped[0].entry === two.mapped[0].entry)
  #expect(one.mapped[0].entry !== third.mapped[0].entry)
  #expect(one.mapped[0].entry.protection == [.read, .execute])
  #expect(one.mapped[1].entry.protection == .read)
  #expect(one.mapped[2].copy)
  let executable = try one.mapped[0].entry.mapLocally(protection: [.read, .execute])
  let function = unsafeBitCast(UInt(executable.address), to: (@convention(c) () -> UInt32).self)
  #expect(withExtendedLifetime(executable) { function() } == 42)
  #expect(mach_vm_protect(
    mach_task_self_, executable.address, executable.size, 0, VM_PROT_READ | VM_PROT_WRITE)
    == KERN_PROTECTION_FAILURE)
}

@Test func failedImageMapRollsBackTheInstalledPrefix() throws {
  let image = try HostedVerifiedImage.admit(elf(train: 1), requiresEntry: true) { _, _ in }
  let task = Task()
  task.failAt = 1
  let space = try HostedAddressSpace(window: window, task: task)
  let loader = HostedImageLoader(space: space, cache: HostedImageCache())
  #expect(throws: Failure.map) {
    try loader.load(image, resolve: { _, _, _, _ in throw Failure.unexpectedRecord }) {
      code, _, _ in code
    }
  }
  #expect(space.occupiedRanges.isEmpty)
  #expect(task.mapped.isEmpty)
}
