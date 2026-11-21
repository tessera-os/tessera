@main
enum ColdMemoryCheck {
  static func main() {
    let seed = (0..<48).map { UInt8($0 + 19) }
    for count in 0...24 {
      for dst in 0...24 {
        for value: Int32 in [-1, 0, 0x105] {
          var actual = seed, expected = seed
          for i in 0..<count { expected[dst+i] = UInt8(truncatingIfNeeded: value) }
          actual.withUnsafeMutableBytes {
            let d = $0.baseAddress! + dst
            precondition(coldSet(d, value, count) == d)
          }
          precondition(actual == expected)
        }
        for src in 0...24 {
          var actual = seed, expected = seed
          for i in 0..<count { expected[dst+i] = seed[src+i] }
          actual.withUnsafeMutableBytes {
            let d = $0.baseAddress! + dst, s = $0.baseAddress! + src
            precondition(coldMove(d, s, count) == d)
          }
          precondition(actual == expected)
          if src+count <= dst || dst+count <= src {
            actual = seed
            actual.withUnsafeMutableBytes {
              let d = $0.baseAddress! + dst, s = $0.baseAddress! + src
              precondition(coldCopy(d, s, count) == d)
            }
            precondition(actual == expected)
          }
        }
      }
    }
    print("Cold memory: aligned, misaligned, overlapping and zero-length ranges passed")
  }
}
