import Testing

@testable import TarwinHV

private let all: UInt64 = 0xffff_ffff_0000_0000
private let basic: UInt64 = (1 << 55) | (6 << 50) | (4096 << 32) | 42
private let walk: UInt64 = 0x0210_4040
private func plan(
  _ on: UInt64 = 0x4000, root: UInt64 = 0x8000,
  basicMSR: UInt64 = basic, ept: UInt64 = walk, feature: UInt64 = 5,
  primary: UInt64 = all, secondary: UInt64 = all, pin: UInt64 = all
) -> VMXControls? {
  VMXControls(
    vmx: true, featureControl: feature, basic: basicMSR, physicalBits: 40,
    vmxonPA: on, vmcsPA: 0x5000, eptRoot: root, eptCaps: ept,
    pinCaps: pin, primaryCaps: primary, secondaryCaps: secondary, entryCaps: all, exitCaps: all)
}

@Test func vmxRejectsUnusableRegionsAndMissingIsolationControls() {
  #expect(plan(0x4001) == nil)
  #expect(plan(0x5000) == nil)
  #expect(plan(root: 0x4000) == nil)
  #expect(plan(root: 1 << 40) == nil)
  #expect(plan(1 << 32, basicMSR: basic | (1 << 48)) == nil)
  for bit: UInt64 in [6, 14, 20, 25] { #expect(plan(ept: walk ^ (1 << bit)) == nil) }
  #expect(plan(feature: 4) == nil)
  #expect(plan(basicMSR: basic ^ (1 << 55)) == nil)
  #expect(plan(basicMSR: basic ^ (6 << 50)) == nil)
  #expect(plan(primary: all ^ (1 << 63)) == nil)
  #expect(plan(primary: all | (1 << 25)) == nil)
  #expect(plan(secondary: all ^ (1 << 33)) == nil)
  #expect(plan(secondary: all ^ (1 << 39)) == nil)
  #expect(plan(pin: all ^ (1 << 39)) == nil)
}

@Test func vmcsUsesCheckedEPTPAndStopsAtFirstFailedWrite() throws {
  let p = try #require(plan(primary: all | 2))
  #expect(p.revision == 42)
  var fields: [UInt64: UInt64] = [:]
  #expect(p.install { f, v in fields.updateValue(v, forKey: f) == nil })
  #expect(fields[0x201a] == 0x801e)
  #expect(fields[0x4002] == 0x8100_0082)
  #expect(fields[0x401e] == 2)
  #expect(fields[0x2800] == UInt64.max)
  var wrote = [UInt64]()
  #expect(
    !p.install { field, _ in
      wrote.append(field)
      return field != 0x401e
    })
  #expect(wrote == [0x4000, 0x4002, 0x401e])
}

@Test func launchResumeAndEntryFailureAreDistinct() {
  for failure in [UInt64(1) << 31, nil] {
    var vm = VMXRunState()
    var modes: [Bool] = []
    func enter(_ resume: Bool) -> Bool {
      modes.append(resume)
      return true
    }
    let first = vm.run(enter: enter, readReason: { 18 })
    let second = vm.run(enter: enter, readReason: { 48 })
    let bad = vm.run(enter: enter, readReason: { failure })
    let retry = vm.run(enter: enter, readReason: { 18 })
    #expect(first == 18 && second == 48 && bad == nil && retry == nil)
    #expect(modes == [false, true, true])
  }
  var vm = VMXRunState()
  var reads = 0
  let rejected = vm.run(
    enter: { _ in false },
    readReason: {
      reads += 1
      return 18
    })
  #expect(rejected == nil && reads == 0)
}
