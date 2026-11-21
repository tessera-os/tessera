import AndroidWire

// Constructed by the host control plane from an authenticated endpoint, not
// from guest bytes. Bind a fresh channel (and epoch on restart) to its VM job.
public struct AgentChannel {
  public let app: UInt64
  public let epoch: UInt64
  public private(set) var disconnected = false
  private var next: UInt64 = 1
  private var nextInput: UInt64 = 1

  public init?(app: UInt64, epoch: UInt64) {
    guard app != 0, epoch != 0 else { return nil }
    self.app = app
    self.epoch = epoch
  }

  // The entire exchange runs under the VM's serialized control executor.
  // nil is a malformed/broken channel: tear down its windows and do not retry.
  public mutating func receive(
    _ record: [UInt8], bridge: inout AndroidBridge,
    makeSurface: (UInt64, UInt64) -> UInt64, closeSurface: (UInt64) -> Void,
    invoke: (BridgeService, UInt64, UInt64, [UInt8]) -> Bool
  ) -> Bool? {
    guard !disconnected else { return nil }
    guard bridge.epoch == epoch, let m = WindowMessage(record: record), m.epoch == epoch,
      m.sequence == next, next != .max
    else {
      disconnect(bridge: &bridge, closeSurface: closeSurface)
      return nil
    }
    next += 1
    let window = bridge.windows.first { $0.window == m.window && $0.app == app }
    switch m.operation {
    case .open:
      guard window == nil, bridge.windows.count < bridge.windowLimit else { return false }
      let surface = makeSurface(app, m.window)
      guard surface != 0 else { return false }
      if bridge.bind(app, m.window, surface) { return true }
      closeSurface(surface)
      return false
    case .close:
      guard let window else { return false }
      bridge.closeWindow(app: app, window: window.window)
      closeSurface(window.surface)
      return true
    case .input: return false
    default:
      guard let window else { return false }
      let service: BridgeService
      switch m.operation {
      case .clipboard: service = .clipboard
      case .notification: service = .notification
      case .audio: service = .audio
      case .camera: service = .camera
      case .folder: service = .folder
      default: return false
      }
      let handle = bridge.route(app, window.window, window.surface, epoch, service, m.token)
      return handle != 0 && invoke(service, handle, window.surface, m.payload)
    }
  }

  // Only one endpoint may own (app, epoch); close it before admitting a
  // replacement. Revoking routes does not dispose shared host service handles.
  public mutating func disconnect(bridge: inout AndroidBridge, closeSurface: (UInt64) -> Void) {
    guard !disconnected else { return }
    disconnected = true
    guard bridge.epoch == epoch else { return }
    bridge.grants.removeAll { $0.app == app }
    let closing = bridge.windows.filter { $0.app == app }
    bridge.windows.removeAll { $0.app == app }
    for w in closing { closeSurface(w.surface) }
  }

  public mutating func input(
    bridge: AndroidBridge, surface: UInt64, grant: UInt64,
    payload: [UInt8], send: ([UInt8]) -> Bool
  ) -> Bool {
    guard !disconnected, nextInput != .max,
      let window = bridge.windows.first(where: { $0.surface == surface && $0.app == app }),
      bridge.route(app, window.window, surface, epoch, .input, grant) != 0,
      let m = WindowMessage(
        operation: .input, epoch: epoch, sequence: nextInput,
        window: window.window, token: grant, payload: payload)
    else { return false }
    nextInput += 1
    return send(m.encode())
  }
}
