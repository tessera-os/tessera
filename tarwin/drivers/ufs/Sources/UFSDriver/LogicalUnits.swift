// REPORT LUNS on the well-known unit returns variable length data. Unlike a
// block read, an underflow is normal; never scan the untransferred allocation
// tail, or accept a partially returned list.
func reportedUnits(response: [UInt8], data: [UInt8], expected: UInt8) throws -> [UInt8] {
  guard response.count >= 16, response[6] == 0, response[7] == 0 else { throw UFSError.command }
  let flags = response[1] & 0x60
  let residual = response.be(12, 4)
  guard flags == 0 && residual == 0 || flags == 0x20 && residual > 0,
    residual <= UInt64(data.count), data.count - Int(residual) >= 8
  else { throw UFSError.malformed }
  let length = data.be(0, 4)
  let received = data.count - Int(residual)
  guard (1...128).contains(expected), length == UInt64(expected) * 8,
    length == UInt64(received - 8), data.be(4, 4) == 0
  else { throw UFSError.malformed }
  var units = [UInt8]()
  for offset in stride(from: 8, to: received, by: 8) {
    let lun = data[offset + 1]
    guard data[offset] == 0, lun < 0x80, data.be(offset + 2, 6) == 0, !units.contains(lun) else {
      throw UFSError.malformed
    }
    units.append(lun)
  }
  return units
}
func reportUnits(_ t: Transfer, expected: UInt8) throws -> [UInt8] {
  var cdb = [UInt8](repeating: 0, count: 16)
  let bytes: UInt32 = 8 + 128 * 8
  cdb[0] = 0xa0
  cdb.field(6, UInt64(bytes), 4, big: true)
  let answer = try t.readControl(lun: 0x81, cdb: cdb, bytes: bytes)
  return try reportedUnits(response: answer.response, data: answer.data, expected: expected)
}
