import Foundation
import KCore
import TarwinDevice

private struct TableBytes: ByteSource {
  let bytes: [UInt8]
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ p: UInt64) -> UInt8 { bytes[Int(p)] }
}

// QTest executes no BIOS. Read the model's own fw_cfg files before starting
// translation, and apply only the firmware linker checksum for its DMAR.
// Never derive a unit by scanning arbitrary RAM or by poking candidate MMIO.
func discoverQ35Vtd(_ q: QTest, requester: UInt16) throws -> FirmwareVtd {
  func readFile(_ key: UInt16, _ size: Int) throws -> [UInt8] {
    guard size > 0, size <= 1024 * 1024 else { throw Failure("Oversize fw_cfg read") }
    let descriptor: UInt32 = 0x700000
    let buffer: UInt64 = 0x800000
    q.write("l", UInt64(descriptor), (UInt32(key) << 16 | 10).bigEndian)
    q.write("l", UInt64(descriptor) + 4, UInt32(size).bigEndian)
    q.write("q", UInt64(descriptor) + 8, buffer.bigEndian)
    _ = q.send("outl 0x514 0")
    _ = q.send("outl 0x518 \(descriptor.bigEndian)")
    guard q.read("l", UInt64(descriptor)) == 0,
      let bytes = Data(base64Encoded: q.send("b64read \(buffer) \(size)")), bytes.count == size
    else { throw q.error ?? Failure("fw_cfg read failed") }
    return Array(bytes)
  }
  func number(_ b: [UInt8], _ i: Int, _ n: Int, be: Bool) -> Int {
    var v = 0
    for k in 0..<n { v |= Int(b[i + k]) << ((be ? n - 1 - k : k) * 8) }
    return v
  }
  let count = number(try readFile(0x19, 4), 0, 4, be: true)
  guard count <= 4096 else { throw Failure("Invalid fw_cfg directory") }
  let directory = try readFile(0x19, 4 + 64 * count)
  func file(_ name: String) throws -> [UInt8] {
    var index: Int?
    for i in stride(from: 4, to: directory.count, by: 64) {
      if directory[(i + 8)..<(i + 64)].prefix(while: { $0 != 0 }).elementsEqual(name.utf8) {
        guard index == nil else { throw Failure("Duplicated fw_cfg file") }
        index = i
      }
    }
    guard let i = index else { throw Failure("Missing fw_cfg file \(name)") }
    return try readFile(
      UInt16(number(directory, i + 4, 2, be: true)), number(directory, i, 4, be: true))
  }
  let loader = try file("etc/table-loader")
  let blob = try file("etc/acpi/tables")
  guard loader.count % 128 == 0 else { throw Failure("Invalid firmware linker file") }
  var dmar: TableBytes?
  for p in stride(from: 0, to: loader.count, by: 128) where number(loader, p, 4, be: false) == 3 {
    guard
      loader[(p + 4)..<(p + 60)].prefix(while: { $0 != 0 }).elementsEqual("etc/acpi/tables".utf8)
    else { continue }
    let start = number(loader, p + 64, 4, be: false)
    let size = number(loader, p + 68, 4, be: false)
    guard start <= blob.count, size <= blob.count - start else {
      throw Failure("Invalid firmware checksum range")
    }
    let range = blob[start..<(start + size)]
    guard range.starts(with: "DMAR".utf8) else { continue }
    guard dmar == nil, size >= 48, number(loader, p + 60, 4, be: false) == start + 9,
      range[start + 9] == 0
    else { throw Failure("Invalid DMAR checksum command") }
    var bytes = Array(range)
    bytes[9] = 0 &- bytes.reduce(0, &+)
    dmar = TableBytes(bytes: bytes)
  }
  // Independent aperture check for this private q35 model only. A platform
  // implementation must consult its trusted reserved-memory map.
  guard let dmar,
    let unit = firmwareVtd(
      dmar, segment: 0, requester: requester,
      reservedRegisters: { $0 == DeviceRange(base: 0xfed9_0000, length: 4096) })
  else { throw Failure("No supported DMAR covering the disk requester") }
  return unit
}
