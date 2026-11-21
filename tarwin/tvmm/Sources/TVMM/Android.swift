public enum BridgeService { case input, clipboard, notification, audio, camera, folder }
public struct AppWindow {
  public let app: UInt64
  public let window: UInt64
  public let surface: UInt64
  public let epoch: UInt64

  public init(app: UInt64, window: UInt64, surface: UInt64, epoch: UInt64) {
    self.app = app
    self.window = window
    self.surface = surface
    self.epoch = epoch
  }
}
public struct HostGrant {
  public let token: UInt64
  public let app: UInt64
  public let epoch: UInt64
  public let service: BridgeService
  public let handle: UInt64

  public init(token: UInt64, app: UInt64, epoch: UInt64, service: BridgeService, handle: UInt64) {
    self.token = token
    self.app = app
    self.epoch = epoch
    self.service = service
    self.handle = handle
  }
}

// One instance per sandboxed VM job. Bind/issue/revoke are host control-plane
// operations; the guest can only request a route. A handle never crosses to Android.
public struct AndroidBridge {
  public internal(set) var epoch: UInt64
  public internal(set) var windows: [AppWindow] = []
  public internal(set) var grants: [HostGrant] = []
  public let windowLimit: Int
  public let grantLimit: Int

  public init(epoch: UInt64, windowLimit: Int, grantLimit: Int) {
    self.epoch = epoch
    self.windowLimit = windowLimit
    self.grantLimit = grantLimit
  }

  public mutating func bind(_ app: UInt64, _ window: UInt64, _ surface: UInt64) -> Bool {
    if windows.count >= windowLimit || window == 0 || surface == 0 { return false }
    for w in windows { if w.window == window || w.surface == surface { return false } }
    windows.append(AppWindow(app: app, window: window, surface: surface, epoch: epoch))
    return true
  }
  public mutating func closeWindow(_ window: UInt64) {
    var live: [AppWindow] = []
    for w in windows { if w.window != window { live.append(w) } }
    windows = live
  }
  public mutating func issue(_ grant: HostGrant) -> Bool {
    if grant.epoch != epoch || grant.token == 0 || grant.handle == 0 || grants.count >= grantLimit {
      return false
    }
    for g in grants { if g.token == grant.token { return false } }
    grants.append(grant)
    return true
  }
  public mutating func revoke(_ token: UInt64) {
    var live: [HostGrant] = []
    for g in grants { if g.token != token { live.append(g) } }
    grants = live
  }
  public func route(
    _ app: UInt64, _ window: UInt64, _ surface: UInt64, _ generation: UInt64,
    _ service: BridgeService, _ token: UInt64
  ) -> UInt64 {
    if generation != epoch { return 0 }
    for w in windows {
      if w.app != app || w.window != window || w.surface != surface || w.epoch != epoch { continue }
      for g in grants {
        if g.token == token && g.app == app && g.epoch == epoch && g.service == service {
          return g.handle
        }
      }
    }
    return 0
  }
}
