import Testing

@testable import Tarboot

#if arch(arm64)
  private typealias Seek = @convention(c) (UnsafeRawPointer, UInt64) -> UInt
  private typealias Tell = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> UInt
  private typealias Read =
    @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt>, UnsafeMutableRawPointer) -> UInt

  @Test func firmwarePaths() {
    func valid(_ name: String) -> Bool {
      (Array(name.utf16) + [0]).withUnsafeBufferPointer { absoluteFilePath($0) }
    }
    #expect(valid("\\EFI\\Tessera\\A.tira"))
    for bad in [
      "", "\\", "boot", "\\boot/", "\\a\\", "\\a\0x", "\\a\\.\\b", "\\..\\b", "\\\\b", "\\fs0:x",
    ] {
      #expect(!valid(bad))
    }
    #expect(![UInt16(92), 65, 66].withUnsafeBufferPointer { absoluteFilePath($0) })
  }

  @Test func firmwareFileSizesAndShortReads() {
    // The first 8 words are the EFI file protocol prefix; the rest are test state.
    let seek: Seek = { p, position in
      let table = UnsafeMutableRawPointer(mutating: p).assumingMemoryBound(to: UInt64.self)
      table[9] = position == .max ? table[8] : position
      return table[10] == 4 ? 1 : 0
    }
    let tell: Tell = { p, out in
      out.pointee = p.assumingMemoryBound(to: UInt64.self)[9]
      return 0
    }
    let read: Read = { p, size, output in
      let table = UnsafeMutableRawPointer(mutating: p).assumingMemoryBound(to: UInt64.self)
      let position = table[9]
      let mode = table[10]
      if mode == 3 {
        size.pointee += 1
        return 0
      }
      if mode == 1 || position == table[8] && mode != 2 {
        size.pointee = 0
        return 0
      }
      precondition(size.pointee >= 1)
      output.storeBytes(of: UInt8(position), as: UInt8.self)
      size.pointee = 1
      table[9] += 1
      return 0
    }
    for (size, mode) in [(4, 0), (0, 0), (5, 0), (4, 1), (4, 2), (4, 3), (4, 4)] {
      var table = [UInt64](repeating: 0, count: 11)
      table[0] = 0x10000
      table[8] = UInt64(size)
      table[10] = UInt64(mode)
      var buffer = [UInt8](repeating: 0xff, count: 6)
      let count = table.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: read, toByteOffset: 32, as: Read.self)
        bytes.storeBytes(of: tell, toByteOffset: 48, as: Tell.self)
        bytes.storeBytes(of: seek, toByteOffset: 56, as: Seek.self)
        return buffer.withUnsafeMutableBytes { out in
          readRegular(bytes.baseAddress!, into: UnsafeMutableRawBufferPointer(rebasing: out[1..<5]))
        }
      }
      if mode == 0 && size == 4 {
        #expect(count == 4)
        #expect(buffer == [255, 0, 1, 2, 3, 255])
      } else {
        #expect(count == nil)
      }
      #expect(buffer.first == 255 && buffer.last == 255)
    }
  }
#endif
