import TarwinSyscall
import Testing

@testable import TarwinHV

@Test func stoppedIntegerTransfersTouchOnlyArchitecturalSlots() {
  let get = TarwinCall.virtualCpuGetRegisters
  let set = TarwinCall.virtualCpuSetRegisters
  for isa in 0..<3 {
    let original = (0..<40).map { 0xcafe_0000 + UInt64($0) }
    var storage = original
    storage.withUnsafeMutableBufferPointer { bank in
      let p = bank.baseAddress!
      let regs: GuestIntegerRegisters
      let slots: [Int?]
      switch isa {
      case 0:
        regs = .arm64(x0Through30: .init(rebasing: bank[..<31]), spEL1: p + 36)!
        slots = Array(0..<31) + [36]
      case 1:
        regs = .rv64(x0Through31: .init(rebasing: bank[..<32]))!
        slots = [nil] + Array(1..<32).map { Optional($0) }
      default:
        regs = .x64(spills: .init(rebasing: bank[..<14]), rax: p + 20, rsp: p + 22)!
        slots = [20, 1, 2, 0, 22, 5, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13]
      }
      var transfer = Array(repeating: UInt64.max, count: slots.count)
      transfer.withUnsafeMutableBufferPointer { words in
        var cpu = VirtualCpuState(creator: 1)
        #expect(regs.transfer(get, cpu: cpu, words: words) == .ok)
        #expect(Array(words) == slots.map { $0.map { original[$0] } ?? 0 })
        let values = slots.indices.map { UInt64($0) << 49 }
        for i in words.indices { words[i] = values[i] }
        #expect(regs.transfer(TarwinCall.virtualCpuRun, cpu: cpu, words: words) == .invalid)
        for n in [get, set] {
          #expect(regs.transfer(n, cpu: cpu, words: .init(rebasing: words.dropLast())) == .invalid)
        }
        #expect(cpu.begin(1) == .enter)
        #expect(regs.transfer(get, cpu: cpu, words: words) == .busy)
        #expect(regs.transfer(set, cpu: cpu, words: words) == .busy)
        #expect(Array(words) == values)
        _ = cpu.finish(.hypercall)
        if isa == 1 {
          words[0] = 1
          #expect(regs.transfer(set, cpu: cpu, words: words) == .invalid)
          words[0] = 0
        }
        #expect(Array(bank) == original)
        #expect(regs.transfer(set, cpu: cpu, words: words) == .ok)
        var expected = original
        for (i, slot) in slots.enumerated() { if let slot { expected[slot] = values[i] } }
        #expect(Array(bank) == expected)
      }
    }
  }
}
