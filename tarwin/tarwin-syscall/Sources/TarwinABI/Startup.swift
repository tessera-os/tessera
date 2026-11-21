/// The payload on the private bootstrap channel, not a service or Linux
/// descriptor header. Flags and tags are metadata, never capability grants.
public struct StartupIdentity: Equatable {
  public let flags: UInt32
  public let app, process, job: UInt64

  public init?(flags: UInt32, app: UInt64, process: UInt64, job: UInt64) {
    guard flags & ~7 == 0, process != 0, job != 0 else { return nil }
    self.flags = flags
    self.app = app
    self.process = process
    self.job = job
  }

  private static func validTag(_ tag: UInt32) -> Bool {
    (1...16).contains(tag) || tag >= 4096
  }

  /// Validate before touching scratch; return exactly the number of bytes to send.
  public func encode(tags: UnsafeBufferPointer<UInt32>, into bytes: UnsafeMutableRawBufferPointer)
    -> Int?
  {
    guard tags.count <= 64 else { return nil }
    let size = 48 + 8 * tags.count
    guard bytes.count >= size else { return nil }
    for i in tags.indices {
      guard Self.validTag(tags[i]) else { return nil }
      for j in 0..<i where tags[i] == tags[j] { return nil }
    }
    func put(_ value: UInt64, _ at: Int, _ width: Int) {
      for i in 0..<width { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    put(0x5453_5254, 0, 4)
    put(1, 4, 4)
    put(UInt64(tags.count), 8, 4)
    put(UInt64(flags), 12, 4)
    put(app, 16, 8)
    put(process, 24, 8)
    put(job, 32, 8)
    put(0, 40, 8)
    for i in tags.indices {
      put(UInt64(tags[i]), 48 + 8 * i, 4)
      put(UInt64(i), 52 + 8 * i, 4)
    }
    return size
  }

  /// On failure install nothing. The recipient still owns all handles from
  /// the read and must close them. Bytes and received names must stay immutable.
  public static func decode(
    _ bytes: UnsafeRawBufferPointer, received: UnsafeBufferPointer<UInt64>,
    into output: UnsafeMutableBufferPointer<StartupEntry>
  ) -> Self? {
    let n = received.count
    guard n <= 64, output.count >= n, bytes.count == 48 + 8 * n else { return nil }
    func word(_ at: Int) -> UInt32 {
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
    }
    func wide(_ at: Int) -> UInt64 {
      UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self))
    }
    guard word(0) == 0x5453_5254, word(4) == 1, word(8) == UInt32(n), wide(40) == 0,
      let identity = Self(flags: word(12), app: wide(16), process: wide(24), job: wide(32))
    else { return nil }
    var used: UInt64 = 0
    for i in 0..<n {
      let tag = word(48 + 8 * i)
      let index = word(52 + 8 * i)
      guard validTag(tag), index < n, received[Int(index)] != 0 else { return nil }
      let bit = UInt64(1) << index
      guard used & bit == 0 else { return nil }
      used |= bit
      for j in 0..<i where word(48 + 8 * j) == tag || received[j] == received[i] { return nil }
    }
    for i in 0..<n {
      output[i] = StartupEntry(tag: word(48 + 8 * i), name: received[Int(word(52 + 8 * i))])
    }
    return identity
  }
}

public struct StartupEntry {
  public let tag: UInt32, name: UInt64
  public init(tag: UInt32 = 0, name: UInt64 = 0) {
    self.tag = tag
    self.name = name
  }
}
