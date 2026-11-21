#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
import Tarboot
import TarwinDevice

@_extern(c, "tarwin_mmio_read8") private func load8(_ p: UnsafeRawPointer) -> UInt8
@_extern(c, "tarwin_mmio_read32") private func load32(_ p: UnsafeRawPointer) -> UInt32
@_extern(c, "tarwin_mmio_read64") private func load64(_ p: UnsafeRawPointer) -> UInt64
@_extern(c, "tarwin_mmio_write8") private func store8(_ p: UnsafeRawPointer, _ v: UInt8)
@_extern(c, "tarwin_mmio_write16") private func store16(_ p: UnsafeRawPointer, _ v: UInt16)
@_extern(c, "tarwin_mmio_write32") private func store32(_ p: UnsafeRawPointer, _ v: UInt32)
@_extern(c, "tarwin_mmio_write64") private func store64(_ p: UnsafeRawPointer, _ v: UInt64)
@_extern(c, "tarwin_publish_device_tables") private func publish()

// Only the fixed, identity-mapped early machine; an abort is terminal.
struct ColdBus: VirtBootFenceBus {
  private func pointer(_ address: UInt64) -> UnsafeRawPointer { UnsafeRawPointer(bitPattern: UInt(address))! }
  func read8(_ p: UInt64) -> UInt8? { load8(pointer(p)) }
  func read32(_ p: UInt64) -> UInt32? { load32(pointer(p)) }
  func read64(_ p: UInt64) -> UInt64? { load64(pointer(p)) }
  func write8(_ p: UInt64, _ v: UInt8) -> Bool { store8(pointer(p),v); return true }
  func write16(_ p: UInt64, _ v: UInt16) -> Bool { store16(pointer(p),v); return true }
  func write32(_ p: UInt64, _ v: UInt32) -> Bool { store32(pointer(p),v); return true }
  func write64(_ p: UInt64, _ v: UInt64) -> Bool { store64(pointer(p),v); return true }
  func publishStores() { publish() }
  func fwConfigWord(_ selector: UInt16) -> UInt32? {
    var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
    cfg.select(selector)
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(cfg.readByte()) << (8 * i) }
    return v
  }
}
#endif
