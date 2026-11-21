import NativeDeviceManager
import XCTest

final class MatchTests: XCTestCase {
  let keys: Set<String> = [
    "pci.vendor", "pci.device", "pci.class", "storage.model", "dt.compatible", "power.removable",
    "storage.capacity",
  ]
  let node: [String: NodeProperty] = [
    "pci.vendor": .scalar(.unsigned(7)), "pci.device": .scalar(.unsigned(8)),
    "pci.class": .scalar(.unsigned(0x1234)), "storage.model": .scalar(.string("drive B")),
    "dt.compatible": .list([.string("fallback"), .string("device-x")]),
    "storage.capacity": .scalar(.signed(12)),
  ]
  let train = DriverVersion(27, 11)!
  func rule(_ dict: [String: DriverPredicate], _ score: Int) -> DriverDictionary {
    DriverDictionary(dict, score: score, registered: keys)!
  }
  func personality(_ name: String, _ rules: [DriverDictionary], _ version: DriverVersion? = nil)
    -> InstalledPersonality
  {
    InstalledPersonality(id: name, api: version ?? train, matches: rules)!
  }
  func testAllPredicateKindsSpecificityBeforeScoreAndTypedValues() {
    let id = rule(
      ["pci.vendor": .oneOf([.unsigned(1), .unsigned(7)]), "pci.device": .equal(.unsigned(8))], 0)
    let specific = rule(
      [
        "pci.class": .mask(0xff00, 0x1200), "storage.model": .prefix("drive"),
        "dt.compatible": .equal(.string("device-x")),
        "storage.capacity": .range(.signed(12), .signed(15)),
      ], 0)
    let generic = rule(["pci.class": .present], 1000)
    let reject = [
      rule(["pci.device": .equal(.signed(8))], 999),
      rule(["storage.capacity": .range(.unsigned(0), .unsigned(12))], 999),
      rule(["power.removable": .present], 999),
    ]
    let set = [
      personality("generic", [generic]), personality("multi", [specific]),
      personality("direct", [generic, id]), personality("bad", reject),
    ]
    XCTAssertEqual(
      rankDrivers(train: train, node: node, installed: set, policy: DriverOverride()) { _ in
        .generic
      }, ["direct", "multi", "generic"])
    XCTAssertNil(DriverDictionary(["bad": .present], score: 0, registered: keys))
    XCTAssertNil(DriverDictionary(["pci.device": .mask(1, 2)], score: 0, registered: keys))
    XCTAssertNil(
      DriverDictionary(
        ["storage.capacity": .range(.signed(14), .signed(13))], score: 0, registered: keys))
    XCTAssertNil(DriverDictionary([:], score: 1001, registered: keys))
  }
  func testAuthWindowOriginAndOverrides() {
    let cls = rule(["pci.class": .present], 10)
    let low = rule(["pci.class": .present], 0)
    let set = [
      personality("vendor", [cls], DriverVersion(26, 12)), personality("builtin", [cls]),
      personality("legacy", [cls], DriverVersion(26, 11)), personality("forged", [cls]),
      personality("lowscore", [low]),
    ]
    let auth: (InstalledPersonality) -> DriverOrigin? = { d in
      d.id == "forged" ? nil : d.id == "builtin" ? .generic : .vendor
    }
    func rank(_ p: DriverOverride) -> [String]? {
      rankDrivers(train: train, node: node, installed: set, policy: p, admit: auth)
    }
    XCTAssertEqual(rank(DriverOverride()), ["vendor", "builtin", "lowscore"])
    XCTAssertEqual(rank(DriverOverride(preferGeneric: true)), ["builtin", "vendor", "lowscore"])
    XCTAssertEqual(rank(DriverOverride(pin: "vendor", exclude: ["vendor"])), [])
    XCTAssertEqual(rank(DriverOverride(pin: "forged")), [])
    XCTAssertEqual(rank(DriverOverride(pin: "legacy")), [])
    XCTAssertEqual(rank(DriverOverride(pin: "builtin")), ["builtin"])
    XCTAssertNil(
      rankDrivers(
        train: train, node: node, installed: set + [set[0]], policy: DriverOverride(), admit: auth))
    let a = RequiredDriver(builtInNode: "nvme", personality: "legacy", api: DriverVersion(26, 11)!)
    let b = RequiredDriver(
      builtInNode: "display", personality: "vendor", api: DriverVersion(26, 12)!)
    XCTAssertEqual(updateBlockers(train: train, required: [b, a]), [a])
  }
  func testFailedCandidateCannotRaceNextProbeOrHotRemove() {
    var p = DriverProbes(generation: 7, ranked: ["vendor", "generic"])!
    var old = DriverProbes(generation: 6, ranked: ["vendor"])!
    var notices = 0
    let a = p.nextProbe { notices += 1 }!
    let stale = old.nextProbe {}!
    XCTAssertFalse(p.probed(stale, accepted: true))
    XCTAssertTrue(p.probed(a, accepted: false))
    XCTAssertNil(p.nextProbe { notices += 1 })
    XCTAssertFalse(p.retire(a) { _ in false })
    XCTAssertNil(p.nextProbe { notices += 1 })
    XCTAssertTrue(p.retire(a) { $0 == a })
    let b = p.nextProbe { notices += 1 }!
    XCTAssertTrue(p.probed(b, accepted: true))
    XCTAssertTrue(p.started(b, success: true))
    XCTAssertTrue(p.exhausted(b))
    XCTAssertFalse(
      p.retire(a) { _ in
        XCTFail()
        return true
      })
    p.remove()
    XCTAssertTrue(p.retire(b) { $0 == b })
    XCTAssertEqual(p.phase, .removed)
    XCTAssertNil(p.nextProbe { notices += 1 })
    XCTAssertEqual(notices, 0)
  }
  func testUnmatchedNoticeIsOnceAfterLaunchFailure() {
    var p = DriverProbes(generation: 3, ranked: ["gpu"])!
    var n = 0
    let t = p.nextProbe { n += 1 }!
    XCTAssertTrue(p.probed(t, accepted: true))
    XCTAssertTrue(p.started(t, success: false))
    XCTAssertTrue(p.retire(t) { _ in true })
    for _ in 0..<3 { XCTAssertNil(p.nextProbe { n += 1 }) }
    XCTAssertEqual(n, 1)
    XCTAssertEqual(p.phase, .discovered)
  }
}
