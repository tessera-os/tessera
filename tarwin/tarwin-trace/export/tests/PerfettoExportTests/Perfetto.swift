import Testing

@testable import PerfettoExport

@Test
func standardTrackPacketHasNoPrivateWrapper() {
  let track = perfettoTrack(7, "x", false)
  let expected: [UInt8] = [10, 10, 80, 1, 226, 3, 5, 8, 7, 18, 1, 120]
  #expect(track == expected)
  let packet = perfettoEvent(7, 150, .end, "", "", 0)
  let end: [UInt8] = [10, 14, 64, 150, 1, 208, 3, 3, 80, 1, 90, 4, 72, 2, 88, 7]
  #expect(packet == end)
}
