#if TARBOOT_ENTER_W0
import Tarboot
import TarwinLoader
import TarwinW0Verify

// Both arguments are held by the loader. The destination is an exclusive,
// disjoint RAM reservation, never an address chosen by the image.
func installArmKernel(_ kernel: W0Kernel, in pages: borrowing FirmwareBootServices.LoaderPages) -> UInt64? {
  let bytes = kernel.bytes, entry = kernel.image.entry
  let headers = kernel.image.programHeaders
  guard pages.base & 16383 == 0, pages.length <= UInt64(Int.max),
    headers.lowerBound >= 64, headers.upperBound <= bytes.count, headers.count % 56 == 0,
    let dest = UnsafeMutableRawPointer(bitPattern: UInt(pages.base)),
    let src = bytes.baseAddress, entry < pages.length, entry >= 4, entry & 15 == 0
  else { return nil }
  func word(_ i: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }
  func wide(_ i: Int) -> UInt64 { bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian }
  var last: UInt64 = 0
  var tagged = false
  for at in stride(from: headers.lowerBound, to: headers.upperBound, by: 56) where word(at) == 1 {
    let off = wide(at + 8), va = wide(at + 16), size = wide(at + 32), mem = wide(at + 40)
    let flags = word(at + 4)
    guard flags == 4 || flags == 5, va >= last, va & 16383 == 0,
      off <= UInt64(bytes.count), size <= UInt64(bytes.count) - off, size <= mem,
      va <= pages.length, mem <= pages.length - va
    else { return nil }
    last = va + mem
    if flags == 5, entry - 4 >= va, entry - va <= size, size - (entry - va) >= 4 {
      let e = Int(off + (entry - va))
      // TVISA §17.2: type of the single physical TBIB pointer and BTI c.
      guard word(e - 4) == 0xd4415060, word(e) == 0xd503245f else { return nil }
      tagged = true
    }
  }
  guard tagged else { return nil }
  dest.initializeMemory(as: UInt8.self, repeating: 0, count: Int(pages.length))
  for at in stride(from: headers.lowerBound, to: headers.upperBound, by: 56) where word(at) == 1 {
    dest.advanced(by: Int(wide(at + 16))).copyMemory(
      from: src.advanced(by: Int(wide(at + 8))), byteCount: Int(wide(at + 32)))
  }
  return pages.base + entry
}

@_extern(c, "tarboot_clean_range")
func cleanRange(_ base: UInt64, _ end: UInt64)

@_extern(c, "tarboot_enter_arm")
func enterArm(_ tbib: UInt64, _ entry: UInt64, _ stackTop: UInt64)
#endif
