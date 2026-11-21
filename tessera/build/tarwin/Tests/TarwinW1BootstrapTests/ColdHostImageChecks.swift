import TarwinArchAarch64
import TarwinW0Verify
import Testing
@testable import TarwinW1Bootstrap

func checkColdHostImage(_ set: W1BootSet, archive: UnsafeRawBufferPointer) {
  let base = W1ColdHostPages.kernelStart, page = W1ColdHostPages.page
  let hostBytes = W1ColdHostPages.bytes, size = W1ColdHostPages.kernelBytes
  let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: hostBytes + size, alignment: page)
  defer { ram.deallocate() }
  let hostMemory = UnsafeMutableRawBufferPointer(rebasing: ram[..<hostBytes])
  let copy = UnsafeMutableRawBufferPointer(rebasing: ram[hostBytes...])
  let pa: UInt64 = 0x4000000, physical = pa + UInt64(hostBytes)
  for success in [false, true] {
    guard var host = W1ColdHostPages(backing: hostMemory, physical: pa,
      privateAllocation: (pa - UInt64(page))..<pa, draw: 17) else { Issue.record(); return }
    var cleaned = Set<Int>()
    func stage(_ va: UInt64, _ start: UInt64, _ file: UnsafeRawBufferPointer) -> UInt64? {
      host.stageKernel(set, archive: file, virtual: va, physical: start, copy: copy) { frame in
        let i = frame.baseAddress! - UnsafeRawPointer(copy.baseAddress!)
        #expect(i >= 0 && i % page == 0 && i <= size - page && frame.count == page)
        #expect(cleaned.insert(i).inserted)
        return success
      }
    }
    let chosen = base + UInt64(size) * ((1 << 18) - 1)
    copy.initializeMemory(as: UInt8.self, repeating: 0xaa)
    #expect(stage(base + 16384, physical, archive) == nil)
    #expect(stage(base - UInt64(size), physical, archive) == nil)
    #expect(stage(chosen + UInt64(size), physical, archive) == nil)
    #expect(stage(chosen, physical - UInt64(page), archive) == nil)
    #expect(stage(chosen, physical, .init(rebasing: archive.dropFirst())) == nil)
    #expect(cleaned.isEmpty && copy.allSatisfy { $0 == 0xaa })
    let entry = stage(chosen, physical, archive)
    if !success { #expect(entry == nil && cleaned.count == 1); continue }
    #expect(entry == chosen + set.kernel.image.entry)
    let bytes = set.kernel.bytes, headers = set.kernel.image.programHeaders
    func word(_ i: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }
    func wide(_ i: Int) -> Int { Int(bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian) }
    var mapped = [UInt64](repeating: 0, count: size / page), expectedClean = Set<Int>()
    for h in stride(from: headers.lowerBound, to: headers.upperBound, by: 56) where word(h) == 1 {
      let off = wide(h+8), rva = wide(h+16), n = wide(h+32), rx = word(h+4) == 5
      #expect(copy[rva..<rva+n].elementsEqual(bytes[off..<off+n]))
      let end = (rva + n + page - 1) & ~(page - 1)
      #expect(copy[rva+n..<end].allSatisfy { $0 == 0 })
      for i in stride(from: rva, to: end, by: page) {
        if rx { expectedClean.insert(i) }
        mapped[i/page] = (physical + UInt64(i)) | 0x783 | (1 << 54) | (1 << (rx ? 50 : 51))
      }
    }
    #expect(cleaned == expectedClean)
    for i in mapped.indices {
      let va = chosen + UInt64(i * page)
      var start = 0, leaf: UInt64 = 0
      for level in 0..<4 {
        leaf = ram.load(fromByteOffset: start + 8 * Int(armWalkIndex(va, level: UInt8(level))), as: UInt64.self)
        if leaf == 0 || level == 3 { break }
        guard leaf >= pa + 3, leaf - pa - 3 < UInt64(W1ColdHostPages.tableBytes)
        else { Issue.record("descriptor outside host tables"); return }
        start = Int(leaf - pa - 3)
      }
      #expect(leaf == mapped[i])
    }
  }
}
