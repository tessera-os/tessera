import TarwinABI
import TarwinHV
import TarwinHVCalls
import TarwinObject
import TarwinSyscall
import Testing

private typealias Provider = IntegerRegisterCalls<RegisterFixture>
private let get = TarwinCall.virtualCpuGetRegisters
private let set = TarwinCall.virtualCpuSetRegisters

private func withFixture(
  _ isa: CallISA = .rv64, kind: UInt32 = TarwinKind.virtualCpu,
  rights: UInt64 = 516, _ body: (inout Provider, UInt64, UnsafeMutableBufferPointer<UInt64>) -> Void
) {
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
  var table = HandleTable(storage: cells, salt: 9)!
  let header = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  header.initialize(
    to: ObjectHeader(source: KoidSource(), ownerJob: 1, kind: kind, maximumRights: rights)!)
  guard case .installed(let name) = table.install(header, rights: rights) else {
    preconditionFailure()
  }
  precondition(header.pointee.release() == .stillLive)
  defer {
    table.drain { _ in }
    #expect(header.pointee.release() == .alreadyReleased)
    header.deinitialize(count: 1)
    header.deallocate()
    cells.deinitialize()
    cells.deallocate()
  }
  var backing = Array(repeating: UInt64.max, count: 40)
  var user = Array(repeating: UInt64.max - 1, count: 33)
  backing.withUnsafeMutableBufferPointer { b in
    let bank: GuestIntegerRegisters
    switch isa {
    case .aarch64:
      bank = .arm64(x0Through30: .init(rebasing: b[..<31]), spEL1: b.baseAddress! + 35)!
    case .rv64: bank = .rv64(x0Through31: .init(rebasing: b[..<32]))!
    case .x64:
      bank = .x64(
        spills: .init(rebasing: b[..<14]), rax: b.baseAddress! + 34, rsp: b.baseAddress! + 35)!
    }
    user.withUnsafeMutableBufferPointer { u in
      withUnsafeMutablePointer(to: &table) { t in
        var provider = Provider(
          RegisterFixture(table: t, cpu: .init(header), bank: bank, memory: u))
        body(&provider, name, b)
      }
    }
  }
}

private func call(
  _ number: UInt64, _ handle: UInt64, _ p: inout Provider, selector: UInt64 = 0,
  va: UInt64 = 0x1ff8, count: UInt64? = nil, caller: CallISA = .aarch64, error: UInt32 = 0
) {
  p.context.events = []
  let r = CallRegisters(handle, selector, va, count ?? UInt64(p.context.bank.count))
  let pc: UInt64 = caller == .rv64 ? 0x8000 : 0x8000 + caller.instructionWidth
  withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 4) { scratch in
    let d = dispatchCall(
      isa: caller, savedPC: pc, libraryCode: 0x8000..<0x9000,
      userRange: p.context.userRange, number: number, registers: r, scratch: scratch, provider: &p)
    guard case .returned(let result) = d else {
      Issue.record("did not return")
      return
    }
    #expect(result.status == syscallStatus(error, 1))
    #expect(result.detail == 0 && result.first == 0 && result.second == 0)
  }
}

@Test func registerDispatchUsesGuestLayoutNotCallerLayout() {
  for guest in [CallISA.rv64, .aarch64, .x64] {
    withFixture(guest) { p, name, b in
      let slots: [Int?]
      switch guest {
      case .rv64: slots = [nil] + (1..<32).map(Optional.some)
      case .aarch64: slots = (Array(0..<31) + [35]).map(Optional.some)
      case .x64: slots = [34, 1, 2, 0, 35, 5, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13]
      }
      for caller in [CallISA.aarch64, .x64, .rv64] {
        for i in b.indices { b[i] = UInt64(i) << 49 }
        let expected = slots.map { $0.map { b[$0] } ?? 0 }
        let originalUser = Array(p.context.memory)
        p.context.readable = false
        p.context.writable = true
        call(get, name, &p, caller: caller)
        #expect(Array(p.context.memory) == expected + originalUser.dropFirst(slots.count))
        #expect(p.context.events == [.lookup, .pinOutput, .lock, .unlock, .write, .unpin])
        var expectedBank = Array(b)
        for (i, slot) in slots.enumerated() {
          p.context.memory[i] = UInt64(i) << 40
          if let slot { expectedBank[slot] = p.context.memory[i] }
        }
        p.context.readable = true
        p.context.writable = false
        call(set, name, &p, caller: caller)
        #expect(Array(b) == expectedBank)
        #expect(p.context.events == [.lookup, .pinInput, .read, .lock, .unlock, .unpin])
      }
    }
  }
}

@Test func handleErrorsPrecedeBufferAccess() {
  for number in [get, set] {
    withFixture { p, handle, _ in
      call(number, handle ^ (1 << 20), &p, selector: 2, va: 0, error: 2)
      #expect(p.context.events == [.lookup])
    }
    withFixture(kind: TarwinKind.virtualMachine) { p, handle, _ in
      call(number, handle, &p, va: 0, error: 3)
      #expect(p.context.events == [.lookup])
    }
    withFixture(rights: number == get ? 512 : 4) { p, handle, _ in
      call(number, handle, &p, error: 4)
      #expect(p.context.events == [.lookup])
    }
  }
}

@Test func refusedTransfersDoNotPublishOrPartiallyCommit() {
  withFixture { p, handle, b in
    let before = Array(b)
    let user = Array(p.context.memory)
    for number in [get, set] {
      call(number, handle, &p, selector: 1, error: 10)
      #expect(p.context.events == [.lookup])
      for count in [UInt64(0), 16, 31, 33, 256, .max] {
        call(number, handle, &p, count: count, error: 1)
        #expect(p.context.events == [.lookup])
      }
      for va in [UInt64(0), 0xff8, 0x1ff9, 0x2f08] {
        call(number, handle, &p, va: va, error: 1)
        #expect(p.context.events == [.lookup])
      }
      p.context.userRange = 0..<UInt64.max
      call(number, handle, &p, va: .max - 7, error: 1)
      #expect(p.context.events == [.lookup])
      p.context.userRange = 0x1000..<0x3000
      let pinOnly: [RegisterEvent] = [.lookup, number == get ? .pinOutput : .pinInput]
      p.context.secondPage = false
      call(number, handle, &p, error: 1)
      #expect(p.context.events == pinOnly)
      p.context.secondPage = true
      p.context.writable = number != get
      p.context.readable = number != set
      call(number, handle, &p, error: 1)
      #expect(p.context.events == pinOnly)
      p.context.writable = true
      p.context.readable = true
      p.context.runAtPin = true
      call(number, handle, &p, error: 22)
      #expect(
        p.context.events
          == (number == get
            ? [.lookup, .pinOutput, .lock, .unlock, .unpin]
            : [.lookup, .pinInput, .read, .lock, .unlock, .unpin]))
      _ = p.context.state.finish(.hypercall)
      p.context.runAtPin = false
    }
    call(set, handle, &p, error: 1)  // RV x0 in the caller buffer is nonzero.
    #expect(p.context.events == [.lookup, .pinInput, .read, .lock, .unlock, .unpin])
    #expect(Array(b) == before && Array(p.context.memory) == user)
  }
}

@Test func handleClosedAfterLookupIsRetainedThroughSnapshot() {
  withFixture(rights: 4) { p, name, _ in
    p.context.revokeAtPin = name
    call(get, name, &p)
    #expect(
      p.context.events == [.lookup, .pinOutput, .lock, .unlock, .write, .unpin]
        && p.context.retired == 1)
    call(get, name, &p, error: 2)
    #expect(p.context.events == [.lookup] && p.context.retired == 1)
  }
}

@Test func manageOnlyDoesNotNeedReadAndNeverWritesCallerMemory() {
  withFixture(.x64, rights: 512) { p, name, b in
    let before = Array(p.context.memory)
    p.context.writable = false
    call(set, name, &p)
    #expect(b[34] == before[0] && b[35] == before[4])
    #expect(Array(p.context.memory) == before)
  }
}
