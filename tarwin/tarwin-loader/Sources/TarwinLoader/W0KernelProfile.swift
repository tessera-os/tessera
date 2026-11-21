// TVISA §17.2 tag of TIR's canonical "fn(ptr) -> never abi(c)".
let w0SinglePointerTag: UInt32 = 0xd441_5060

/// Shared structural policy for the QEMU W0 signer and verifier. This does
/// not establish trust in either signature or authorize a physical branch.
public func inspectW0SigningCandidate(
  _ b: UnsafeRawBufferPointer, machine: UInt16, train: (UInt8, UInt8, UInt8),
  tir: (UInt8, UInt8, UInt8), addressLimit: UInt64, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> InspectedImage? {
  // RV64 passes the hart and TBIB in separate arguments. Do not reuse
  // the single-pointer type tag for that incompatible entry.
  guard machine == ElfMachine.aarch64 || machine == ElfMachine.x64,
    let (image, d, section) = parsedSigningCandidate(
      b, machine: machine, addressLimit: addressLimit,
      finalized: false, requiresEntry: true, scratch: scratch)
  else { return nil }
  let r = ELFReader(bytes: b)
  let n = image.notes
  func version(_ at: Int, _ v: (UInt8, UInt8, UInt8)) -> Bool {
    b[at] == v.0 && b[at + 1] == v.1 && b[at + 2] == v.2
  }
  var hint: Int?
  guard let role = n.profile, r.u16(role.lowerBound) == 0x0403,
    let grants = n.entitlements, r.nameEquals(grants, "[]"),
    let window = n.train, version(window.lowerBound, train), version(window.lowerBound + 3, tir),
    version(window.lowerBound + 6, train), let target = n.target,
    matchesW0Baseline(UnsafeRawBufferPointer(rebasing: b[target]), machine: machine),
    d[.relative].count == 0, d[.authenticated].count == 0, d[.imports].count == 0,
    d[.runtime].count == 0,
    d[.dispatch].count == 0, d[.tls].count == 0, d[.features].count == 0,
    r.u32(section.lowerBound + d[.gpu].bytes.lowerBound) == 0,
    r.validLocalEntry(
      image.entry, tag: w0SinglePointerTag, machine: machine, programs: image.programHeaders,
      hint: &hint)
  else { return nil }
  var note = false
  for p in stride(
    from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
  {
    if r.u32(p) == 4 {
      guard !note, r.u64(p + 16) == 0 else { return nil }
      note = true
    } else {
      guard r.u32(p) == 1, r.u32(p + 4) == 4 || r.u32(p + 4) == 5, r.u64(p + 32) == r.u64(p + 40)
      else { return nil }
    }
  }
  let header = Int(r.u64(40))
  for i in 0..<Int(r.u16(60)) where r.u64(header + 64 * i + 8) & 0x401 != 0 { return nil }
  return note ? image : nil
}
