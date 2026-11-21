import XCTest

@testable import TarwinLoader

func checkPinned(_ root: BlakeCv, _ left: BlakeCv) -> Bool {
  var frame = [UInt8](repeating: 0, count: 4096)
  frame[0] = UInt8(4096 % 251)
  let words = [left.w0, left.w1, left.w2, left.w3, left.w4, left.w5, left.w6, left.w7]
  var proof = words.flatMap { word in
    (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
  }
  func verifies(_ frame: [UInt8], _ proof: [UInt8]) -> Bool {
    frame.withUnsafeBufferPointer { bytes in
      proof.withUnsafeBufferPointer { verifyFilePage(bytes, $0, 4097, 4096, 4096, root) }
    }
  }
  guard verifies(frame, proof) else { return false }
  frame[1] = 1
  guard !verifies(frame, proof) else { return false }
  frame[1] = 0
  guard !verifies(frame, []), !verifies(frame, proof + proof) else { return false }
  proof[0] ^= 1
  return !verifies(frame, proof)
}
