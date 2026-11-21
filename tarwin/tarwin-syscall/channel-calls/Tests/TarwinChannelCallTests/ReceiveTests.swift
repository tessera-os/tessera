import TarwinABI
import TarwinChannelCalls
import TarwinIPCChannels
import TarwinObject
import TarwinSyscall
import XCTest

private final class PairOwner: ChannelNamespace {
  let heads = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 4)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 8)
  let lengths = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
  let payload = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 8)
  let grants = UnsafeMutableBufferPointer<ObjectGrant>.allocate(capacity: 128)
  var pair: ChannelPair, table: HandleTable
  init() {
    let ids = KoidSource()
    for i in 0..<4 {
      (heads + i).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: 1,
          kind: i == 3 ? TarwinKind.port : TarwinKind.channel, maximumRights: 7)!)
    }
    lengths.initialize(repeating: .init())
    table = HandleTable(storage: cells, salt: 4)!
    let lengths = self.lengths
    let payload = self.payload
    let grants = self.grants
    func fifo(_ i: Int) -> ChannelQueue {
      ChannelQueue(
        lengths: .init(rebasing: lengths[i...i]),
        bytes: .init(rebasing: payload[(8 * i)..<(8 * i + 8)]),
        grants: .init(start: grants.baseAddress! + 64 * i, count: 64))!
    }
    pair = ChannelPair(a: .init(heads), b: .init(heads + 1), toA: fifo(0), toB: fifo(1))!
  }
  deinit {
    pair.close(.a) { _ in XCTFail() }
    pair.close(.b) { _ in XCTFail() }
    table.drain { _ in XCTFail() }
    for i in 0..<4 { XCTAssertEqual((heads + i).pointee.release(), .destroy) }
    cells.deinitialize()
    cells.deallocate()
    heads.deinitialize(count: 4)
    heads.deallocate()
    lengths.deinitialize()
    lengths.deallocate()
    payload.deallocate()
    grants.deallocate()
  }
  func install(_ index: Int, rights: UInt64) -> UInt64 {
    guard case .installed(let name) = table.install(.init(heads + index), rights: rights)
    else {
      XCTFail()
      return 0
    }
    return name
  }
  func withPair(named: UInt64, _ body: (inout ChannelPair, inout HandleTable) -> CallResult)
    -> CallResult
  {
    body(&pair, &table)
  }
}

private final class Output: ChannelUserOutput {
  let userRange: Range<UInt64> = 8..<0x3000
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 8)
  let names = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 1)
  var calls = 0, permit = true
  init() { names.initialize(repeating: 0) }
  deinit {
    bytes.deallocate()
    names.deinitialize()
    names.deallocate()
  }
  func withWritable(
    bytes b: Range<UInt64>, names h: Range<UInt64>,
    _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>) -> CallResult
  ) -> CallResult? {
    calls += 1
    guard permit,
      b.isEmpty || b.lowerBound == 0x1000 && b.count <= bytes.count,
      h.isEmpty || h == 0x2000..<0x2008
    else { return nil }
    return body(.init(rebasing: bytes.prefix(b.count)), .init(rebasing: names.prefix(h.count / 8)))
  }
}

final class ReceiveTests: XCTestCase {
  func testReadAuthorityAndPeekState() {
    let owner = PairOwner()
    let memory = Output()
    var calls = ChannelReceiveCalls(space: owner, memory: memory)
    func peek(_ name: UInt64) -> UInt32 {
      [name].withUnsafeBufferPointer {
        calls.invoke(number: TarwinCall.channelPeek, words: $0).code
      }
    }
    XCTAssertEqual(peek(0), 2)
    XCTAssertEqual(peek(owner.install(3, rights: 4)), 3)
    XCTAssertEqual(peek(owner.install(1, rights: 2)), 4)
    XCTAssertEqual(peek(owner.install(2, rights: 4)), 2)
    let name = owner.install(1, rights: 4)
    XCTAssertEqual(peek(name), 24)
    owner.pair.close(.a) { _ in XCTFail() }
    XCTAssertEqual(peek(name), 27)
    XCTAssertTrue(owner.table.close(name) { _ in XCTFail() })
    XCTAssertEqual(peek(name), 2)
    XCTAssertEqual(memory.calls, 0)
  }

  func testFaultAndSmallOutputsLeaveMessageAndGrantQueued() {
    let owner = PairOwner()
    let memory = Output()
    let channel = owner.install(1, rights: 4)
    let grant = owner.install(3, rights: 6)
    let sent = [UInt8(3), 7].withUnsafeBytes { data in
      [grant].withUnsafeBufferPointer { handles in
        owner.pair.send(
          from: .a, data, names: handles, table: &owner.table,
          invalidate: { XCTAssertEqual($0, grant) }, retire: { _ in XCTFail() })
      }
    }
    XCTAssertEqual(sent, .ok)
    owner.pair.close(.a) { _ in XCTFail() }
    var calls = ChannelReceiveCalls(space: owner, memory: memory)
    func read(_ b: UInt64, _ n: UInt64, _ h: UInt64, _ k: UInt64) -> CallResult {
      [channel, b, n, h, k].withUnsafeBufferPointer {
        calls.invoke(number: TarwinCall.channelRead, words: $0)
      }
    }
    XCTAssertEqual(read(.max, 3, 0, 0).code, 1)
    XCTAssertEqual(read(0, 3, 0, 0).code, 1)
    XCTAssertEqual(read(0x1000, 3, 0x2001, 1).code, 1)
    XCTAssertEqual(read(0x1000, 8, 0x1000, 1).code, 1)
    XCTAssertEqual(memory.calls, 0)
    memory.permit = false
    XCTAssertEqual(read(0x1000, 8, 0x2000, 1).code, 1)
    memory.permit = true
    let small = read(0x1000, 1, 0, 0)
    XCTAssertEqual(small.code, 7)
    XCTAssertEqual(small.detail, 2)
    XCTAssertEqual(owner.table.count, 1)
    XCTAssertEqual(memory.names[0], 0)
    let peek = [channel].withUnsafeBufferPointer {
      calls.invoke(number: TarwinCall.channelPeek, words: $0)
    }
    XCTAssertEqual(peek.status, 0)
    XCTAssertEqual(peek.first, 2)
    XCTAssertEqual(peek.second, 1)
    let got = read(0x1000, 8, 0x2000, 1)
    XCTAssertEqual(got.status, 0)
    XCTAssertEqual(got.first, peek.first)
    XCTAssertEqual(got.second, peek.second)
    XCTAssertEqual(Array(memory.bytes.prefix(2)), [3, 7])
    XCTAssertNotEqual(memory.names[0], grant)
    guard
      case .found(let pin) = owner.table.reader.pinWithinEpoch(
        memory.names[0], kind: TarwinKind.port, need: 6)
    else { return XCTFail() }
    XCTAssertEqual(pin.header, .init(owner.heads + 3))
    pin.drop { _ in XCTFail() }
    XCTAssertEqual(read(0, 0, 0, 0).code, 27)
  }
}
