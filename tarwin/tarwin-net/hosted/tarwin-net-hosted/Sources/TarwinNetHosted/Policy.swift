import Synchronization

public enum NetProtocol: Sendable, Hashable { case tcp, udp }

/// Which socket call is being asked for. Filtering runs before the call.
public enum NetDirection: Sendable, Hashable {
  /// connect() or sendto(): the app reaches out to `remote`.
  case outbound
  /// bind()/listen() on `local`, so peers can reach the app.
  case listen
  /// A peer arrived: accept() or recvfrom() from `remote`.
  case inbound
}

public struct NetFlow: Sendable, Hashable {
  public let app: String, proto: NetProtocol, direction: NetDirection, address: NetAddress
  public init(app: String, proto: NetProtocol, direction: NetDirection, address: NetAddress) {
    self.app = app
    self.proto = proto
    self.direction = direction
    self.address = address
  }
}

/// One filter row. Unset fields match anything; ports are inclusive.
public struct NetRule: Sendable, Hashable {
  public enum Action: Sendable { case allow, deny }
  public let action: Action, app: String?, proto: NetProtocol?, direction: NetDirection?
  public let prefix: NetPrefix?, ports: ClosedRange<UInt16>?
  public init(
    _ action: Action, app: String? = nil, proto: NetProtocol? = nil,
    direction: NetDirection? = nil, prefix: NetPrefix? = nil, ports: ClosedRange<UInt16>? = nil
  ) {
    self.action = action
    self.app = app
    self.proto = proto
    self.direction = direction
    self.prefix = prefix
    self.ports = ports
  }
  func matches(_ f: NetFlow) -> Bool {
    (app == nil || app == f.app) && (proto == nil || proto == f.proto)
      && (direction == nil || direction == f.direction)
      && (prefix?.contains(f.address) ?? true) && (ports?.contains(f.address.port) ?? true)
  }
}

/// What an app's signed entitlements allow (from the Tarwin loader).
public struct NetEntitlements: Sendable, Hashable {
  public var client: Bool, server: Bool
  public init(client: Bool = false, server: Bool = false) {
    self.client = client
    self.server = server
  }
}

public enum NetVerdict: Sendable, Equatable {
  case allow
  case deny(String)
}

/// Per-app packet filtering in tarwind (HS-012). Order: the user's and
/// administrator's rules, first match wins; then entitlements: `client`
/// for outbound flows and replies to them, `server` to listen beyond
/// loopback and accept non-loopback peers. Anything else is denied.
/// Multicast and broadcast need an explicit allow rule.
public final class NetPolicy: Sendable {
  private struct State {
    var rules: [NetRule] = []
    var apps: [String: NetEntitlements] = [:]
  }
  private let state = Mutex(State())
  public init(rules: [NetRule] = []) { state.withLock { $0.rules = rules } }

  public func setRules(_ rules: [NetRule]) { state.withLock { $0.rules = rules } }
  public func setEntitlements(_ e: NetEntitlements, for app: String) {
    state.withLock { $0.apps[app] = e }
  }
  public func removeApp(_ app: String) { state.withLock { $0.apps[app] = nil } }

  public func check(_ f: NetFlow) -> NetVerdict {
    let (rules, ent) = state.withLock { ($0.rules, $0.apps[f.app]) }
    if let r = rules.first(where: { $0.matches(f) }) {
      return r.action == .allow ? .allow : .deny("rule")
    }
    guard let ent else { return .deny("unknown app") }
    if f.address.isMulticastOrBroadcast { return .deny("multicast") }
    switch f.direction {
    case .outbound:
      return ent.client && !f.address.isUnspecified ? .allow : .deny("no client entitlement")
    case .listen:
      if f.address.isLoopback && (ent.client || ent.server) { return .allow }
      return ent.server ? .allow : .deny("no server entitlement")
    case .inbound:
      if f.address.isLoopback && (ent.client || ent.server) { return .allow }
      return ent.server ? .allow : .deny("no server entitlement")
    }
  }
}
