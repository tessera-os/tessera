import TarwinMM
import Testing

@Test func memoryTests() {
  #expect(pageRoundTrip())
  #expect(faultTests())
  #expect(pressureTests())
  var order: UInt8 = 0
  while order <= 6 {
    var arena = makeArena(0x100000, pageSize: 4096, usable: 0xffff_ffff_ffff_ffff)
    let size = UInt64(4096) << UInt64(order)
    var address: UInt64 = 0x100000
    while address < 0x140000 {
      let block = takePages(&arena, order: order)
      #expect(block.ok)
      #expect(block.address == address)
      address += size
    }
    #expect(!takePages(&arena, order: 0).ok)
    #expect(!(order > 0 && givePages(&arena, address: 0x100000, order: order - 1)))
    #expect(!(order < 6 && givePages(&arena, address: 0x100000, order: order + 1)))
    while address > 0x100000 {
      address -= size
      #expect(givePages(&arena, address: address, order: order))
      #expect(!givePages(&arena, address: address, order: order))
    }
    #expect(takePages(&arena, order: 6).ok)
    order += 1
  }
  var reserved = makeArena(0, pageSize: 16384, usable: 0xffff_ffff_ffff_fffe)
  #expect(!takePages(&reserved, order: 6).ok)
  #expect(takePages(&reserved, order: 0).address == 16384)
  #expect(userRegion(0, length: 4096, pageSize: 4096, userBits: 47) == 0)
  #expect(userRegion(0x1_0000_0000, length: 16384, pageSize: 16384, userBits: 47) == 1)
  #expect(userRegion(0xff_ffff_f000, length: 8192, pageSize: 4096, userBits: 47) == 0)
  #expect(userRegion(0xffff_ffff_ffff_f000, length: 4096, pageSize: 4096, userBits: 56) == 0)
  #expect(
    !permitsMapping(7, readable: true, writable: true, executable: true, code: true, sealed: false))
  #expect(
    !permitsMapping(3, readable: true, writable: true, executable: false, code: false, sealed: true)
  )
  #expect(
    !permitsMapping(5, readable: true, writable: false, executable: true, code: false, sealed: true)
  )
  #expect(
    permitsMapping(5, readable: true, writable: false, executable: true, code: true, sealed: true))
  #expect(fitsReservation(0x2000, size: 4096, reservedBase: 0x1000, reservedSize: 8192))
  #expect(!fitsReservation(0x2000, size: 4097, reservedBase: 0x1000, reservedSize: 8192))
}
