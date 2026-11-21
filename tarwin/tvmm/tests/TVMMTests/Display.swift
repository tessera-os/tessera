import Testing

@testable import TVMM

func allocateImage(_ format: UInt64, _ w: UInt64, _ h: UInt64) -> UInt64 { return 17 }
func destroyImage(_ token: UInt64) -> Bool { return token == 17 }
func pinImage(_ spans: [Segment]) -> UInt64 { return 18 }
func unpinImage(_ token: UInt64) {}
func uploadImage(_ img: UInt64, _ pin: UInt64, _ offset: UInt64, _ rect: PixelRect) -> Bool {
  return img == 17 && pin == 18
}
func flushImage(_ img: UInt64, _ rect: PixelRect) -> Bool { return true }
func presentImage(_ surface: UInt64, _ img: UInt64, _ rect: PixelRect) -> Bool {
  return surface == 3 && img == 17
}
func gpuCommand(_ kind: Int, _ size: Int) -> [UInt8] {
  var bytes: [UInt8] = []
  for _ in 0..<size { bytes.append(0) }
  bytes[0] = UInt8(Int(kind) & 255)
  bytes[1] = 1
  bytes[4] = 1
  bytes[8] = 91
  return bytes
}
func responseCode(_ gpu: inout DisplayController, _ cmd: [UInt8]) -> UInt64 {
  guard
    let data = gpu.control(
      cmd, 408, GuestAperture(base: 0, length: 4096), allocateImage, destroyImage, pinImage,
      unpinImage, uploadImage, flushImage, presentImage)
  else { return 0 }
  if data.count < 24 || data[4] != 1 || data[8] != 91 { return 0 }
  return vword(data, 0, 4)
}
@Test
func guestScanoutRejectsOversizeAndUsesOnlyItsSurface() {
  var gpu = DisplayController(
    limit: 256, maxImages: 1,
    outputs: [Scanout(width: 8, height: 8, surface: 3)])
  var cmd = gpuCommand(0x101, 40)
  cmd[24] = 2
  cmd[28] = 1
  cmd[32] = 8
  cmd[36] = 9
  #expect(responseCode(&gpu, cmd) == 0x1201)
  cmd[36] = 8
  #expect(responseCode(&gpu, cmd) == 0x1100)
  var sc = gpuCommand(0x103, 48)
  sc[32] = 8
  sc[36] = 8
  sc[44] = 2
  #expect(responseCode(&gpu, sc) == 0x1100)
  sc[24] = 1
  #expect(responseCode(&gpu, sc) == 0x1205)
  sc[40] = 2
  #expect(responseCode(&gpu, sc) == 0x1202)
  var end = gpuCommand(0x102, 32)
  end[24] = 2
  #expect(responseCode(&gpu, end) == 0x1100)
  #expect(gpu.charged == 0)
}
