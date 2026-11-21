import Testing

@testable import TarwinW1Bootstrap

@Test func measurementUsesOnlyThePinnedArchiveAndADisjointLog() {
  var storage = [UInt8](repeating: 0, count: 256)
  storage.withUnsafeMutableBytes { all in
    let archive = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(all)[32..<128])
    let member = UnsafeRawBufferPointer(rebasing: archive[24..<40])
    func ok(_ r: Range<Int>, _ l: Range<Int>) -> Bool {
      exactMember(member, in: archive, at: r, excluding: .init(rebasing: all[l]))
    }
    #expect(ok(24..<40, 128..<256))
    #expect(ok(24..<40, 0..<32))
    #expect(!ok(23..<39, 128..<256))
    #expect(!ok(24..<41, 128..<256))
    #expect(!ok(-1..<15, 128..<256))
    #expect(!ok(81..<97, 128..<256))
    #expect(!ok(24..<24, 128..<256))
    #expect(!ok(24..<40, 127..<256))
    #expect(!ok(24..<40, 0..<33))
  }
}
