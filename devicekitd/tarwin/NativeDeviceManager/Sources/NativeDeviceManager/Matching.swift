import NativeDriverKit

public struct DriverVersion: Equatable, Comparable {
  public let year: UInt32, month: UInt32
  public init?(_ year: UInt32, _ month: UInt32) {
    guard compatibleDriver(year, month, year, month) else { return nil }
    self.year = year
    self.month = month
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.year, lhs.month) < (rhs.year, rhs.month)
  }
  public func supports(_ api: Self) -> Bool { compatibleDriver(year, month, api.year, api.month) }
}
public enum DriverScalar: Equatable {
  case boolean(Bool)
  case signed(Int64)
  case unsigned(UInt64)
  case real(Double)
  case string(String)
  case bytes([UInt8])
  fileprivate var valid: Bool {
    if case .real(let d) = self { return d.isFinite }
    return true
  }
  fileprivate func between(_ lo: Self, _ hi: Self) -> Bool {
    switch (self, lo, hi) {
    case (.signed(let n), .signed(let a), .signed(let b)): return a <= n && n <= b
    case (.unsigned(let n), .unsigned(let a), .unsigned(let b)): return a <= n && n <= b
    case (.real(let n), .real(let a), .real(let b)):
      return n.isFinite && a.isFinite && b.isFinite && a <= n && n <= b
    default: return false
    }
  }
}
public enum NodeProperty {
  case scalar(DriverScalar)
  case list([DriverScalar])
  case aggregate
}
public enum DriverPredicate {
  case equal(DriverScalar)
  case oneOf([DriverScalar])
  case range(DriverScalar, DriverScalar)
  case mask(UInt64, UInt64)
  case prefix(String)
  case present
  fileprivate var valid: Bool {
    switch self {
    case .equal(let v): return v.valid
    case .oneOf(let a): return !a.isEmpty && a.count <= 256 && a.allSatisfy(\.valid)
    case .range(let lo, let hi): return lo.between(lo, hi)
    case .mask(let m, let bits): return bits & ~m == 0
    default: return true
    }
  }
  fileprivate var identifies: Bool {
    switch self {
    case .equal, .oneOf: return true
    default: return false
    }
  }
  fileprivate func matches(_ p: NodeProperty) -> Bool {
    if case .present = self { return true }
    func one(_ v: DriverScalar) -> Bool {
      switch self {
      case .equal(let n): return n == v
      case .oneOf(let a): return a.contains(v)
      case .range(let lo, let hi): return v.between(lo, hi)
      case .mask(let mask, let bits):
        if case .unsigned(let n) = v { return n & mask == bits }
        if case .signed(let n) = v { return UInt64(bitPattern: n) & mask == bits }
        return false
      case .prefix(let p):
        if case .string(let s) = v { return s.hasPrefix(p) }
        return false
      case .present: return true
      }
    }
    switch p {
    case .scalar(let v): return one(v)
    case .list(let vs): return vs.contains(where: one)
    case .aggregate: return false
    }
  }
}
public struct DriverDictionary {
  fileprivate let requirements: [String: DriverPredicate], score: Int, identity: Bool
  /// Input is normalized by the signed package reader. The property registry
  /// is the target API's, not a declaration supplied by the personality.
  public init?(_ rules: [String: DriverPredicate], score: Int, registered: Set<String>) {
    guard (0...1000).contains(score), rules.count <= 128,
      rules.allSatisfy({ key, v in key != "score" && registered.contains(key) && v.valid })
    else { return nil }
    requirements = rules
    self.score = score
    identity =
      (rules["pci.vendor"]?.identifies == true && rules["pci.device"]?.identifies == true)
      || (rules["usb.vendor"]?.identifies == true && rules["usb.product"]?.identifies == true)
  }
}
public struct InstalledPersonality {
  /// Unique, manager-resolved ID for a particular installed driver executable.
  public let id: String, api: DriverVersion
  fileprivate let dictionaries: [DriverDictionary]
  public init?(id: String, api: DriverVersion, matches: [DriverDictionary]) {
    guard !id.isEmpty, !matches.isEmpty, matches.count <= 128 else { return nil }
    self.id = id
    self.api = api
    dictionaries = matches
  }
}
public enum DriverOrigin { case vendor, generic, thirdParty }
public struct DriverOverride {
  public let pin: String?, exclude: Set<String>, preferGeneric: Bool
  public init(pin: String? = nil, exclude: Set<String> = [], preferGeneric: Bool = false) {
    self.pin = pin
    self.exclude = exclude
    self.preferGeneric = preferGeneric
  }
}
private struct Ranking {
  let id: String, api: DriverVersion, identity: Bool, count: Int, score: Int, vendor: Bool,
    genericPreference: Bool
  func precedes(_ other: Self) -> Bool {
    if genericPreference != other.genericPreference { return genericPreference }
    if identity != other.identity { return identity }
    if count != other.count { return count > other.count }
    if score != other.score { return score > other.score }
    if vendor != other.vendor { return vendor }
    if api != other.api { return api > other.api }
    return id.utf8.lexicographicallyPrecedes(other.id.utf8)
  }
}
/// A snapshot for one registry node. Admission vouches for the package,
/// its signer relationship to this device and its offered families. A pin
/// never bypasses admission, the API window, exclusions or a match.
public func rankDrivers(
  train: DriverVersion, node: [String: NodeProperty], installed: [InstalledPersonality],
  policy: DriverOverride, admit: (InstalledPersonality) -> DriverOrigin?
) -> [String]? {
  var ids = Set<String>()
  var ranks: [Ranking] = []
  for driver in installed {
    guard ids.insert(driver.id).inserted else { return nil }
    guard train.supports(driver.api), !policy.exclude.contains(driver.id),
      policy.pin == nil || policy.pin == driver.id, let origin = admit(driver)
    else { continue }
    var best: Ranking?
    for rule in driver.dictionaries
    where rule.requirements.allSatisfy({ key, p in node[key].map(p.matches) ?? false }) {
      let r = Ranking(
        id: driver.id, api: driver.api, identity: rule.identity, count: rule.requirements.count,
        score: rule.score,
        vendor: origin == .vendor, genericPreference: policy.preferGeneric && origin == .generic)
      if best.map({ r.precedes($0) }) ?? true { best = r }
    }
    if let best { ranks.append(best) }
  }
  return ranks.sorted { $0.precedes($1) }.map(\.id)
}
public struct RequiredDriver: Equatable {
  public let builtInNode: String, personality: String, api: DriverVersion
  public init(builtInNode: String, personality: String, api: DriverVersion) {
    self.builtInNode = builtInNode
    self.personality = personality
    self.api = api
  }
}
/// The update service must supply a complete trusted snapshot of all required
/// built-in bindings, not just drivers available in the prospective train.
public func updateBlockers(train: DriverVersion, required: [RequiredDriver]) -> [RequiredDriver] {
  required.filter { !train.supports($0.api) }.sorted {
    ($0.builtInNode, $0.personality) < ($1.builtInNode, $1.personality)
  }
}
