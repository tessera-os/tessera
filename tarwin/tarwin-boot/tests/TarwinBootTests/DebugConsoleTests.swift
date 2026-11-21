import TarwinBoot
import Testing

@Test func validatesFramebufferExtent() {
  #expect(DisplayMode(width: 0, height: 8, stride: 6, format: 0, capacity: 192) == nil)
  #expect(DisplayMode(width: 6, height: 8, stride: 5, format: 0, capacity: 192) == nil)
  #expect(DisplayMode(width: 6, height: 8, stride: 6, format: 2, capacity: 192) == nil)
  #expect(DisplayMode(width: 6, height: 8, stride: 6, format: 1, capacity: 191) == nil)
  #expect(DisplayMode(width: 1, height: .max, stride: .max, format: 0, capacity: .max) == nil)
}

@Test func debugTextStaysInVisibleCells() throws {
  for format in [UInt32(0), 1] {
    let mode = try #require(DisplayMode(width: 13, height: 16, stride: 16, format: format, capacity: 1024))
    let guardWord: UInt32 = 0xdead_beef
    var storage = [UInt32](repeating: guardWord, count: 257)
    storage.withUnsafeMutableBytes { raw in
      let mapped = UnsafeMutableRawBufferPointer(rebasing: raw[4...])
      let disabled = DebugConsole(mapped: mapped, mode: mode, debugImage: false) == nil
      let short = DebugConsole(mapped: .init(rebasing: mapped[..<1020]), mode: mode, debugImage: true) == nil
      let unaligned = DebugConsole(mapped: .init(rebasing: raw[1...]), mode: mode, debugImage: true) == nil
      #expect(disabled && short && unaligned)
      guard var console = DebugConsole(mapped: mapped, mode: mode, debugImage: true) else {
        Issue.record("rejected display mode"); return
      }
      let first = console.write("a\rAZ")
      let wrapped = console.write("19")
      let full = !console.write("!")
      #expect(first && wrapped && full)
    }
    #expect(storage[0] == guardWord)
    let bg: UInt32 = format == 0 ? 0x402010 : 0x102040
    #expect(Array(storage[1...6]) == [bg, 0xffffff, 0xffffff, 0xffffff, bg, bg])
    for row in 0..<16 {
      #expect(storage[(1 + row * 16 + 12)..<(1 + row * 16 + 16)].allSatisfy { $0 == guardWord })
    }
  }
}
