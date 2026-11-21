public enum Wire {
  public static let headerSize = 32
  public static let maximumPayload = 65536
  public static let ping: UInt16 = 0xffff
  public static let pong: UInt16 = 0xfffe

  public static func read(_ bytes: UnsafeRawBufferPointer, _ offset: Int, _ width: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<width { value |= UInt64(bytes[offset + i]) << (i * 8) }
    return value
  }
  public static func write(_ value: UInt64, to bytes: UnsafeMutableRawBufferPointer, at offset: Int, width: Int) {
    for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
  }
}

public struct FrameView {
  public let family: UInt16
  public let kind: UInt16
  public let flags: UInt16
  public let sequence: UInt64
  public let timestampNs: UInt64
  public let payload: UnsafeRawBufferPointer

  public init?(_ bytes: UnsafeRawBufferPointer) {
    guard bytes.count >= 32, Wire.read(bytes, 0, 4) == 0x44485754,
      Wire.read(bytes, 4, 2) == 1 else { return nil }
    let length = Int(Wire.read(bytes, 12, 4))
    guard length <= Wire.maximumPayload, bytes.count == 32 + length else { return nil }
    family = UInt16(Wire.read(bytes, 6, 2)); kind = UInt16(Wire.read(bytes, 8, 2))
    flags = UInt16(Wire.read(bytes, 10, 2)); sequence = Wire.read(bytes, 16, 8)
    timestampNs = Wire.read(bytes, 24, 8)
    payload = UnsafeRawBufferPointer(rebasing: bytes[32...])
  }

  @discardableResult
  public static func encode(family: UInt16, kind: UInt16, flags: UInt16 = 0,
    sequence: UInt64, timestampNs: UInt64, payload: UnsafeRawBufferPointer,
    into bytes: UnsafeMutableRawBufferPointer) -> Int? {
    guard payload.count <= Wire.maximumPayload, bytes.count >= 32 + payload.count else { return nil }
    Wire.write(0x44485754, to: bytes, at: 0, width: 4)
    Wire.write(1, to: bytes, at: 4, width: 2)
    Wire.write(UInt64(family), to: bytes, at: 6, width: 2)
    Wire.write(UInt64(kind), to: bytes, at: 8, width: 2)
    Wire.write(UInt64(flags), to: bytes, at: 10, width: 2)
    Wire.write(UInt64(payload.count), to: bytes, at: 12, width: 4)
    Wire.write(sequence, to: bytes, at: 16, width: 8)
    Wire.write(timestampNs, to: bytes, at: 24, width: 8)
    if payload.count > 0 { bytes.baseAddress!.advanced(by: 32).copyMemory(from: payload.baseAddress!, byteCount: payload.count) }
    return 32 + payload.count
  }
}

public enum HIDKind {
  public static let keyboard: UInt16 = 1
  public static let pointer: UInt16 = 2
  public static let tablet: UInt16 = 3
  public static let gesture: UInt16 = 4
  public static let leds: UInt16 = 5
}
