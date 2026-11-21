import KCore
import Tarboot

struct ArchiveBytes: ByteSource {
  var data: [UInt8]
  var size: UInt64
  func byteCount() -> UInt64 { return self.size }
  func byteAt(_ offset: UInt64) -> UInt8 {
    if offset >= self.size { preconditionFailure() }
    return data[Int(offset)]
  }
  mutating func set(_ offset: UInt64, value: UInt8) {
    if offset >= self.size { preconditionFailure() }
    data[Int(offset)] = value
  }
}

func archiveTests() -> Bool {
  // Two independent one-byte stored members "a" and "b".
  var data = ArchiveBytes(data: Array(repeating: 0, count: 145), size: 144)
  data.set(0, value: 84)
  data.set(1, value: 73)
  data.set(2, value: 82)
  data.set(3, value: 65)
  data.set(4, value: 1)
  data.set(8, value: 2)
  data.set(16, value: 26)
  data.set(24, value: 97)
  data.set(25, value: 98)
  var p: UInt64 = 26
  while p < 144 {
    let second = p != 26
    data.set(p, value: 1)
    data.set(p + 1, value: second ? UInt8(98) : UInt8(97))
    data.set(p + 2, value: second ? UInt8(25) : UInt8(24))
    data.set(p + 10, value: 1)
    data.set(p + 18, value: 1)
    p += 59
  }
  var name = ArchiveBytes(data: [0], size: 1)
  name.set(0, value: 97)
  let member = findBootMember(data, name: name)
  var ok =
    member.validArchive && member.found && member.offset == 24 && member.stored == 1
    && member.size == 1 && member.digestAt == 53
  name.set(0, value: 99)
  let missing = findBootMember(data, name: name)
  if !missing.validArchive || missing.found { ok = false }
  name.set(0, value: 97)
  data.set(86, value: 97)
  if findBootMember(data, name: name).found { ok = false }
  data.set(86, value: 192)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(86, value: 46)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(86, value: 98)
  data.set(87, value: 26)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(87, value: 25)
  data.set(111, value: 2)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(111, value: 0)
  data.set(111, value: 1)
  if !findBootMember(data, name: name).validArchive { ok = false }
  data.set(111, value: 0)
  data.set(26, value: 129)
  data.set(27, value: 0)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(26, value: 1)
  data.set(27, value: 97)
  data.set(23, value: 128)
  if findBootMember(data, name: name).validArchive { ok = false }
  data.set(23, value: 0)
  data.size = 145
  if findBootMember(data, name: name).validArchive { ok = false }
  var n: UInt64 = 0
  while n < 144 {
    data.size = n
    if findBootMember(data, name: name).validArchive { ok = false }
    n += 1
  }
  return ok
}
