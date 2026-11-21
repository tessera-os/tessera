import Testing

@testable import TVMM

func readDisk(_ offset: UInt64, _ size: UInt64) -> [UInt8] {
  var b: [UInt8] = []
  for i in 0..<Int(size) { b.append(UInt8((offset + UInt64(i)) & 255)) }
  return b
}
func writableDisk(_ offset: UInt64, _ bytes: [UInt8]) -> Bool {
  return offset == 512 && bytes.count == 512
}
func diskSync() -> Bool { return true }
func zeroLast(_ op: BlockOperation, _ r: BlockRange) -> Bool {
  return op == .writeZeroes && r.offset == 512 && r.length == 512 && r.unmap
}
func blockOutput(_ cmd: [UInt8], _ space: UInt64) -> [UInt8] {
  let config = BlockFeatures(
    capacity: 2, readOnly: false, flush: true, discard: true,
    zero: true, maxRanges: 2, maxSectors: 2, unmapZeroes: true)
  return switch executeBlock(cmd, space, config, readDisk, writableDisk, diskSync, zeroLast) {
  case .some(let b): b
  case .none: []
  }
}

@Test
func blockControllerWritesStatusAtEndAndChecksAllRangesBeforeApplying() {
  var cmd: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
  let reply = blockOutput(cmd, 513)
  #expect(reply.count == 513)
  #expect(reply[511] == 255)
  #expect(reply[512] == 0)
  cmd[8] = 2
  let failed = blockOutput(cmd, 513)
  #expect(failed[512] == 1)
  #expect(failed[511] == 0)
  cmd[0] = 13
  cmd[8] = 0
  let range: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
  for byte in range { cmd.append(byte) }
  #expect(blockOutput(cmd, 1)[0] == 0)
  cmd[24] = 2
  #expect(blockOutput(cmd, 1)[0] == 1)
  cmd[0] = 99
  #expect(blockOutput(cmd, 1)[0] == 2)
}

func frameSum(_ b: [UInt8]) -> Bool { return b.count == 15 && b[0] == 254 && b[1] == 255 }
@Test
func netChecksumAndBridgeAuthority() {
  var frame: [UInt8] = []
  for _ in 0..<27 { frame.append(0) }
  frame[0] = 1
  frame[26] = 1
  let allowed = NetPolicy(mtu: 1500, checksum: true, bridge: false, hypervisorResource: false)
  #expect(netTransmit(frame, allowed, frameSum))
  let denied = NetPolicy(mtu: 1500, checksum: true, bridge: true, hypervisorResource: false)
  #expect(!netTransmit(frame, denied, frameSum))
  frame[8] = 255
  #expect(!netTransmit(frame, allowed, frameSum))
}

func sink(_ bytes: [UInt8]) -> Bool { return bytes.count <= 10 }
@Test
func endpointAndCreditAreScopedToOneConnection() {
  var socket = GuestSocket(guestCid: 3, guestPort: 7, hostPort: 9, receiveLimit: 2)
  var packet: [UInt8] = []
  for _ in 0..<44 { packet.append(0) }
  packet[0] = 3
  packet[8] = 2
  packet[16] = 7
  packet[20] = 9
  packet[28] = 1
  packet[30] = 1
  packet[36] = 4
  #expect(socket.receive(packet, sink) == SocketAction.accept)
  #expect(socket.reserveSend(3) == true)
  #expect(socket.reserveSend(2) == false)
  packet[30] = 6
  packet[40] = 4
  #expect(socket.receive(packet, sink) == SocketAction.reject)
  packet[40] = 3
  #expect(socket.receive(packet, sink) == SocketAction.credit)
  #expect(socket.reserveSend(4) == true)
  packet[30] = 5
  packet[24] = 1
  packet.append(97)
  packet[0] = 9
  #expect(socket.receive(packet, sink) == SocketAction.reject)
  packet[0] = 3
  #expect(socket.receive(packet, sink) == SocketAction.delivered)
  #expect(socket.consumed(2) == false)
  #expect(socket.consumed(1) == true)
}
