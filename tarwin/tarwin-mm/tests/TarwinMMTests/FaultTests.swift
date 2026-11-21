import TarwinMM

struct CacheProbe: FilePager {
  var pins: UInt64
  var released: UInt64
  var address: UInt64
  mutating func pinFilePage(
    _ object: UInt64, offset: UInt64, validBytes: UInt64, pageSize: UInt64, write: Bool
  ) -> FilePageLease {
    if object != 7 || offset != 4096 || validBytes != 17 || pageSize != 4096 || !write {
      preconditionFailure()
    }
    self.pins += 1
    return FilePageLease(token: 9, physical: self.address)
  }
  mutating func unpinFilePage(_ token: UInt64, dirty: Bool) {
    if token != 9 || dirty { preconditionFailure() }
    self.released += 1
  }
}

func faultTests() -> Bool {
  var cache = CacheProbe(pins: 0, released: 0, address: 8192)
  let lease = faultFilePage(
    &cache, object: 7, size: 4113, offset: 4096, pageSize: 4096, write: true)
  var ok = lease.token == 9 && lease.physical == 8192 && cache.released == 0
  cache.address += 1
  if faultFilePage(&cache, object: 7, size: 4113, offset: 4096, pageSize: 4096, write: true).token
    != 0 || cache.released != 1
  {
    ok = false
  }
  if faultFilePage(&cache, object: 7, size: 4113, offset: 4095, pageSize: 4096, write: true).token
    != 0
    || faultFilePage(&cache, object: 7, size: 4096, offset: 4096, pageSize: 4096, write: true).token
      != 0
    || cache.pins != 2
  {
    ok = false
  }

  var src = buffer(4224)
  var dst = buffer(4224)
  src.putByte(3, value: 93)
  src.putByte(4223, value: 47)
  if !privateCopy(src, frame: &dst, pageSize: 4096, tagged: true) || dst.byteAt(3) != 93
    || dst.byteAt(4223) != 47
  {
    ok = false
  }
  if demandZero(&dst, pageSize: 4096, tagged: false) || dst.byteAt(3) != 93 { ok = false }
  if !demandZero(&dst, pageSize: 4096, tagged: true) || dst.byteAt(3) != 0 || dst.byteAt(4223) != 0
    || src.byteAt(3) != 93
  {
    ok = false
  }
  return ok
}
