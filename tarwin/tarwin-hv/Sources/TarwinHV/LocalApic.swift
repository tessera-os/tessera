// Fixed-size local APIC IRR/ISR banks. TPR and the top in-service priority class
// both mask lower/equal classes; pending vectors remain latched until accepted.
public struct VectorSet {
  public internal(set) var a: UInt64 = 0
  public internal(set) var b: UInt64 = 0
  public internal(set) var c: UInt64 = 0
  public internal(set) var d: UInt64 = 0

  public init() {}

  public mutating func change(_ vector: UInt64, _ on: Bool) {
    let bit = UInt64(1) << (vector % 64)
    let clear = bit ^ 0xffff_ffff_ffff_ffff
    switch vector / 64 {
    case 0: a = on ? a | bit : a & clear
    case 1: b = on ? b | bit : b & clear
    case 2: c = on ? c | bit : c & clear
    case 3: d = on ? d | bit : d & clear
    default: break
    }
  }
  public func highest() -> UInt64 {
    var word = d
    var base: UInt64 = 192
    if word == 0 {
      word = c
      base = 128
    }
    if word == 0 {
      word = b
      base = 64
    }
    if word == 0 {
      word = a
      base = 0
    }
    if word == 0 { return 0 }
    while word > 1 {
      word = word >> 1
      base += 1
    }
    return base
  }
}

public struct LocalApic {
  public internal(set) var pending: VectorSet = VectorSet()
  public internal(set) var active: VectorSet = VectorSet()
  public internal(set) var tpr: UInt64 = 0

  public init(tpr: UInt64) {
    self.tpr = tpr
  }

  public mutating func raise(_ vector: UInt64) -> Bool {
    if vector < 16 || vector > 255 { return false }
    pending.change(vector, true)
    return true
  }
  public mutating func acknowledge() -> UInt64 {
    let v = pending.highest()
    let cls = v >> 4
    if cls <= (tpr >> 4) || cls <= (active.highest() >> 4) { return 0 }
    pending.change(v, false)
    active.change(v, true)
    return v
  }
  public mutating func endOfInterrupt() -> UInt64 {
    let v = active.highest()
    if v != 0 { active.change(v, false) }
    return v
  }
}
