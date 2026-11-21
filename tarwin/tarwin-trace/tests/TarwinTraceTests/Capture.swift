import TarwinTrace
import Testing

private struct Frozen: PanicSnapshots {
  let cpuCount: UInt32 = 2
  func registerByteCount(cpu: UInt32) -> UInt32 { 2 }
  func registerByte(cpu: UInt32, offset: UInt32) -> UInt8 { UInt8(cpu + offset) }
  func frameCount(cpu: UInt32) -> UInt16 { 1 }
  func frame(cpu: UInt32, index: UInt16) -> UInt64 { UInt64(cpu + 77) }
  let logBytes: UInt64 = 10, traceBytes: UInt64 = 8
  func logByte(_ offset: UInt64) -> UInt8 { UInt8(offset) }
  func traceByte(_ offset: UInt64) -> UInt8 { UInt8(offset + 20) }
}

@Test func fullCpuCapturePrioritizesRegistersAndArchivesBeforeClearing() {
  var bytes = Array(repeating: UInt8(0), count: 84)
  func read(_ i: UInt64) -> UInt8 { bytes[Int(i)] }
  func put(_ i: UInt64, _ b: UInt8) { bytes[Int(i)] = b }
  var mirrors = 0
  func store(_ capacity: UInt64) -> PanicCaptureResult {
    capturePanic(
      Frozen(), capacity: capacity, put: put, persist: {},
      mirrorCommitted: { n in
        #expect(n == 84 && panicSize(84, read) == n)
        mirrors += 1
        return false
      })
  }
  #expect(store(84) == .ramOnly)
  // 12 header + 56 CPU bytes (two pairs of TLVs); 16 bytes for tails and TLV headers.
  #expect(bytes[68] == 3 && Array(bytes[73..<76]) == [7, 8, 9])
  #expect(bytes[76] == 4 && Array(bytes[81..<84]) == [25, 26, 27])
  #expect(store(77) == .unavailable && mirrors == 1)
  #expect(!collectPanic(84, read, { _ in false }, put, {}))
  #expect(panicSize(84, read) == 84)
  #expect(collectPanic(84, read, { _ in true }, put, {}))
  #expect(panicSize(84, read) == 0)
}
