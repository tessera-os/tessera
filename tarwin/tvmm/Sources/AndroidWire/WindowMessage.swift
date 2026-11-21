// Train-private record on an ordered, authenticated, app-bound agent channel.
// It carries guest window IDs and grant tokens, never app identities or host handles.
public enum WindowOperation: UInt8 {
  case open = 1
  case close, clipboard, notification, audio, camera, folder, input
}

public struct WindowMessage {
  public static let header = 40
  public static let maxPayload = 65536
  public let operation: WindowOperation
  public let epoch: UInt64
  public let sequence: UInt64
  public let window: UInt64
  public let token: UInt64
  public let payload: [UInt8]

  public init?(
    operation: WindowOperation, epoch: UInt64, sequence: UInt64,
    window: UInt64, token: UInt64, payload: [UInt8]
  ) {
    guard epoch != 0, sequence != 0, window != 0, payload.count <= Self.maxPayload else {
      return nil
    }
    if operation == .open || operation == .close {
      guard token == 0 && payload.isEmpty else { return nil }
    } else if token == 0 {
      return nil
    }
    self.operation = operation
    self.epoch = epoch
    self.sequence = sequence
    self.window = window
    self.token = token
    self.payload = payload
  }

  public init?(record: [UInt8]) {
    guard record.count >= Self.header, record.count <= Self.header + Self.maxPayload,
      record[0] == 1, let op = WindowOperation(rawValue: record[1]), record[2] == 0,
      record[3] == 0
    else { return nil }
    func word(_ start: Int, _ count: Int) -> UInt64 {
      var result: UInt64 = 0
      for i in 0..<count { result |= UInt64(record[start + i]) << (8 * i) }
      return result
    }
    guard word(4, 4) == UInt64(record.count - Self.header) else { return nil }
    self.init(
      operation: op, epoch: word(8, 8), sequence: word(16, 8), window: word(24, 8),
      token: word(32, 8), payload: Array(record.dropFirst(Self.header)))
  }

  public func encode() -> [UInt8] {
    var bytes: [UInt8] = [1, operation.rawValue, 0, 0]
    for (v, n) in [(UInt64(payload.count), 4), (epoch, 8), (sequence, 8), (window, 8), (token, 8)] {
      for i in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> (i * 8))) }
    }
    bytes.append(contentsOf: payload)
    return bytes
  }
}
