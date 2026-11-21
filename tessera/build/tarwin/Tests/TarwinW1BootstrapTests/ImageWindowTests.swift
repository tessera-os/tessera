import TarwinLoader
import TarwinMM
import Testing

@Test func loaderAndMapAgreeOnTheWholeImageWindow() {
  for machine in [ElfMachine.aarch64, ElfMachine.x64, ElfMachine.rv64] {
    let page = imagePage(machine)
    let lo = imageWindow.lowerBound, hi = imageWindow.upperBound
    let middle = lo + ((hi - lo) / page / 2) * page
    let existing = middle..<middle + page
    var slots = [existing, 0..<0, 0..<0]
    slots.withUnsafeMutableBufferPointer { slots in
      guard var map = ImageReservations(storage: slots, used: 1, pageSize: page, userBits: 47),
        let process = ImagePlacementSpace(
          machine: machine, span: 2 * page, alignment: page, occupied: map.occupied),
        let first = process.reservation(randomWord: process.positions),
        let library = ImagePlacementSpace(
          machine: machine, span: page, alignment: page, occupied: map.occupied, excluding: first),
        let last = library.reservation(randomWord: 2 * library.positions - 1)
      else { Issue.record("widened window rejected"); return }
      #expect(process.positions >= minimumImagePositions && library.positions >= minimumImagePositions)
      #expect(first == lo..<lo + 2 * page && last == hi - page..<hi)
      let committed = map.reservePair(first, last)
      #expect(committed && Array(map.occupied) == [first, existing, last])
    }
    let taken = [lo..<hi - (minimumImagePositions - 1) * page]
    taken.withUnsafeBufferPointer { occupied in
      let small = ImagePlacementSpace(machine: machine, span: page, alignment: page, occupied: occupied)
      #expect(small?.positions == minimumImagePositions - 1)
      #expect(small?.reservation(randomWord: .max) == nil)
    }
  }
}
