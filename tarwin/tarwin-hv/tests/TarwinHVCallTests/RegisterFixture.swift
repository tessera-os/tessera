import TarwinABI
import TarwinHV
import TarwinHVCalls
import TarwinObject
import TarwinSyscall

enum RegisterEvent { case lookup, pinInput, pinOutput, read, lock, unlock, write, unpin }

// One test mapping split across two pages. VA 0x1ff8 is the final word
// of page one. Both the mapping and register bank are test-owned storage.
struct RegisterFixture: RegisterCallContext {
  let table: UnsafeMutablePointer<HandleTable>
  let cpu: UnsafePointer<ObjectHeader>
  let bank: GuestIntegerRegisters
  let memory: UnsafeMutableBufferPointer<UInt64>
  var state = VirtualCpuState(creator: 7)
  var userRange: Range<UInt64> = 0x1000..<0x3000
  var readable = true, writable = true, secondPage = true, runAtPin = false
  var revokeAtPin: UInt64 = 0
  #if !hasFeature(Embedded)
    var events: [RegisterEvent] = []
  #endif
  var retired = 0
  private mutating func event(_ id: RegisterEvent) {
    #if !hasFeature(Embedded)
      events.append(id)
    #endif
  }

  mutating func inCallerEpoch(_ lookup: (HandleReadView) -> PinResult) -> PinResult {
    event(.lookup)
    return lookup(table.pointee.reader)
  }
  mutating func retire(_ object: UnsafePointer<ObjectHeader>) {
    precondition(object == cpu)
    retired += 1
  }
  func integerCount(of object: UnsafePointer<ObjectHeader>) -> Int? {
    object == cpu ? bank.count : nil
  }
  mutating func withStateLocked(
    _ object: UnsafePointer<ObjectHeader>,
    _ body: (VirtualCpuState, GuestIntegerRegisters) -> HvError
  ) -> HvError {
    precondition(object == cpu)
    event(.lock)
    let result = body(state, bank)
    event(.unlock)
    return result
  }
  mutating func pinWords(at address: UInt64, count: Int, access: RegisterBufferAccess) -> Int? {
    event(access == .readFromCaller ? .pinInput : .pinOutput)
    guard address == 0x1ff8, count <= memory.count, secondPage,
      access == .readFromCaller ? readable : writable
    else { return nil }
    if runAtPin { _ = state.begin(7) }
    if revokeAtPin != 0 {
      let closed = table.pointee.close(revokeAtPin) { _ in preconditionFailure("lost vCPU pin") }
      precondition(closed)
      revokeAtPin = 0
    }
    return count
  }
  mutating func read(_ pin: Int, into words: UnsafeMutableBufferPointer<UInt64>) {
    precondition(pin == words.count)
    event(.read)
    for i in words.indices { words[i] = memory[i] }
  }
  mutating func write(_ pin: Int, from words: UnsafeBufferPointer<UInt64>) {
    precondition(pin == words.count)
    event(.write)
    for i in words.indices { memory[i] = words[i] }
  }
  mutating func unpin(_ pin: Int) { event(.unpin) }
}

#if hasFeature(Embedded)
  // Force concrete specialization of the provider, dispatcher, and fixture
  // under -no-allocations. These are harness-owned pointers, not user VAs.
  @_cdecl("tarwin_check_integer_call")
  func checkIntegerCall(_ fixture: UnsafeMutableRawPointer, _ name: UInt64, _ number: UInt64)
    -> UInt64
  {
    let f = fixture.assumingMemoryBound(to: RegisterFixture.self)
    var p = IntegerRegisterCalls(f.pointee)
    return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 4) { args in
      let d = dispatchCall(
        isa: .aarch64, savedPC: 0x8004, libraryCode: 0x8000..<0x9000,
        userRange: p.context.userRange, number: number,
        registers: CallRegisters(name, 0, 0x1ff8, UInt64(p.context.bank.count)), scratch: args,
        provider: &p)
      if case .returned(let r) = d { return r.status }
      return UInt64.max
    }
  }
#endif
