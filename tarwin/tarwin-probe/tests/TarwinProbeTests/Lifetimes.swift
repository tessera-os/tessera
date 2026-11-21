import TarwinSyscall
import Testing

@testable import TarwinProbe

func verified(_ module: UInt64, _ hook: UInt64) -> UInt64 {
  return module == 4 && hook == 5 ? 12 : 0
}
func published(_ hook: UInt64, _ token: UInt64) -> Bool { return hook == 5 && token == 12 }
func active(_ hook: UInt64, _ token: UInt64) -> Bool { return false }
func releaseImage(_ token: UInt64) {}

@Test
func onlyVerifiedAuthorizedProbeSurvivesUntilHooksDrain() {
  var a = ProbeAttachment()
  #expect(!attachProbe(TarwinCall.probeAttach, &a, false, 4, 5, verified, published, releaseImage))
  #expect(!attachProbe(TarwinCall.probeAttach, &a, true, 8, 5, verified, published, releaseImage))
  #expect(
    !attachProbe(
      TarwinCall.performanceSessionCreate, &a, true, 4, 5, verified, published, releaseImage))
  #expect(attachProbe(TarwinCall.probeAttach, &a, true, 4, 5, verified, published, releaseImage))
  #expect(a.detach(active, releaseImage) == false)
  #expect(a.image == 12)
  #expect(a.detach(published, releaseImage) == true)
  #expect(a.image == 0)
}

nonisolated(unsafe) private var mapCells: [HashEntry] = []
func loadCell(_ i: UInt64) -> HashEntry { return mapCells[Int(i)] }
func putCell(_ i: UInt64, _ entry: HashEntry) { mapCells[Int(i)] = entry }
@Test
func collisionTombstoneDoesNotHideOrDuplicateKey() {
  for i in 0..<2 { mapCells.append(HashEntry(state: .empty, key: 0, value: 0)) }
  #expect(hashOperation(2, 7, 17, 1, .insert, loadCell, putCell).status == HashStatus.inserted)
  #expect(hashOperation(2, 8, 18, 1, .insert, loadCell, putCell).status == HashStatus.inserted)
  #expect(hashOperation(2, 9, 19, 1, .insert, loadCell, putCell).status == HashStatus.full)
  #expect(hashOperation(2, 7, 0, 1, .erase, loadCell, putCell).status == HashStatus.removed)
  #expect(hashOperation(2, 8, 88, 1, .insert, loadCell, putCell).status == HashStatus.found)
  #expect(hashOperation(2, 8, 0, 1, .lookup, loadCell, putCell).value == 88)
  #expect(hashOperation(2, 9, 19, 1, .insert, loadCell, putCell).status == HashStatus.inserted)
}
