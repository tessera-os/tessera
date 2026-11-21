import Testing

@testable import TarwinDebugImage

nonisolated(unsafe) private var saved: UInt8 = 0
func saveByte(_ i: UInt64, _ b: UInt8) { if i == 0 { saved = b } }
func commandByte(_ i: UInt64) -> UInt8 { return saved }
func reg(_ i: UInt64) -> UInt8 { return 171 }
nonisolated(unsafe) private var output: [UInt8] = []
func sendByte(_ b: UInt8) { output.append(b) }
func stopAll() -> Bool { return true }
@Test
func checksumAndAllCpuStopGateRegisterReplies() {
  var reader = PacketReader()
  let bad: [UInt8] = [36, 103, 35, 48]
  for b in bad { #expect(reader.receive(b, saveByte) == RxAction.more) }
  #expect(reader.receive(48, saveByte) == RxAction.reject)
  let good: [UInt8] = [36, 103, 35, 54]
  for b in good { #expect(reader.receive(b, saveByte) == RxAction.more) }
  #expect(reader.receive(55, saveByte) == RxAction.packet)
  var session = RemoteStop()
  #expect(session.connect(false, true, stopAll) == false)
  #expect(!replyStopped(session, 1, commandByte, 1, reg, sendByte))
  #expect(output.count == 0)
  #expect(session.connect(true, true, stopAll) == true)
  #expect(!replyStopped(session, 1, commandByte, 1, reg, sendByte))
  let expected: [UInt8] = [36, 97, 98, 35, 99, 51]
  #expect(output == expected)
}
