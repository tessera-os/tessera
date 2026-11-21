import TarwinTrace
import Testing

private struct Frozen: PanicSnapshots {
  var cpuCount: UInt32 = 2
  var frames: UInt16 = 1
  func registerByteCount(cpu: UInt32) -> UInt32 { 2 }
  func registerByte(cpu: UInt32, offset: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: cpu + offset) }
  func frameCount(cpu: UInt32) -> UInt16 { frames }
  func frame(cpu: UInt32, index: UInt16) -> UInt64 { UInt64(cpu + 77) }
  let logBytes: UInt64 = 10, traceBytes: UInt64 = 8
  func logByte(_ offset: UInt64) -> UInt8 { UInt8(offset) }
  func traceByte(_ offset: UInt64) -> UInt8 { UInt8(offset + 20) }
}

@Test func captureFitsMaximumPhysicalCpuCountWithoutDroppingACpuOrEitherTail() {
  let snapshots = Frozen(cpuCount: 4096, frames: 256)
  let count = 12 + 4096 * 36 + 12  // Two registers and two frames per CPU, two one-byte tails.
  var bytes = Array(repeating: UInt8(0), count: count)
  #expect(capturePanic(
    snapshots, capacity: UInt64(count), put: { bytes[Int($0)] = $1 }, persist: {},
    mirrorCommitted: { _ in false }) == .ramOnly)
  #expect(panicSize(UInt64(count), { bytes[Int($0)] }) == UInt64(count))
  for cpu in [0, 512, 4095] {
    let record = 12 + cpu * 36
    #expect(bytes[record] == 1 && bytes[record + 1] == 6)
    #expect(Int(bytes[record + 5]) + 256 * Int(bytes[record + 6]) == cpu)
    #expect(bytes[record + 11] == 2 && bytes[record + 12] == 20)
  }
  #expect(Array(bytes.suffix(12)) == [3, 1, 0, 0, 0, 9, 4, 1, 0, 0, 0, 27])
  #expect(capturePanic(
    Frozen(cpuCount: 4097), capacity: PanicLayout.maxBytes,
    put: { _, _ in Issue.record("unexpected write") }, persist: {},
    mirrorCommitted: { _ in true }) == .unavailable)
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
