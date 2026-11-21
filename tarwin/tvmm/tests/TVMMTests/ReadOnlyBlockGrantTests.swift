import Testing
@testable import TVMM

@Test func blockGrantReadsOnlyTheRequestedPageAndWritesOnlyOutputs() {
  var request = [UInt8](repeating: 0, count: 8192)
  func set(_ offset: Int, _ value: UInt64) {
    for i in 0..<8 { request[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
  }
  set(0,0x0401_0001); set(8,3); set(16,1); set(24,2040); set(32,8)
  set(40,256); set(48,1); set(256,4096); set(264,4096)
  request[275] = 0xad
  var disk = [UInt8](repeating: 0xab, count: 1048576)
  for i in 0..<4096 { disk[2040*512+i] = UInt8(truncatingIfNeeded: i*31) }
  var scratch = [UInt8](repeating: 0xd9, count: 8192)
  var backend = ReadOnlyBlockGrant()
  func submit(_ bytes: inout [UInt8]) -> Bool {
    bytes.withUnsafeMutableBytes { grant in
      scratch.withUnsafeMutableBytes { workspace in
        disk.withUnsafeBytes { backend.read(grant:grant, scratch:workspace, disk:$0) }
      }
    }
  }
  for (offset,value) in [(0,2),(2,2),(3,0),(4,1),(8,0),(16,2),(24,249),(24,1),(32,7),
                        (41,2),(48,2),(52,1),(56,1),(127,1),(256,1),(265,8),(268,1)] {
    var invalid = request
    invalid[offset] = UInt8(value)
    let input = invalid, accepted = submit(&invalid)
    #expect(!accepted && invalid == input && backend.lastID == 0)
  }
  let accepted = submit(&request)
  #expect(accepted && backend.lastID == 3 && request[275] == 0xad)
  #expect(request[4096...] == disk[(2040*512)...])
  var completion = [UInt8](repeating: 0, count: 128)
  completion[0] = 1; completion[8] = 3; completion[16] = 1
  #expect(Array(request[128..<256]) == completion)
  let replay = submit(&request)
  #expect(!replay)
}
