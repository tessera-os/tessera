import Darwin
import Foundation
import TarwinHostedImage
import TarwinLoaderHosted
import TarwinMMHosted
import Testing

private enum Failure: Error { case untrusted, unexpectedRecord, map }

private func elf(train: UInt8, trapSites: [UInt32]? = nil) -> Data {
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
  if let trapSites {
    let sections = file.count
    let names = sections + 3 * 64
    let sectionNames = Data("\0.shstrtab\0.tirtrap\0".utf8)
    let traps = names + sectionNames.count
    file.append(Data(count: 3 * 64))
    file.append(sectionNames)
    file.append(Data(count: 4 + trapSites.count * 8))
    put(UInt64(sections), 40)
    put(UInt16(64), 58)
    put(UInt16(3), 60)
    put(UInt16(1), 62)
    put(UInt32(1), sections + 64)
    put(UInt32(3), sections + 68)
    put(UInt64(names), sections + 88)
    put(UInt64(sectionNames.count), sections + 96)
    put(UInt32(11), sections + 128)
    put(UInt32(1), sections + 132)
    put(UInt64(traps), sections + 152)
    put(UInt64(4 + trapSites.count * 8), sections + 160)
    put(UInt32(trapSites.count), traps)
    for (index, site) in trapSites.enumerated() {
      put(site, traps + 4 + index * 8)
      if site == UInt32(page + 4) { put(UInt16(7), traps + 8 + index * 8) }
    }
    header(1, 1, 5, page, page, 16, 16)
    put(UInt32(0xd400_0001), page)
    put(UInt32(0xd420_00e0), page + 4)
    put(UInt32(0xd400_0001), page + 8)
    put(UInt32(0xd65f_03c0), page + 12)
  }
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
      code, _, _, _ in (code, Data(), [:])
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
      code, _, _, _ in (code, Data(), [:])
    }
  }
  #expect(space.occupiedRanges.isEmpty)
  #expect(task.mapped.isEmpty)
}

private func trapRewriter(for image: HostedVerifiedImage) -> HostedImageLoader.TrapRewriter {
  { code, rva, base, veneersAt in
    try HostedTrapRewrite.rewrite(code, rva, base, veneersAt, verifiedTrapRVAs: image.trapRVAs)
  }
}

@Test func loadsH2VeneersFromSignedSiteMetadataAndRollsBackOnSidecarFailure() throws {
  let page = UInt32(hostedPageSize)
  let image = try HostedVerifiedImage.admit(
    elf(train: 1, trapSites: [page, page + 4]), requiresEntry: true
  ) { _, _ in }
  #expect(image.trapRVAs == [UInt64(page)])
  let task = Task()
  let space = try HostedAddressSpace(window: window, task: task)
  let loader = HostedImageLoader(space: space, cache: HostedImageCache())
  task.failAt = 3
  #expect(throws: Failure.map) {
    try loader.load(image, resolve: { _, _, _, _ in throw Failure.unexpectedRecord },
      rewrite: trapRewriter(for: image))
  }
  #expect(task.mapped.isEmpty)
  #expect(space.occupiedRanges.isEmpty)

  task.failAt = nil
  let loaded = try loader.load(image, resolve: { _, _, _, _ in throw Failure.unexpectedRecord },
    rewrite: trapRewriter(for: image))
  let veneer = try #require(task.mapped.last)
  let text = try #require(task.mapped.first)
  #expect(loaded.siteMap == [veneer.address: text.address])
  #expect(veneer.entry.protection == [.read, .execute])
  #expect(veneer.address != text.address)
  let mapped = try veneer.entry.mapLocally(protection: [.read, .execute])
  let pointer = try #require(UnsafeRawPointer(bitPattern: UInt(mapped.address)))
  #expect(pointer.load(as: UInt32.self) == HostedTrapRewrite.gateTrap)
  #expect(mach_vm_protect(mach_task_self_, mapped.address, mapped.size, 0, VM_PROT_READ | VM_PROT_WRITE)
    == KERN_PROTECTION_FAILURE)
  let mappedText = try text.entry.mapLocally(protection: [.read, .execute])
  let textPointer = try #require(UnsafeRawPointer(bitPattern: UInt(mappedText.address)))
  #expect(textPointer.load(fromByteOffset: 4, as: UInt32.self) == 0xd420_00e0)
  #expect(textPointer.load(fromByteOffset: 8, as: UInt32.self) == HostedTrapRewrite.forbiddenTrap)
}

@Test func rejectsInvalidTrapMetadataAndUnenrolledVeneerClaims() throws {
  let page = UInt32(hostedPageSize)
  for sites in [[page, page], [page + 4, page], [page + 2], [page + 12], [page * 2]] {
    #expect(throws: HostedImageError.invalidImage) {
      try HostedVerifiedImage.admit(elf(train: 1, trapSites: sites), requiresEntry: true) { _, _ in }
    }
  }
  let image = try HostedVerifiedImage.admit(
    elf(train: 1, trapSites: [page]), requiresEntry: true
  ) { _, _ in }
  let task = Task()
  let space = try HostedAddressSpace(window: window, task: task)
  let loader = HostedImageLoader(space: space, cache: HostedImageCache())
  #expect(throws: HostedImageError.invalidTrapRewrite) {
    try loader.load(image, resolve: { _, _, _, _ in throw Failure.unexpectedRecord }) {
      code, rva, base, veneersAt in
      (code, Data(count: 4), [veneersAt: base + rva + 8])
    }
  }
  #expect(task.mapped.isEmpty)
}
