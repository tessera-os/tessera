import Tarboot
import TarwinBoot

@_extern(c, "tarwin_mmio_read32") private func read32(_ p: UnsafeRawPointer) -> UInt32
@_extern(c, "tarwin_mmio_write32") private func write32(_ p: UnsafeRawPointer, _ v: UInt32)

func readFixedClaim() -> DebugQEMUFixedGeneration? {
  var port = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
  return readFixedQEMUDebugClaim(&port)
}

func uartByte(_ byte: UInt8) -> Bool {
  let uart = UnsafeRawPointer(bitPattern: 0x0900_0000)!
  for _ in 0..<500000 where read32(uart + 0x18) & 0x20 == 0 {
    write32(uart, UInt32(byte))
    return true
  }
  return false
}

func reportFixedMarker(_ label: StaticString) -> Bool {
  for i in 0..<label.utf8CodeUnitCount where !uartByte(label.utf8Start[i]) { return false }
  return true
}

func reportFixedClaim(_ id: DebugQEMUFixedGeneration) -> Bool {
  guard reportFixedMarker("TARWIN-DEBUG-FIXED-TBIB=") else { return false }
  for i in 0..<16 {
    let b = UInt8(truncatingIfNeeded: (i < 8 ? id.low : id.high) >> ((i % 8) * 8))
    for k in 0..<2 {
      let n = k == 0 ? b >> 4 : b & 15
      guard uartByte(n < 10 ? 48+n : 87+n) else { return false }
    }
  }
  return uartByte(13) && uartByte(10)
}
