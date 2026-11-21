import TarwinArchAarch64
import Testing

@Test func guardedRootsKeepGCSSeparateFromWritableDataAndRELRO() {
  let page = 16384
  let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * page, alignment: 16)
  defer { buf.deallocate() }
  let va: UInt64 = 1 << 43
  let pa: UInt64 = 0x10_0000
  let step = UInt64(page)
  func index(_ leaf: UInt64) -> UInt64 {
    ((leaf >> 6) & 1) | (((leaf >> 51) & 1) << 1) | (((leaf >> 53) & 3) << 2)
  }
  func permission(_ bank: UInt64, _ slot: Int) -> UInt64 {
    let word = buf.load(fromByteOffset: 3 * page + slot * 8, as: UInt64.self)
    return (bank >> (4 * index(word))) & 15
  }
  func checkUser(_ layout: ArmPermissionLayout) {
    var t = ArmUserTranslation(backing: buf, physical: 0x80000, layout: layout)!
    let control = t.insertControlPage(virtual: va, physical: pa)
    #expect(control == (layout == .guarded))
    guard layout == .guarded else { return }
    #expect(t.mapsControlPage(va, physical: pa) && !t.mapsPrivateDataPage(va, physical: pa))
    let data = t.insert(virtual: va + step, physical: pa + step, write: true, execute: false)
    let code = t.insert(
      virtual: va + 2 * step, physical: pa + 2 * step, write: false, execute: true)
    let ro = t.insert(virtual: va + 3 * step, physical: pa + 3 * step, write: false, execute: false)
    #expect(data && code && ro)
    for (slot, access) in [9, 12, 10, 8].enumerated() {
      #expect(permission(ArmPermissionLayout.pire0, slot) == UInt64(access))
      #expect(permission(ArmPermissionLayout.pir, slot) == 0)
    }
    let badSeal = t.sealReadOnly(va..<va + step)
    let sealed = t.sealReadOnly(va + step..<va + 2 * step)
    #expect(!badSeal && sealed && permission(ArmPermissionLayout.pire0, 1) == 8)
    let invalid = t.insertControlPage(virtual: 1 << 32, physical: pa + 4 * step)
    #expect(!invalid && !t.mapsControlPage(va + step, physical: pa + step))
  }
  checkUser(.direct)
  checkUser(.guarded)
  let high: UInt64 = 0xffff_8000_0000_0000
  var k = ArmKernelTranslation(backing: buf, physical: 0x80000, layout: .guarded)!
  let rx = k.insert(virtual: high, physical: pa, write: false, execute: true)
  let rw = k.insert(virtual: high + step, physical: pa + step, write: true, execute: false)
  let ro = k.insert(virtual: high + 2 * step, physical: pa + 2 * step, write: false, execute: false)
  #expect(rx && rw && ro && !k.mapsPrivateDataPage(high + 2 * step, physical: pa + 2 * step))
  let mmio = k.insertReadOnlyDevice(virtual: high + 3 * step, physical: 0x090d_0000)
  let normalAlias = k.mapsPrivateDataPage(high + 3 * step, physical: 0x090d_0000)
  let low = k.insertReadOnlyDevice(virtual: 0x100000000, physical: 0x090d_0000)
  #expect(mmio && !normalAlias && !low)
  #expect(permission(ArmPermissionLayout.pir, 2) == 8 && permission(ArmPermissionLayout.pire0, 2) == 0)
  #expect(permission(ArmPermissionLayout.pir, 3) == 8 && permission(ArmPermissionLayout.pire0, 3) == 0)
  let leaves = buf.bindMemory(to: UInt64.self)
  #expect((leaves[6146] >> 2) & 7 == 0 && (leaves[6147] >> 2) & 7 == 1)
  #expect(
    permission(ArmPermissionLayout.pir, 0) == 10 && permission(ArmPermissionLayout.pir, 1) == 12)
  #expect(
    permission(ArmPermissionLayout.pire0, 0) == 0 && permission(ArmPermissionLayout.pire0, 1) == 0)
}
