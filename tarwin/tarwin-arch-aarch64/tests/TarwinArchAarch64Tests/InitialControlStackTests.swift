import TarwinArchAarch64
import Testing

private enum Setup: CaseIterable {
  case valid, ordinaryData, missingPage, wrongFrame, lowerGuardMapped,
    upperGuardMapped, directRoot, overflowingPhysical, wrongSize
}

@Test func firstControlStackRequiresExactFramesBetweenBothGuards() {
  let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16)
  defer { mem.deallocate() }
  let page: UInt64 = 16384
  let pa: UInt64 = 0x100000
  let va = (UInt64(1) << 43) + page
  func accepts(_ setup: Setup) -> Bool {
    let layout: ArmPermissionLayout = setup == .directRoot ? .direct : .guarded
    var tables = ArmUserTranslation(backing: mem, physical: 0x80000, layout: layout)!
    if setup == .ordinaryData || setup == .directRoot {
      _ = tables.insert(virtual: va, physical: pa, write: true, execute: false)
    } else {
      _ = tables.insertControlPage(virtual: va, physical: pa)
    }
    if setup != .missingPage {
      _ = tables.insertControlPage(virtual: va + page, physical: pa + (setup == .wrongFrame ? 2 : 1) * page)
    }
    if setup == .lowerGuardMapped || setup == .upperGuardMapped {
      _ = tables.insert(
        virtual: setup == .lowerGuardMapped ? va - page : va + 2 * page,
        physical: pa + 3 * page, write: false, execute: false)
    }
    guard
      let state = ArmInitialControlStack(
        tables: tables, shadow: va..<va + 2 * page,
        physical: setup == .overflowingPhysical ? .max - page + 1 : pa,
        stackBytes: (setup == .wrongSize ? 8 : 9) * page)
    else { return false }
    return state.root == tables.physicalRoot && state.pointer == va + 2 * page - 8
  }
  for setup in Setup.allCases { #expect(accepts(setup) == (setup == .valid)) }
  #expect(ArmInitialControlStack.control == 0x421)
}
