/// A single 2D resource on a modern virtio-gpu control queue. The caller
/// supplies an exclusive, pinned device-readable backing grant and keeps it
/// until teardown completes (or a separately acknowledged reset and drain).
public enum GPU2DOp: Equatable {
  case display, create, attach, upload, scanout, flush, disable, detach, destroy
  fileprivate var opcode: UInt32 {
    switch self {
    case .display: 0x100
    case .create: 0x101
    case .destroy: 0x102
    case .scanout, .disable: 0x103
    case .flush: 0x104
    case .upload: 0x105
    case .attach: 0x106
    case .detach: 0x107
    }
  }
}

public struct GPU2DRequest {
  public let fence: UInt64
  public let bytes: [UInt8]
  public let responseBytes: UInt32
}

public struct GPU2DResource: ~Copyable {
  private let id: UInt32, head: UInt32, width: UInt32, height: UInt32, backing: UInt64
  private var last: GPU2DOp?, pending: GPU2DOp?, fence: UInt64 = 0
  public private(set) var broken = false
  public var retired: Bool { !broken && last == .destroy && pending == nil }

  public init?(
    id: UInt32, scanout: UInt32, width: UInt32, height: UInt32,
    backing: UInt64, backingBytes: UInt32
  ) {
    guard id != 0, scanout < 16, (1...8192).contains(width), (1...8192).contains(height),
      UInt64(width) * UInt64(height) * 4 == UInt64(backingBytes),
      validArea(backing, UInt64(backingBytes), 4)
    else { return nil }
    self.id = id
    self.head = scanout
    self.width = width
    self.height = height
    self.backing = backing
  }

  /// Only one outstanding request for this resource; route completion by the
  /// split queue's private cookie before passing the device's written prefix.
  public mutating func prepare(_ op: GPU2DOp) -> GPU2DRequest? {
    guard !broken, pending == nil, fence < .max else { return nil }
    switch (last, op) {
    case (nil, .display), (.display, .create), (.create, .attach), (.attach, .upload),
      (.upload, .scanout), (.scanout, .flush), (.flush, .upload), (.flush, .disable),
      (.disable, .detach), (.detach, .destroy):
      break
    default: return nil
    }
    pending = op
    fence += 1
    let rect: [UInt32] = [0, 0, width, height]
    var words = [op.opcode, 1, UInt32(truncatingIfNeeded: fence), UInt32(fence >> 32), 0, 0]
    switch op {
    case .display: break
    case .create: words += [id, 2, width, height]  // B8G8R8X8_UNORM
    case .attach:
      words += [
        id, 1, UInt32(truncatingIfNeeded: backing), UInt32(backing >> 32), width * height * 4, 0,
      ]
    case .upload: words += rect + [0, 0, id, 0]
    case .scanout: words += rect + [head, id]
    case .flush: words += rect + [id, 0]
    case .disable: words += [0, 0, 0, 0, head, 0]
    case .detach, .destroy: words += [id, 0]
    }
    var bytes: [UInt8] = []
    for w in words { for s in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: w >> (8 * s))) } }
    return GPU2DRequest(fence: fence, bytes: bytes, responseBytes: op == .display ? 408 : 24)
  }

  public mutating func complete(_ bytes: [UInt8]) -> Bool {
    guard !broken, let op = pending else { return false }
    guard bytes.count == (op == .display ? 408 : 24),
      configLe(bytes, 0, 4) == (op == .display ? 0x1101 : 0x1100),
      configLe(bytes, 4, 4) == 1, configLe(bytes, 8, 4) == UInt32(truncatingIfNeeded: fence),
      configLe(bytes, 12, 4) == UInt32(fence >> 32), configLe(bytes, 16, 4) == 0
    else {
      broken = true
      return false
    }
    if op == .display {
      let p = 24 + 24 * Int(head)
      guard configLe(bytes, p + 16, 4) == 1, configLe(bytes, p + 8, 4) > 0,
        configLe(bytes, p + 12, 4) > 0
      else {
        broken = true
        return false
      }
    }
    last = op
    pending = nil
    return true
  }
}
