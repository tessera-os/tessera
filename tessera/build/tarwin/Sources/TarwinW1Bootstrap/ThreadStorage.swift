import TarwinArchAarch64
import TarwinKernelRandom
import TarwinRandomCore

/// One placement in an otherwise empty ordinary region of a fresh address
/// space. Not for later threads: their existing reservations must be counted.
public struct W1ThreadPlacement: ~Copyable {
  public let stack, shadow: Range<UInt64>
  public let tcb: UInt64
  fileprivate let protector: UInt64

  /// Hold the serialized kernel RNG and provide the current trusted epoch.
  public init?(stackBytes: UInt64, random: inout KernelRandom, generation: () -> RandomEpoch?) {
    guard
      let selected = Self(stackBytes: stackBytes, draw: { random.word(generation: generation()) })
    else { return nil }
    self = selected
  }

  init?(stackBytes: UInt64, draw: () -> UInt64?) {
    let lo: UInt64 = 1 << 43
    let hi: UInt64 = 1 << 46
    let page: UInt64 = 16384
    guard stackBytes >= page, stackBytes <= hi - lo, stackBytes % page == 0 else { return nil }
    let shadowBytes = max(page, ((stackBytes / 8 + page - 1) / page) * page)
    // Four guard pages below the stack; then stack, guard, TCB, guard,
    // shadow stack, guard. Only the whole reservation can be selected.
    let span = 8 * page + stackBytes + shadowBytes
    guard span <= hi - lo else { return nil }
    let count = (hi - lo - span) / page + 1
    guard count >= 1 << 30 else { return nil }
    for _ in 0..<64 {
      guard let word = draw() else { return nil }
      if word < (0 &- count) % count { continue }
      guard let guardWord = draw(), guardWord != 0 else { return nil }
      let start = lo + (word % count) * page + 4 * page
      stack = start..<start + stackBytes
      tcb = stack.upperBound + page
      shadow = (tcb + 2 * page)..<(tcb + 2 * page + shadowBytes)
      protector = guardWord
      return
    }
    return nil
  }
}

/// The stack/TCB are mapped. Shadow frames are zeroed and reserved:
/// unmapped under direct permissions, GCS pages under W1 indirection.
/// This does not enable GCS or install a thread's GCSPR.
public struct W1ThreadStorage {
  public let stack, shadow: Range<UInt64>
  public let tcb, stackPhysical, shadowPhysical: UInt64
}

extension W1FramePool {
  mutating func stageThread(_ t: borrowing W1ThreadPlacement, tables: inout ArmUserTranslation)
    -> W1ThreadStorage?
  {
    let page = 16384
    let stackBytes = Int(t.stack.upperBound - t.stack.lowerBound)
    let shadowBytes = Int(t.shadow.upperBound - t.shadow.lowerBound)
    let bytes = stackBytes + page + shadowBytes
    guard bytes <= memory.count - used else { return nil }
    let start = used
    memory[start..<start + bytes].initializeMemory(as: UInt8.self, repeating: 0)
    for i in stride(from: 0, to: stackBytes, by: page) {
      guard
        tables.insert(
          virtual: t.stack.lowerBound + UInt64(i), physical: physical + UInt64(start + i),
          write: true, execute: false)
      else { return nil }
    }
    let block = start + stackBytes
    guard
      tables.insert(virtual: t.tcb, physical: physical + UInt64(block), write: true, execute: false)
    else { return nil }
    // TVISA §19.1. This W1 subset has no TLS templates or runtime state yet.
    let ptr = memory.baseAddress! + block
    ptr.storeBytes(of: t.tcb.littleEndian, as: UInt64.self)
    ptr.storeBytes(of: t.protector.littleEndian, toByteOffset: 8, as: UInt64.self)
    ptr.storeBytes(of: t.stack.lowerBound.littleEndian, toByteOffset: 16, as: UInt64.self)
    ptr.storeBytes(of: t.shadow.lowerBound.littleEndian, toByteOffset: 40, as: UInt64.self)
    if tables.layout == .guarded {
      for i in stride(from: 0, to: shadowBytes, by: page) {
        guard tables.insertControlPage(
          virtual: t.shadow.lowerBound + UInt64(i), physical: physical + UInt64(block + page + i))
        else { return nil }
      }
    }
    used += bytes
    return W1ThreadStorage(
      stack: t.stack, shadow: t.shadow, tcb: t.tcb, stackPhysical: physical + UInt64(start),
      shadowPhysical: physical + UInt64(block + page))
  }
}
