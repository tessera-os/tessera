// The trusted slot supplies the aperture, designated offsets and client
// process. A platform that cannot enforce write-only MMIO returns false
// from mapWriteOnlyUcNx, rather than substituting a readable mapping.
public struct DoorbellGrant: Equatable {
  public let process: UInt64
  public let page: UInt64
  public let slotEpoch: UInt64

  public init(process: UInt64, page: UInt64, slotEpoch: UInt64) {
    self.process = process
    self.page = page
    self.slotEpoch = slotEpoch
  }
}

public func grantDoorbell(
  _ apertureBytes: UInt64, _ pageBytes: UInt64, _ designated: [UInt64], _ grant: DoorbellGrant,
  _ liveEpoch: UInt64, _ reserveAndMapWriteOnlyUcNx: (UInt64, UInt64, UInt64, UInt64) -> Bool
) -> Bool {
  if pageBytes == 0 || (pageBytes & (pageBytes - 1)) != 0 || grant.slotEpoch != liveEpoch {
    return false
  }
  if grant.page >= apertureBytes || pageBytes > apertureBytes - grant.page
    || grant.page % pageBytes != 0
  {
    return false
  }
  for offset in designated {
    if offset == grant.page {
      // Reservation includes the slot's revocation record, before exposure.
      return reserveAndMapWriteOnlyUcNx(grant.process, grant.page, pageBytes, liveEpoch)
    }
  }
  return false
}
