import Tarboot
import Testing

@Test func independentEmulatorClock() {
  func utc(
    _ year: Int, _ month: UInt8, _ day: UInt8, _ zone: UInt16 = 0,
    daylight: UInt8 = 0, second: UInt8 = 0
  ) -> UInt64? {
    [
      UInt8(truncatingIfNeeded: year), UInt8(year >> 8), month, day, 0, 0, second, 0,
      0, 0, 0, 0, UInt8(truncatingIfNeeded: zone), UInt8(zone >> 8), daylight, 0,
    ]
    .withUnsafeBytes(emulatorUTC)
  }
  #expect(utc(1970, 1, 1) == 0)
  #expect(utc(2000, 2, 29, 2047) == 951_782_400)
  #expect(utc(2100, 2, 29) == nil)
  #expect(utc(2031, 4, 31) == nil)
  #expect(utc(2026, 13, 1) == nil)
  #expect(utc(2026, 2, 1, 60) == nil)
  #expect(utc(2026, 2, 1, daylight: 2) == nil)
  #expect(utc(2026, 2, 1, second: 60) == nil)
  #expect([UInt8](repeating: 0, count: 15).withUnsafeBytes(emulatorUTC) == nil)
}
