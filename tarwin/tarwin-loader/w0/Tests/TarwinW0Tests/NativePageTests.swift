import TarwinLoader
import TarwinW0Verify
import XCTest

/// Exercise every RX page of the actual authenticated kernel, not a second
/// ELF-shaped fixture. A changed cache or frame must not pass on page-in.
func checkExecutablePages(_ kernel: W0Kernel, machine: UInt16) throws {
  let k = kernel.bytes
  let size = imagePage(machine)
  let empty = BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0)
  let count = try XCTUnwrap(NativePageIndex.capacity(fileBytes: k.count))
  var nodes = Array(repeating: empty, count: count)
  func build(_ buffer: UnsafeMutableBufferPointer<BlakeCv>) -> NativePageIndex? {
    NativePageIndex(file: k, image: kernel.image, storage: buffer)
  }
  let index = try nodes.withUnsafeMutableBufferPointer { b in
    XCTAssertNil(build(UnsafeMutableBufferPointer(rebasing: b.dropLast())))
    return try XCTUnwrap(build(b))
  }
  var output = [UInt8](repeating: 0, count: 16 * 54 * 32)
  func emit(_ offset: UInt64, _ length: Int) -> Int? {
    nodes.withUnsafeBufferPointer { n in
      output.withUnsafeMutableBytes {
        index.witnesses(
          offset: offset, pageSize: size, nodes: n,
          into: UnsafeMutableRawBufferPointer(rebasing: $0.prefix(length)))
      }
    }
  }
  let capacity = output.count
  XCTAssertNil(emit(1, capacity))
  XCTAssertNil(emit(UInt64.max - size + 1, capacity))
  XCTAssertNil(emit(UInt64(k.count) / size * size, capacity))
  var pages = 0
  for at in stride(
    from: kernel.image.programHeaders.lowerBound, to: kernel.image.programHeaders.upperBound, by: 56
  ) {
    func u32(_ p: Int) -> UInt32 {
      UInt32(littleEndian: k.loadUnaligned(fromByteOffset: at + p, as: UInt32.self))
    }
    func u64(_ p: Int) -> UInt64 {
      UInt64(littleEndian: k.loadUnaligned(fromByteOffset: at + p, as: UInt64.self))
    }
    guard u32(0) == 1, u32(4) == 5 else { continue }
    let start = u64(8)
    let end = start + u64(32)
    for offset in stride(from: start, to: end, by: Int(size)) {
      pages += 1
      let used = try XCTUnwrap(emit(offset, capacity))
      XCTAssertGreaterThan(used, 0)
      XCTAssertNil(emit(offset, used - 1))
      XCTAssertEqual(emit(offset, used), used)
      var frame = Array(k[Int(offset)..<Int(offset + size)])
      func verify() -> Bool {
        frame.withUnsafeBufferPointer { f in
          output.withUnsafeBufferPointer {
            verifyFilePage(
              f, UnsafeBufferPointer(rebasing: $0.prefix(used)), index.canonicalSize, offset, size,
              index.root)
          }
        }
      }
      XCTAssertTrue(verify())
      frame[0] ^= 1
      XCTAssertFalse(verify())
      frame[0] ^= 1
      output[used - 1] ^= 1
      XCTAssertFalse(verify())
      // First sibling for the first leaf on this aligned page.
      let j = Int(offset / 1024) ^ 1
      let original = nodes[j]
      nodes[j] = empty
      XCTAssertEqual(emit(offset, capacity), used)
      XCTAssertFalse(verify())
      nodes[j] = original
    }
  }
  XCTAssertGreaterThan(pages, 0)
}
