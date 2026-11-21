import AndroidWire

// One trusted Android compositor/Binder adapter per authenticated application
// endpoint. The adapter resolves the caller and runs its Android permission
// check; neither substitutes for a grant at the host. Transport distinguishes
// a durable rejection (false) from a lost acknowledgement (nil).
public struct GuestWindows {
  public let epoch: UInt64
  private let limit: Int
  private var windows: Set<UInt64> = []
  private var next: UInt64 = 1
  private var lastInput: UInt64 = 0
  public private(set) var disconnected = false

  public init?(epoch: UInt64, limit: Int) {
    guard epoch != 0, limit > 0 else { return nil }
    self.epoch = epoch
    self.limit = limit
  }

  public mutating func request(
    _ operation: WindowOperation, window: UInt64, token: UInt64 = 0,
    payload: [UInt8] = [], androidAllows: () -> Bool, exchange: ([UInt8]) -> Bool?
  ) -> Bool {
    guard !disconnected, next != .max, androidAllows(), operation != .input else { return false }
    if operation == .open {
      guard windows.count < limit && !windows.contains(window) else { return false }
    } else if !windows.contains(window) {
      return false
    }
    guard
      let message = WindowMessage(
        operation: operation, epoch: epoch, sequence: next,
        window: window, token: token, payload: payload)
    else { return false }
    next += 1
    guard let ok = exchange(message.encode()) else {
      disconnected = true
      windows.removeAll()
      return false
    }
    guard ok else { return false }
    if operation == .open { windows.insert(window) }
    if operation == .close { windows.remove(window) }
    return true
  }

  public mutating func input(_ record: [UInt8], deliver: (UInt64, [UInt8]) -> Bool) -> Bool {
    guard !disconnected, let m = WindowMessage(record: record), m.operation == .input,
      m.epoch == epoch, m.sequence > lastInput, windows.contains(m.window)
    else { return false }
    lastInput = m.sequence
    return deliver(m.window, m.payload)
  }
}
