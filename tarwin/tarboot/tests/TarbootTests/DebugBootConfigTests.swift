import Tarboot
import Testing

private func parse(_ version: String, slot: String = "A") -> DebugBootConfig? {
  Array(
    ("{\"flags\":[\"debug\"],\"securityVersion\":" + version + ",\"slot\":\"" + slot + "\"}").utf8
  )
  .withUnsafeBytes { DebugBootConfig($0) }
}
@Test func parseCanonicalDebugConfig() {
  #expect(parse("0")?.securityVersion == 0)
  #expect(parse("9007199254740991", slot: "B")?.slot == 1)
  #expect(parse("1", slot: "C") == nil)
  for value in ["-1", "1e0", "0.0", "01", " 1", "9007199254740992", "", "1,\"other\":2"] {
    #expect(parse(value) == nil)
  }
}
