import TarwinABI

/// Requires architecture variant bodies in the signed LibTessera image.
/// There is deliberately no host or Linux fallback.
public protocol NativeGate {
  var isa: CallISA { get }
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult
}

/// The register window and its optional argument block live only for the
/// synchronous entry. Asynchronous operations must capture their operands
/// separately in the kernel before this function returns.
public func nativeCall<G: NativeGate>(
  _ number: UInt64, words: UnsafeBufferPointer<UInt64>, gate: inout G
) -> CallResult {
  let capacity = gate.isa.argumentCount
  let split = words.count > capacity ? capacity - 1 : words.count
  var regs = CallRegisters()
  for i in 0..<split { regs[i] = words[i] }
  if split != words.count {
    // A nonempty borrowed UInt64 buffer covers every tail word and has
    // the alignment required by A.3. Keep the borrow across gate entry.
    regs[split] = UInt64(UInt(bitPattern: words.baseAddress!.advanced(by: split)))
  }
  return gate.enter(number: number, registers: regs)
}
