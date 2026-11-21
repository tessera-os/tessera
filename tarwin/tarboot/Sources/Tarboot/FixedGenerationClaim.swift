import TarwinBoot

/// Call only from the isolated non-restorable debug loader. fw_cfg carries
/// the value, not the decision to use that profile. Never mask a device or
/// a malformed inventory with a fixed ID.
public func readFixedQEMUDebugClaim<R: QEMUFileReader>(_ reader: inout R) -> DebugQEMUFixedGeneration? {
  guard case .unavailable = qemuGenerationDevice(&reader) else { return nil }
  var storage = (UInt64(0), UInt64(0))
  return withUnsafeMutableBytes(of: &storage) {
    guard let bytes = copyQEMUFile(&reader, named: "opt/org.tessera/tarwin/debug-fixed-epoch",
      sizes: 16...16, into: $0) else { return nil }
    return DebugQEMUFixedGeneration(low: UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self)),
      high: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
  }
}
