public func enumerateEcam(_ firstBus: UInt32, _ lastBus: UInt32, _ read32: (UInt32) -> UInt32)
  -> [PciFunction]
{
  var found: [PciFunction] = []
  var scratch = PciWalkScratch()
  _ = visitEcam(firstBus, lastBus, scratch: &scratch, read32: read32) {
    found.append($0)
    return true
  }
  return found
}
