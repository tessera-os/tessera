import EarlyVolume
import TarwinBlockWire
import TarwinIPC

// Debug transport: offsets in one fixed grant, never guest/monitor physical addresses.
protocol GuestStorageTransport {
  func exchange(_ grant: UnsafeMutableRawBufferPointer) -> Bool
}

private struct GuestReadDisk<T: GuestStorageTransport>: TrfsMedia {
  let blocks: UInt64 = 256
  let grant: UnsafeMutableRawBufferPointer
  let counter: UnsafeMutablePointer<UInt64>
  let transport: T

  func read(_ block: UInt64, into dst: UnsafeMutableRawBufferPointer) -> Bool {
    guard block < blocks, dst.count == 4096, counter.pointee < .max else { return false }
    counter.pointee += 1
    let id = counter.pointee
    guard
      let r = BlockRequest(
        id: id, epoch: 1, lba: block * 8, blocks: 8,
        queue: 0, op: .read, qos: .interactive, payload: .init(list: 256, vectors: 1))
    else { return false }
    let p = grant.baseAddress!
    let req = r.record()
    for i in 0..<32 {
      p.storeBytes(of: req.words[i].littleEndian, toByteOffset: 4 * i, as: UInt32.self)
      p.storeBytes(of: UInt32.max, toByteOffset: 128 + 4 * i, as: UInt32.self)
    }
    p.storeBytes(of: UInt64(4096).littleEndian, toByteOffset: 256, as: UInt64.self)
    p.storeBytes(of: UInt32(4096).littleEndian, toByteOffset: 264, as: UInt32.self)
    p.storeBytes(of: UInt32(0), toByteOffset: 268, as: UInt32.self)
    guard transport.exchange(grant) else { return false }
    var reply = RingRecord()
    for i in 0..<32 {
      reply.words[i] = UInt32(littleEndian: p.load(fromByteOffset: 128 + 4 * i, as: UInt32.self))
    }
    guard let done = BlockCompletion(record: reply), done.id == id, done.epoch == 1,
      done.queue == 0, done.status == .ok
    else { return false }
    dst.copyMemory(from: .init(start: p + 4096, count: 4096))
    return true
  }
  func write(_ block: UInt64, from src: UnsafeRawBufferPointer) -> Bool { false }
  func flush() -> Bool { false }
  func sha256(_ b: UnsafeRawBufferPointer) -> TrfsDigest {
    let hash = measurementDigest(b)
    return withUnsafeBytes(of: hash) { TrfsDigest($0)! }
  }
}

// The guest's own envelope and payload expectations are independent of the
// monitor and disk contents. This pin is a fixture, not a signed boot verdict.
func exerciseGuestStorage<T: GuestStorageTransport>(
  _ workspace: UnsafeMutableRawBufferPointer,
  transport: T
) -> Bool {
  guard workspace.count == 16384, let p = workspace.baseAddress,
    UInt(bitPattern: p) & 4095 == 0
  else { return false }
  for i in 0..<8192 { workspace[i] = 0 }
  let head: InlineArray<32, UInt8> = [
    0xac, 0xf8, 0xe3, 0x29, 0xe9, 0x80, 0xf5, 0xea, 0x25, 0x30, 0xad, 0x42, 0xc2, 0x9d, 0x53, 0x43,
    0xb0, 0x5a, 0x73, 0x39, 0xf3, 0x18, 0x83, 0xc6, 0xd6, 0x09, 0x81, 0xd3, 0x6e, 0x23, 0x21, 0xe3,
  ]
  var count: UInt64 = 0
  return withUnsafeMutablePointer(to: &count) { counter in
    let disk = GuestReadDisk(
      grant: .init(start: p, count: 8192), counter: counter, transport: transport)
    let dst = UnsafeMutableRawBufferPointer(start: p + 12288, count: 4096)
    let name: StaticString = "system-version"
    guard var volume = TrfsVolume(media: disk, scratch: .init(start: p + 8192, count: 4096)),
      let pin = withUnsafeBytes(of: head, { TrfsDigest($0) }), volume.mount(expected: pin),
      let snap = volume.snapshot, snap.digest == pin,
      case .file(let file) = volume.lookup(
        1, nameBytes: .init(start: name.utf8Start, count: name.utf8CodeUnitCount), in: snap),
      volume.readPage(file, index: 0, in: snap, into: dst) == dst.count
    else { return false }
    for i in dst.indices where dst[i] != UInt8(truncatingIfNeeded: (i >> 4) ^ i) { return false }
    return true
  }
}
