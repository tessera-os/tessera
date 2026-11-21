import Tarboot

@_extern(c, "q35_gen_note") private func note(_ byte: UInt8)
@_extern(c, "q35_gen_word") private func word(_ address: UInt64) -> UInt64

func reportQ35Generation(_ tables: FirmwareTableLocations, _ map: UnsafeBufferPointer<FirmwareRegion>) {
  guard let page = q35GenerationPage(tables, in: map),
    let id = page.sample(readWord: { word($0) }) else { note(0); return }
  note(1)
  for i in 0..<16 {
    note(UInt8(truncatingIfNeeded: (i < 8 ? id.0 : id.1) >> ((i & 7) * 8)))
  }
}
