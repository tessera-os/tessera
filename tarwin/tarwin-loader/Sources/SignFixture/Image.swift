import Foundation
import TarwinLoader

func little<T: FixedWidthInteger>(_ v: T) -> Data {
  withUnsafeBytes(of: v.littleEndian) { Data($0) }
}
func words(_ cv: BlakeCv) -> Data {
  [cv.w0, cv.w1, cv.w2, cv.w3, cv.w4, cv.w5, cv.w6, cv.w7].reduce(into: Data()) { $0 += little($1) }
}
func stack() -> [BlakeCv] {
  Array(repeating: BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
}
extension Data {
  func uint<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) throws -> T {
    try require(
      offset >= 0 && offset <= count && count - offset >= MemoryLayout<T>.size, "invalid offset")
    return withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
  }
}
func makeEnvelope(_ chain: Data) -> Data {
  Data("TSG1".utf8) + little(UInt32(chain.count)) + chain + Data(repeating: 0, count: 3373)
}
/// Keep every LOAD and every other section in place. Append a new file-only
/// note stream; point PT_NOTE and its SHT_NOTE there before computing the ID.
/// The original stream is now ordinary, fully hashed, unreferenced bytes.
func addEnvelope(_ file: Data, _ chain: Data, machine: UInt16, user: EarlyUserRole? = nil) throws
  -> Data
{
  var s = stack()
  let profileBytes: [UInt8]
  switch user {
  case nil: profileBytes = [3, 4]
  case .initialProcess: profileBytes = [1, 0]
  case .systemLibrary: profileBytes = [1, 1]
  }
  let requiresEntry = profileBytes != [1, 1]
  let unsigned = file.withUnsafeBytes { b in
    s.withUnsafeMutableBufferPointer {
      inspectUnsignedArtifact(
        b, machine: machine, addressLimit: UInt64.max, finalized: false,
        requiresEntry: requiresEntry,
        scratch: $0)
    }
  }
  guard let unsigned, let profile = unsigned.notes.profile,
    file[profile].elementsEqual(profileBytes)
  else { throw Failure.invalid("expected unsigned ELF of the requested role") }
  let ph = Int(try file.uint(32, UInt64.self))
  let sh = Int(try file.uint(40, UInt64.self))
  let programs = Int(try file.uint(56, UInt16.self))
  let sections = Int(try file.uint(60, UInt16.self))
  let notes = try (0..<programs).map { ph + $0 * 56 }.filter { try file.uint($0, UInt32.self) == 4 }
  let sht = try (0..<sections).map { sh + $0 * 64 }.filter {
    try file.uint($0 + 4, UInt32.self) == 7
  }
  guard notes.count == 1, sht.count == 1 else { throw Failure.invalid("expected one note stream") }
  let p = notes[0]
  let h = sht[0]
  let start = Int(try file.uint(p + 8, UInt64.self))
  let size = Int(try file.uint(p + 32, UInt64.self))
  try require(
    try file.uint(h + 24, UInt64.self) == UInt64(start)
      && file.uint(h + 32, UInt64.self) == UInt64(size) && file.uint(h + 8, UInt64.self) == 0
      && file.uint(p + 16, UInt64.self) == 0, "not the linker file-only notes")
  let env = makeEnvelope(chain)
  var stream = Data(file[start..<start + size])
  stream += little(UInt32(8))
  stream += little(UInt32(env.count))
  stream += little(UInt32(2))
  stream += Data("Tessera\0".utf8)
  stream += env
  while !stream.count.isMultiple(of: 4) { stream.append(0) }
  var out = file
  while !out.count.isMultiple(of: 4) { out.append(0) }
  for i in [p + 8, h + 24] { out.replaceSubrange(i..<i + 8, with: little(UInt64(out.count))) }
  for i in [p + 32, p + 40, h + 32] {
    out.replaceSubrange(i..<i + 8, with: little(UInt64(stream.count)))
  }
  out += stream
  guard
    let image = out.withUnsafeBytes({
      inspectELF(
        $0, target: machine, addressLimit: .max, finalized: false, requiresEntry: requiresEntry,
        requiresLoaderRecords: true)
    }),
    let id = image.notes.buildID,
    let cv = out.withUnsafeBytes({ b in
      s.withUnsafeMutableBufferPointer { nativeSigningID(b, image: image, scratch: $0) }
    })
  else { throw Failure.invalid("cannot canonicalize final image") }
  out.replaceSubrange(id, with: words(cv))
  return out
}
func signingParts(
  _ file: Data, machine: UInt16, train: [UInt8], tir: [UInt8], user: EarlyUserRole? = nil
) throws -> (
  Data, Range<Int>, Range<Int>
) {
  var s = stack()
  guard train.count == 3, tir.count == 3,
    let image = file.withUnsafeBytes({ b in
      s.withUnsafeMutableBufferPointer { scratch -> InspectedImage? in
        if let user {
          return inspectEarlyUserImage(
            b, role: user, machine: machine,
            train: (train[0], train[1], train[2]), tir: (tir[0], tir[1], tir[2]),
            addressLimit: .max, scratch: scratch)?.image
        }
        return inspectW0SigningCandidate(
          b, machine: machine, train: (train[0], train[1], train[2]),
          tir: (tir[0], tir[1], tir[2]), addressLimit: .max, scratch: scratch)
      }
    }), let sig = image.notes.signature,
    let env = file.withUnsafeBytes({ HybridEnvelope($0, descriptor: sig) })
  else {
    throw Failure.invalid("image does not meet expected role, entry, layout, train and baseline")
  }
  var msg = Data(repeating: 0, count: 1024)
  guard
    let count = file.withUnsafeBytes({ b in
      msg.withUnsafeMutableBytes { nativeSigningMessage(b, notes: image.notes, into: $0) }
    })
  else { throw Failure.invalid("message too large") }
  return (Data(msg.prefix(count)), sig, env.ed25519.lowerBound..<env.mldsa65.upperBound)
}
