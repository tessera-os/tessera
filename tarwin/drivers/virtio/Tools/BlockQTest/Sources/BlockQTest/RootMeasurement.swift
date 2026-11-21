import CryptoKit
import Foundation
import KCore
import TRFS
import TarwinBoot

private struct TestBytes: ByteBuffer {
  var bytes: [UInt8]
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ i: UInt64) -> UInt8 { bytes[Int(i)] }
  mutating func putByte(_ i: UInt64, value: UInt8) { bytes[Int(i)] = value }
}

// q35 locality 0; the firmware and kernel are not running in this fixture.
private struct Q35TIS: TPMFIFORegisters {
  let q: QTest
  private let base: UInt64 = 0xfed4_0000
  func access() -> UInt8 { UInt8(q.read("b", base)) }
  func setAccess(_ value: UInt8) { q.write("b", base, value) }
  func status() -> UInt32 { UInt32(q.read("l", base + 0x18)) }
  func setStatus(_ value: UInt8) { q.write("b", base + 0x18, value) }
  func receive() -> UInt8 { UInt8(q.read("b", base + 0x24)) }
  func send(_ value: UInt8) { q.write("b", base + 0x24, value) }
}

private func transaction(_ bytes: [UInt8], _ port: inout TPMFIFO<Q35TIS>) -> [UInt8] {
  for i in bytes.indices { port.putByte(UInt64(i), value: bytes[i]) }
  return (0..<port.submit(UInt64(bytes.count))).map { port.byteAt($0) }
}

private func pcr(_ port: inout TPMFIFO<Q35TIS>) -> [UInt8]? {
  // Exact SHA-256 selection; bit 11 only. Skip the variable update counter.
  let selection: [UInt8] = [0, 0, 0, 1, 0, 11, 3, 0, 8, 0]
  let reply = transaction([128, 1, 0, 0, 0, 20, 0, 0, 1, 126] + selection, &port)
  guard reply.count == 62, reply.prefix(10).elementsEqual([128, 1, 0, 0, 0, 62, 0, 0, 0, 0]),
    reply[14..<30].elementsEqual(selection + [0, 0, 0, 1, 0, 32])
  else { return nil }
  return Array(reply.suffix(32))
}

func measureSnapshot(_ root: TrfsDigest, on q: QTest) -> Bool {
  var scratch = [UInt8](repeating: 0, count: 4096)
  return scratch.withUnsafeMutableBytes { memory in
    guard var port = TPMFIFO(registers: Q35TIS(q: q), scratch: memory, pollLimit: 50_000)
    else { return false }
    let started = transaction([128, 1, 0, 0, 0, 12, 0, 0, 1, 68, 0, 0], &port)
    guard started == [128, 1, 0, 0, 0, 10, 0, 0, 0, 0], let before = pcr(&port),
      before.allSatisfy({ $0 == 0 })
    else { return false }
    var digest = TestBytes(bytes: [UInt8](repeating: 0, count: 32))
    guard digest.bytes.withUnsafeMutableBytes({ root.encode(into: $0) }) else { return false }
    let label = TestBytes(bytes: Array("Tarwin system snapshot".utf8))
    var record = TestBytes(bytes: [UInt8](repeating: 0, count: 50 + label.bytes.count))
    var state = MeasurementLog(used: 0, stopped: false)
    guard
      extendAndRecord(&port, state: &state, log: &record, pcr: 11, digest: digest, event: label),
      state.used == UInt64(record.bytes.count), !state.stopped,
      record.bytes.prefix(14).elementsEqual([11, 0, 0, 0, 13, 0, 0, 0, 1, 0, 0, 0, 11, 0]),
      record.bytes[14..<46].elementsEqual(digest.bytes),
      record.bytes[46..<50].elementsEqual([UInt8(label.bytes.count), 0, 0, 0]),
      record.bytes.dropFirst(50).elementsEqual(label.bytes), let after = pcr(&port)
    else { return false }
    let replay = SHA256.hash(data: Data(before + digest.bytes))
    return q.error == nil && after.elementsEqual(replay)
  }
}
