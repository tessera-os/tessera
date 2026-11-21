import TarwinABI
import TarwinArchAarch64
import TarwinIPCChannels
import TarwinObject
import Testing

@testable import TarwinW1Bootstrap

func checkPinnedReceive(
  _ images: borrowing W1PrivateImages, stack: UnsafeMutableRawBufferPointer,
  child: inout ProcessExecution, pair: inout ChannelPair, tree: borrowing JobTree
) throws {
  let prepared = images.initialThread
  let thread = try #require(prepared)
  let host: UInt64 = 0x80000
  let kva = UInt64(UInt(bitPattern: stack.baseAddress))
  let root = images.tables.physicalRoot
  let tables = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16384)
  defer { tables.deallocate() }
  let high: UInt64 = 0xffff_8000_0000_0000
  guard var k = ArmKernelTranslation(backing: tables, physical: host),
    let address = UnsafeMutableRawPointer(bitPattern: UInt(high))
  else {
    Issue.record("missing host root")
    return
  }
  let highView = UnsafeMutableRawBufferPointer(start: address, count: stack.count)
  for offset in stride(from: 0, to: stack.count, by: 16384) {
    let ok = k.insert(
      virtual: high + UInt64(offset), physical: thread.stackPhysical + UInt64(offset),
      write: true, execute: false)
    #expect(ok)
    if offset == 0 {
      let missing = W1StackOutputPins(images: images, child: child, host: k, alias: highView) == nil
      #expect(missing)
    }
  }
  // Host tests can walk synthetic upper tables but must never dereference the alias.
  guard let verified = W1StackOutputPins(images: images, child: child, host: k, alias: highView)
  else {
    Issue.record("matching upper/lower page runs rejected")
    return
  }
  let idle = verified.revoke()
  #expect(idle)
  // A second view of the first frame is not the next byte range.
  let aliased =
    W1StackOutputPins(
      images: images, child: child, hostRoot: host, alias: stack,
      hostPage: { _, pa in pa == thread.stackPhysical }) == nil
  #expect(aliased)
  guard
    let pins = W1StackOutputPins(
      images: images, child: child, hostRoot: host, alias: stack,
      hostPage: { va, pa in pa == thread.stackPhysical + (va - kva) })
  else {
    Issue.record("owned frame binding rejected")
    return
  }
  try withUnsafePointer(to: pins) { p in
    #expect(
      W1StackChannelOutput(
        pins: p, child: child, activeUserRoot: root + 16384, activeHostRoot: host) == nil)
    #expect(
      W1StackChannelOutput(
        pins: p, child: child, activeUserRoot: root, activeHostRoot: host + 16384) == nil)
    let output = W1StackChannelOutput(
      pins: p, child: child, activeUserRoot: root, activeHostRoot: host)
    var memory = try #require(output)
    let base = thread.stack.lowerBound
    let end = thread.stack.upperBound
    var called = 0
    func no(_ bytes: Range<UInt64>, _ names: Range<UInt64>) -> Bool {
      memory.withWritable(bytes: bytes, names: names) { _, _ in
        called += 1
        return CallResult()
      } == nil
    }
    #expect(no(base..<base + 9, base + 8..<base + 16))
    #expect(no(end - 8..<end + 1, 0..<0))
    #expect(no(base..<base + 1, base + 3..<base + 11))
    #expect(no(0..<0, base..<base + 520))
    #expect(no(base..<base + 65537, 0..<0))
    #expect(no(base..<base, 0..<0))
    #expect(no(0..<0, base..<base))
    #expect(no(thread.shadow, 0..<0))
    #expect(no(base - 16..<base - 8, 0..<0))
    #expect(called == 0 && pair.peek(at: .b)?.handles == 1 && pair.peek(at: .b)?.bytes == 56)
    let maxed = memory.withWritable(
      bytes: base + 1..<base + 65537, names: base + 65544..<base + 66056
    ) { b, h in
      #expect(b.count == 65536 && h.count == 64)
      return CallResult()
    }
    #expect(maxed != nil)
    let empty = memory.withWritable(bytes: 0..<0, names: 0..<0) { b, h in
      #expect(b.isEmpty && h.isEmpty)
      return CallResult(status: 7, detail: 2, first: 3, second: 4)
    }
    #expect(empty?.status == 7 && empty?.detail == 2 && empty?.first == 3 && empty?.second == 4)
    // Cross a real page at an odd byte, ending on it beside the handle span.
    let offset = 16384 - 17
    let va = base + UInt64(offset)
    var other = memory
    let result = memory.withWritable(bytes: va..<va + 56, names: va + 57..<va + 65) { b, names in
      called += 1
      #expect(b.count == 56 && names.count == 1)
      let refused =
        other.withWritable(bytes: va..<va + 1, names: 0..<0) { _, _ in
          called += 1
          return CallResult()
        } == nil
      #expect(refused)
      let drained = p.pointee.revoke()
      #expect(!drained)  // the views remain pinned through the receive
      var size = ChannelSize()
      let state = child.withHandles(tree: tree) { table in
        pair.receive(at: .b, into: b, names: names, table: &table, size: &size)
      }
      #expect(state == .ok && size.bytes == 56 && size.handles == 1)
      return CallResult(first: UInt64(size.bytes))
    }
    #expect(
      result?.first == 56
        && stack.loadUnaligned(fromByteOffset: offset, as: UInt32.self) == 0x5453_5254)
    let name = stack.load(fromByteOffset: offset + 57, as: UInt64.self)
    let count = child.withHandles(tree: tree) { $0.count }
    let closed = child.withHandles(tree: tree) { $0.close(name, retire: { _ in }) }
    #expect(name != 0 && count == 2 && closed == true)
    #expect(no(0..<0, 0..<0) && p.pointee.revoke() && called == 1)
  }
}
