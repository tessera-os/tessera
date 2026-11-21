/// Physical ABI of the pinned, low-PCI, non-restorable Arm virt-11.1
/// debug loader/kernel pair. Only the loader's actual reserved TBIB goes
/// in x0; no addresses for writable storage come from boot media.
public struct ColdKernelLayout {
  public static let pages: UInt = 28
  public static let mapBytes = 5 * 4096
  public let handoff: UInt64
  public var table: UInt64 { handoff + 6 * 4096 }
  public var commands: UInt64 { table + 4096 }
  public var signature: UInt64 { commands + 4096 }
  public var scratch: UInt64 { signature + 65536 }
  public var end: UInt64 { scratch + 16384 }

  public init?(handoff: UInt64) {
    guard handoff & 4095 == 0, handoff >= 0x4000_0000,
      handoff <= 0x6000_0000 - UInt64(Self.pages) * 4096 else { return nil }
    self.handoff = handoff
  }

  /// Call only after DMA continuity and the entire handoff/map have been
  /// checked. A signed member must still be verified on these exact bytes.
  public func containsSeparateArchive(_ base: UInt64, bytes: UInt64) -> Bool {
    bytes != 0 && base & 4095 == 0 && base >= 0x4000_0000 && base < 0x6000_0000
      && bytes <= 0x6000_0000 - base && (base >= end || base + bytes <= handoff)
  }
}
