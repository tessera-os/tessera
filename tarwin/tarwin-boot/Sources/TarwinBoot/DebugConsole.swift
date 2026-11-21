/// The current linear GOP mode. Stride counts 32-bit pixels, including padding.
public struct DisplayMode {
  public let width: Int
  public let height: Int
  public let stride: Int
  public let format: UInt32
  public let byteCount: Int

  public init?(width: UInt32, height: UInt32, stride: UInt32, format: UInt32, capacity: UInt64) {
    let pixels = UInt64(stride) * UInt64(height)
    guard width > 0, height > 0, stride >= width, format <= 1,
      pixels <= UInt64(Int.max / 4), pixels * 4 <= capacity else { return nil }
    self.width = Int(width)
    self.height = Int(height)
    self.stride = Int(stride)
    self.format = format
    self.byteCount = Int(pixels * 4)
  }
}

/// A single writer on an authenticated debug image. Its caller owns the mapping
/// until the console is dropped and before a display driver takes over.
public struct DebugConsole: ~Copyable {
  private let pixels: UnsafeMutablePointer<UInt32>
  private let mode: DisplayMode
  private var x = 0
  private var y = 0

  /// Only for a mapped, aligned, writable linear pixel aperture with regular
  /// framebuffer store semantics. A physical address or TBIB field is not a mapping.
  @unsafe public init?(mapped: UnsafeMutableRawBufferPointer, mode: DisplayMode, debugImage: Bool) {
    guard debugImage, mode.width >= 6, mode.height >= 8, mapped.count >= mode.byteCount,
      let base = mapped.baseAddress, UInt(bitPattern: base) & 3 == 0 else { return nil }
    self.mode = mode
    pixels = base.assumingMemoryBound(to: UInt32.self)
  }

  /// Stops at the bottom rather than scrolling over memory the console doesn't own.
  @discardableResult public mutating func write(_ text: StaticString) -> Bool {
    for i in 0..<text.utf8CodeUnitCount {
      let byte = text.utf8Start[i]
      if byte == 13 { x = 0; continue }
      if byte == 10 { x = 0; y = min(y + 8, mode.height); continue }
      if x > mode.width - 6 { x = 0; y = min(y + 8, mode.height) }
      guard y <= mode.height - 8 else { return false }
      var glyph = bitmap(byte)
      // Dark blue background, white text. Reserved channel remains zero.
      let background: UInt32 = mode.format == 0 ? 0x402010 : 0x102040
      for row in 0..<8 {
        for col in 0..<6 {
          pixels[(y + row) * mode.stride + x + col] =
            col < 5 && glyph & (16 >> col) != 0 ? 0x00ff_ffff : background
        }
        glyph >>= 8
      }
      x += 6
    }
    return true
  }
}

// Five glyph bits per row, top row in the low byte. ASCII letters fold to capitals.
private func bitmap(_ byte: UInt8) -> UInt64 {
  switch (97...122).contains(byte) ? byte - 32 : byte {
  case 32: return 0
  case 48: return 0x0e_11_19_15_13_11_0e // 0
  case 49: return 0x0e_04_04_04_04_0c_04 // 1
  case 50: return 0x1f_08_04_02_01_11_0e // 2
  case 51: return 0x1e_01_01_0e_01_01_1e // 3
  case 52: return 0x02_02_1f_12_0a_06_02 // 4
  case 53: return 0x1e_01_01_1e_10_10_1f // 5
  case 54: return 0x0e_11_11_1e_10_08_06 // 6
  case 55: return 0x08_08_08_04_02_01_1f // 7
  case 56: return 0x0e_11_11_0e_11_11_0e // 8
  case 57: return 0x0c_02_01_0f_11_11_0e // 9
  case 65: return 0x11_11_11_1f_11_11_0e // A
  case 66: return 0x1e_11_11_1e_11_11_1e // B
  case 67: return 0x0e_11_10_10_10_11_0e // C
  case 68: return 0x1e_11_11_11_11_11_1e // D
  case 69: return 0x1f_10_10_1e_10_10_1f // E
  case 70: return 0x10_10_10_1e_10_10_1f // F
  case 71: return 0x0f_11_11_17_10_11_0e // G
  case 72: return 0x11_11_11_1f_11_11_11 // H
  case 73: return 0x0e_04_04_04_04_04_0e // I
  case 74: return 0x0c_12_02_02_02_02_07 // J
  case 75: return 0x11_12_14_18_14_12_11 // K
  case 76: return 0x1f_10_10_10_10_10_10 // L
  case 77: return 0x11_11_11_15_15_1b_11 // M
  case 78: return 0x11_13_13_15_19_19_11 // N
  case 79: return 0x0e_11_11_11_11_11_0e // O
  case 80: return 0x10_10_10_1e_11_11_1e // P
  case 81: return 0x0d_12_15_11_11_11_0e // Q
  case 82: return 0x11_12_14_1e_11_11_1e // R
  case 83: return 0x1e_01_01_0e_10_10_0f // S
  case 84: return 0x04_04_04_04_04_04_1f // T
  case 85: return 0x0e_11_11_11_11_11_11 // U
  case 86: return 0x04_0a_11_11_11_11_11 // V
  case 87: return 0x11_1b_15_15_11_11_11 // W
  case 88: return 0x11_11_0a_04_0a_11_11 // X
  case 89: return 0x04_04_04_04_0a_11_11 // Y
  case 90: return 0x1f_10_08_04_02_01_1f // Z
  case 58: return 0x00_04_04_00_04_04_00 // :
  case 46: return 0x0c_0c_00_00_00_00_00 // .
  case 45: return 0x00_00_00_1f_00_00_00 // -
  case 47: return 0x10_10_08_04_02_01_01 // /
  default: return 0x04_00_04_02_01_11_0e
  }
}
