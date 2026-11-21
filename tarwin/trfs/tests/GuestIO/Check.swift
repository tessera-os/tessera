import Foundation
import TarwinBlockWire
import TarwinIPC

private enum Mode: CaseIterable { case clean, payload, head, stale, wrongQueue, failed, missing }

private struct HostExchange: GuestStorageTransport {
  let run: (UnsafeMutableRawBufferPointer) -> Bool
  func exchange(_ grant: UnsafeMutableRawBufferPointer) -> Bool { run(grant) }
}

@main
enum Check {
  static func main() throws {
    let image = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(image.count == 256 * 4096)
    let p = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 4096)
    defer { p.deallocate() }
    let workspace = UnsafeMutableRawBufferPointer(start: p, count: 16384)
    for mode in Mode.allCases {
      var reads: UInt64 = 0
      var sawData = false
      let transport = HostExchange { area in
        precondition(area.baseAddress == p && area.count == 8192)
        var record = RingRecord()
        for i in 0..<32 {
          record.words[i] = UInt32(littleEndian: area.load(fromByteOffset: i * 4, as: UInt32.self))
        }
        reads += 1
        guard let r = BlockRequest(record: record, epoch: 1, queue: 0) else {
          preconditionFailure()
        }
        precondition(
          r.id == reads && r.op == .read && r.blocks == 8 && r.lba % 8 == 0 && r.lba <= 2040)
        precondition(r.payload.list == 256 && r.payload.vectors == 1)
        precondition(area.load(fromByteOffset: 256, as: UInt64.self).littleEndian == 4096)
        precondition(area.load(fromByteOffset: 264, as: UInt32.self).littleEndian == 4096)
        precondition(area.load(fromByteOffset: 268, as: UInt32.self) == 0)
        if mode == .missing { return false }
        let offset = Int(r.lba) * 512
        if offset == 4 * 4096 { sawData = true }
        image.withUnsafeBytes {
          UnsafeMutableRawBufferPointer(rebasing: area[4096...]).copyMemory(
            from: .init(rebasing: $0[offset..<(offset + 4096)]))
        }
        if (mode == .head && offset == 6 * 4096) || (mode == .payload && offset == 4 * 4096) {
          area[4096 + 77] ^= 1
        }
        let done = BlockCompletion(
          id: mode == .stale ? r.id + 1 : r.id, epoch: r.epoch,
          queue: mode == .wrongQueue ? 1 : r.queue, status: mode == .failed ? .media : .ok
        ).record()
        for i in 0..<32 {
          area.storeBytes(
            of: done.words[i].littleEndian, toByteOffset: 128 + 4 * i, as: UInt32.self)
        }
        return true
      }
      let ok = exerciseGuestStorage(workspace, transport: transport)
      precondition(ok == (mode == .clean) && reads > 0)
      if mode == .clean || mode == .payload { precondition(sawData) }
      print("\(mode): \(reads) reads; \(ok ? "accepted" : "rejected")")
    }
  }
}
