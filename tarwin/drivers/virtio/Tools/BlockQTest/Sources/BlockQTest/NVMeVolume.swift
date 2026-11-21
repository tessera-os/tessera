import CryptoKit
import Foundation
import NVMeDriver
import TRFS
import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC

/// Hosted transport: only ciphertext crosses qtest into guest RAM. Each real
/// NVMe transfer gets one directional VT-d translation and a terminal drain.
private final class NVMeCipherDisk: TrfsRetiredBlockIO {
  let blocks: UInt64, stage: SectorPin
  let q: QTest, dma: TranslatedDisk, channel: BlockChannel,
    controller: UnsafeMutablePointer<NVMeController>
  var error: Error?, key: UInt64 = 0, transfers = 0
  init(
    _ q: QTest, _ d: TranslatedDisk, _ c: BlockChannel, _ p: UnsafeMutablePointer<NVMeController>,
    _ s: SectorPin
  ) {
    self.q = q
    dma = d
    channel = c
    controller = p
    stage = s
    blocks = p.pointee.limits.capacity / 8
  }
  func sha256(_ b: UnsafeRawBufferPointer) -> TrfsDigest {
    SHA256.hash(data: Data(b)).withUnsafeBytes { TrfsDigest($0)! }
  }
  func erase(_ b: UnsafeMutableRawBufferPointer) {
    b.initializeMemory(as: UInt8.self, repeating: 0)
  }
  func flush() -> Bool { perform(.flush, 0) }
  func transfer(_ block: UInt64, physical: UInt64, count: Int, read: Bool) -> Int? {
    guard block < blocks, physical == stage.physical, count == 4096,
      perform(read ? .read : .write, block)
    else { return nil }
    transfers += 1
    return count
  }
  private func perform(_ op: BlockOp, _ block: UInt64) -> Bool {
    guard error == nil else { return false }
    do {
      let data = op != .flush
      let read = op == .read
      let ioPage: UInt64 = 0x111000
      let list: UInt64 = 0x120000
      let frame = stage.physical
      let iova = dma.bias + ioPage
      if data {
        if !read {
          _ = q.send("b64write \(frame) 4096 " + Data(stage.bytes).base64EncodedString())
        } else {
          _ = q.send("memset \(frame) 4096 0xc9")
        }
        try dma.mapData(page: ioPage, frame: frame, access: read ? .deviceWrite : .deviceRead)
      }
      key += 1
      var r = RingRecord()
      let id = try channel.request(
        .init(op: op, lba: block * 8, blocks: data ? 8 : 0, qos: .interactive, queue: 0),
        key: key, payload: data ? BlockPayload(list: list, vectors: 1) : BlockPayload(),
        record: &r)
      try controller.pointee.submit(
        r,
        allows: { a, n, w in
          data && ((a == list && n == 16 && !w) || (a == iova && n == 4096 && w == read))
        }, readVector: { $0 == list ? BlockDmaVector(address: iova, bytes: 4096) : nil })
      let until = ContinuousClock.now + .seconds(3)
      while true {
        if let done = try controller.pointee.poll() {
          try channel.finish(done, id: id, key: key, bytes: data ? 4096 : 0) {
            $0 == id && (!data || self.dma.retireData(page: ioPage, frame: frame))
          }
          break
        }
        try q.require(.now < until, "TRFS NVMe timeout")
        _ = q.send("clock_step 1000000")
      }
      if read {
        guard let b = Data(base64Encoded: q.send("b64read \(frame) 4096")), b.count == 4096
        else { throw Failure("TRFS short ciphertext readback") }
        b.copyBytes(to: stage.bytes)
      }
      if let e = q.error { throw e }
      return true
    } catch {
      // Terminating the private model retires all DMA; never reuse a live pin.
      self.error = error
      q.close()
      return false
    }
  }
}

final class NVMeVolumeScenario {
  private var written: TrfsDigest?
  private let existingSignedDisk: Bool
  private let measurement: (socket: String, root: Data)?
  init(measurement: (socket: String, root: Data)? = nil, existingSignedDisk: Bool = false) {
    self.measurement = measurement
    self.existingSignedDisk = existingSignedDisk
  }
  var devices: [String] {
    guard existingSignedDisk || written != nil, let (socket, _) = measurement else { return [] }
    return ["-chardev", "socket,id=root_tpm,path=" + socket, "-tpmdev",
            "emulator,id=measured,chardev=root_tpm", "-device", "tpm-tis,tpmdev=measured"]
  }
  private let name = Array("system-version".utf8)
  private let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: ($0 >> 4) ^ $0) })
  func run(_ q: QTest, controller: inout NVMeController, dma: TranslatedDisk, channel: BlockChannel)
    throws
  {
    let pages = (0..<4).map { _ in
      UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    }
    defer { for p in pages { p.deallocate() } }
    let cache = SectorPin(physical: 0x130000, bytes: pages[0])!
    let stage = SectorPin(physical: 0x151000, bytes: pages[1])!
    var key = VectorCipher()
    try withUnsafeMutablePointer(to: &controller) { dev in
      let disk = NVMeCipherDisk(q, dma, channel, dev, stage)
      try withUnsafeMutablePointer(to: &key) { k in
        let media = TrfsEncryptedMedia(io: disk, cipher: k, privatePage: cache, ciphertext: stage)!
        var v = TrfsVolume(media: media, scratch: pages[2])!
        if existingSignedDisk || written != nil {
          let mounted: Bool
          if let (_, root) = measurement {
            // An independent pin, never a digest from the first run or the drive.
            let wrong = Data(SHA256.hash(data: Data("unrelated test slot".utf8)))
            var rejected = TrfsVolume(media: media, scratch: pages[2])!
            var called = false
            let accepted = wrong.withUnsafeBytes {
              rejected.mountSystem(bootSetRoot: $0) { _ in called = true; return false }
            }
            guard !accepted, !called, rejected.snapshot == nil, !rejected.mount()
            else { throw Failure("Wrong boot root reached measurement or mount") }
            mounted = root.withUnsafeBytes {
              v.mountSystem(bootSetRoot: $0) { measureSnapshot($0, on: q) }
            }
          } else if let written, !existingSignedDisk {
            mounted = v.mount(expected: written)
          } else {
            throw Failure("Existing disk requires a signed root and measurement")
          }
          guard mounted, let snapshot = v.snapshot,
            case .file(let id) = v.lookup(1, name: name, in: snapshot),
            v.readPage(id, index: 0, in: snapshot, into: pages[3]) == payload.count,
            Data(pages[3]) == payload, v.create(1, name: [97], kind: .file) == nil
          else {
            throw disk.error ?? Failure("Cold NVMe snapshot, content or read-only gate failed")
          }
        } else {
          // Only the two anchors of this disposable, known-new test partition.
          pages[3].initializeMemory(as: UInt8.self, repeating: 0)
          guard media.write(0, from: .init(pages[3])), media.write(1, from: .init(pages[3])),
            media.flush(),
            v.formatBlank(), let id = v.create(1, name: name, kind: .file),
            payload.withUnsafeBytes({ v.writePage(id, index: 0, bytes: $0) }), let root = v.snapshot
          else { throw disk.error ?? Failure("NVMe snapshot publication failed") }
          written = root.digest
        }
      }
      try q.require(
        disk.transfers > 0 && dma.retired == disk.transfers && q.read("l", 0xfed9_0034) == 0,
        "Missing per-sector VT-d drain or hardware fault")
      print(
        "TRFS NVMe: \(disk.transfers) ciphertext transfers/drains, \(channel.notifications) terminal block completions"
      )
    }
  }
  func checkBacking(_ file: URL) throws {
    let b = try Data(contentsOf: file)
    guard b.count == 1_048_576, b.range(of: payload) == nil, b.range(of: Data(name)) == nil,
      b[(7 * 4096)...].allSatisfy({ $0 == 0x6c })
    else { throw Failure("Plaintext or out-of-range disk modification") }
  }
}
