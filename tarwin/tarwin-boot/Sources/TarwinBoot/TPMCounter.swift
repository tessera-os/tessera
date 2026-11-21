import KCore

/// Read the pinned SHA-256 NV counter with an empty read password. Only
/// ReadPublic and Read are issued. Hold exclusive access to the provisioned
/// TPM and its command buffer across both; never obtain index/name from ESP.
public func readTPMSecurityFloor<P: TpmPort>(
  _ port: inout P, index: UInt32, name: UnsafeRawBufferPointer
) -> UInt64? {
  guard index >> 24 == 1, name.count == 32, (62...4096).contains(port.byteCount()) else { return nil }
  tpmHeader(&port, 0x8001, 0x169, 14)
  putField(&port, p: 10, bytes: 4, value: UInt64(index), big: true)
  let size = port.submit(14)
  // Platform-created, PPWRITE, AUTHREAD, NO_DA, written counter; reject an
  // ordinary writable value, policy or other index even with a claimed Name.
  guard size == 62, tpmSuccess(port, size, tag: 0x8001),
    big(port, p: 10, n: 2) == 14, big(port, p: 12, n: 4) == UInt64(index),
    big(port, p: 16, n: 2) == 0x000b, big(port, p: 18, n: 4) == 0x6204_0011,
    big(port, p: 22, n: 2) == 0, big(port, p: 24, n: 2) == 8,
    big(port, p: 26, n: 2) == 34, big(port, p: 28, n: 2) == 0x000b
  else { return nil }
  for i in name.indices where port.byteAt(30 + UInt64(i)) != name[i] { return nil }
  tpmHeader(&port, 0x8002, 0x14e, 35)
  putField(&port, p: 10, bytes: 4, value: UInt64(index), big: true)
  putField(&port, p: 14, bytes: 4, value: UInt64(index), big: true)
  putField(&port, p: 18, bytes: 4, value: 9, big: true)
  putField(&port, p: 22, bytes: 4, value: 0x4000_0009, big: true)
  putField(&port, p: 26, bytes: 5, value: 0, big: true)
  putField(&port, p: 31, bytes: 2, value: 8, big: true)
  putField(&port, p: 33, bytes: 2, value: 0, big: true)
  let valueSize = port.submit(35)
  guard valueSize == 29, tpmSuccess(port, valueSize, tag: 0x8002),
    big(port, p: 10, n: 4) == 10, big(port, p: 14, n: 2) == 8,
    big(port, p: 24, n: 2) == 0, port.byteAt(26) <= 1, big(port, p: 27, n: 2) == 0
  else { return nil }
  return big(port, p: 16, n: 8)
}
