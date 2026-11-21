import TarwinArchAarch64
import Testing

private final class Bus: ArmWatchdogIO {
  var control: [UInt32: UInt32] = [0xfcc: 0x1043b]
  var refreshID: UInt32 = 0x1043b
  var writes: [UInt32] = []
  var dropOffset = false
  func read(_ frame: ArmWatchdogFrame, _ offset: UInt32) -> UInt32 {
    frame == .control ? control[offset, default: 0] : refreshID
  }
  func write(_ frame: ArmWatchdogFrame, _ offset: UInt32, _ value: UInt32) {
    writes.append((frame == .control ? 0 : 0x1000) + offset)
    if frame == .control && !(dropOffset && offset == 8) { control[offset] = value }
  }
}

@Test func watchdogRequiresNewDispatchBeforeWarning() {
  let bus = Bus()
  guard var w = ArmGenericWatchdog(bus: bus, offset: 0x1_ffff_ffff, dispatch: 10)
  else { Issue.record("could not arm watchdog"); return }
  #expect(bus.writes == [12, 8, 0])
  #expect(w.service(dispatch: 11) == true)
  #expect(w.service(dispatch: 11) == false)
  #expect(w.service(dispatch: 9) == false)
  bus.control[0] = 3
  #expect(w.service(dispatch: 12) == false)
  #expect(bus.writes == [12, 8, 0, 0x1000])
}

@Test func watchdogRefusesUnsupportedOrActiveFrames() {
  for (ctrl, refresh, state, offset): (UInt32, UInt32, UInt32, UInt64) in [
    (0x1043b, 0x1043b, 0, 0), (0x1043b, 0x1043b, 0, 1 << 48),
    (0x43b, 0x43b, 0, 1 << 32), (0, 0, 0, 1), (0x2043b, 0x2043b, 0, 1),
    (0x43b, 0x1043b, 0, 1), (0x1043b, 0x1043b, 1, 1)] {
    let b = Bus()
    b.control = [0xfcc: ctrl, 0: state]
    b.refreshID = refresh
    let denied = ArmGenericWatchdog(bus: b, offset: offset, dispatch: 1) == nil
    #expect(denied && b.writes.isEmpty)
  }
  let bus = Bus()
  bus.dropOffset = true
  #expect((ArmGenericWatchdog(bus: bus, offset: 7, dispatch: 0) == nil) == true)
  #expect(!bus.writes.contains(0))
  bus.control[0xfcc] = 0x43b
  bus.refreshID = 0x43b
  bus.dropOffset = false
  bus.writes.removeAll()
  let supported = ArmGenericWatchdog(bus: bus, offset: UInt64(UInt32.max), dispatch: 1) != nil
  #expect(supported && bus.writes == [8, 0])
}
