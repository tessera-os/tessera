import TarwinMM
import TarwinW0Verify

/// Reserve virtual space only. Hold exclusive process-map ownership throughout
/// this call and provide fresh kernel CSPRNG draws, or nil on entropy failure.
/// No archive bytes are reopened, PTEs installed or PAC keys changed here.
public func reserveAuthorizedQEMUImages(
  _ set: borrowing W1BootSet, in map: inout ImageReservations, nextRandom: () -> UInt64?
) -> W1AddressPlan? {
  guard map.pageSize == 16384,
    let plan = set.addressPlan(occupied: map.occupied, nextRandom: nextRandom),
    map.reservePair(plan.processReservation, plan.libraryReservation)
  else { return nil }
  return plan
}
