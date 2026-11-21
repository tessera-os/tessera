#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  typealias HandleProtocol =
    @convention(c) (
      UnsafeRawPointer, UnsafeRawPointer,
      UnsafeMutablePointer<UnsafeRawPointer?>
    ) -> UInt
  private typealias OpenVolume =
    @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>) -> UInt
  private typealias OpenFile =
    @convention(c) (
      UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>,
      UnsafePointer<UInt16>, UInt64, UInt64
    ) -> UInt
  private typealias CloseFile = @convention(c) (UnsafeRawPointer) -> UInt
  private typealias Position = @convention(c) (UnsafeRawPointer, UInt64) -> UInt
  private typealias Tell = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> UInt
  private typealias Read =
    @convention(c) (
      UnsafeRawPointer, UnsafeMutablePointer<UInt>,
      UnsafeMutableRawPointer
    ) -> UInt

  // Boot policy supplies an absolute, terminated path on the image's own volume.
  // Reject aliases for the root/parent/current directory; never search other devices.
  func absoluteFilePath(_ path: UnsafeBufferPointer<UInt16>) -> Bool {
    guard path.count >= 3, path[0] == 92, path[path.count - 1] == 0 else { return false }
    var start = 1
    for i in 1..<path.count {
      let ch = path[i]
      if ch == 0 && i != path.count - 1 { return false }
      if ch == 47 || ch == 58 { return false }
      if ch == 0 || ch == 92 {
        let n = i - start
        if n == 0 || (path[start] == 46 && (n == 1 || (n == 2 && path[start + 1] == 46))) {
          return false
        }
        start = i + 1
      }
    }
    return true
  }

  private func lookup(
    _ protocolFor: HandleProtocol, _ handle: UnsafeRawPointer, _ lo: UInt64, _ hi: UInt64
  ) -> UnsafeRawPointer? {
    var guid = (lo.littleEndian, hi.littleEndian)
    var result: UnsafeRawPointer?
    let status = withUnsafeBytes(of: &guid) { protocolFor(handle, $0.baseAddress!, &result) }
    return status == 0 ? result : nil
  }

  // All function tables here are supplied by the active EFI firmware. Local file
  // handles cannot outlive the operation; 'output' is exclusive loader storage.
  func readImageFile(
    _ image: UnsafeRawPointer, protocolFor: HandleProtocol,
    path: UnsafeBufferPointer<UInt16>, into output: UnsafeMutableRawBufferPointer
  ) -> Int? {
    guard absoluteFilePath(path), let filename = path.baseAddress, output.count > 0,
      let loaded = lookup(protocolFor, image, 0x11d2_9562_5b1b_31a1, 0x3b72_69c9_a000_3f8e),
      loaded.load(as: UInt32.self) >= 0x1000,
      let device = loaded.load(fromByteOffset: 24, as: UnsafeRawPointer?.self),
      let fs = lookup(protocolFor, device, 0x11d2_6459_964e_5b22, 0x3b72_69c9_a000_398e),
      fs.load(as: UInt64.self) >= 0x10000,
      let volume = fs.load(fromByteOffset: 8, as: OpenVolume?.self)
    else { return nil }
    var root: UnsafeRawPointer?
    guard volume(fs, &root) == 0, let root,
      let closeRoot = root.load(fromByteOffset: 16, as: CloseFile?.self)
    else { return nil }
    let result = readAtRoot(root, filename: filename, into: output)
    return closeRoot(root) == 0 ? result : nil
  }

  private func readAtRoot(
    _ root: UnsafeRawPointer, filename: UnsafePointer<UInt16>,
    into output: UnsafeMutableRawBufferPointer
  ) -> Int? {
    guard root.load(as: UInt64.self) >= 0x10000,
      let open = root.load(fromByteOffset: 8, as: OpenFile?.self)
    else { return nil }
    var file: UnsafeRawPointer?
    guard open(root, &file, filename, 1, 0) == 0, let file,
      let close = file.load(fromByteOffset: 16, as: CloseFile?.self)
    else { return nil }
    let size = readRegular(file, into: output)
    return close(file) == 0 ? size : nil
  }

  func readRegular(_ file: UnsafeRawPointer, into output: UnsafeMutableRawBufferPointer) -> Int? {
    guard file.load(as: UInt64.self) >= 0x10000, let base = output.baseAddress,
      let read = file.load(fromByteOffset: 32, as: Read?.self),
      let tell = file.load(fromByteOffset: 48, as: Tell?.self),
      let seek = file.load(fromByteOffset: 56, as: Position?.self)
    else { return nil }
    var size: UInt64 = 0
    // SetPosition(END) is defined for regular files, not directories.
    guard seek(file, .max) == 0, tell(file, &size) == 0, size > 0, size <= UInt64(output.count),
      seek(file, 0) == 0
    else { return nil }
    var offset: UInt = 0
    while offset < UInt(size) {
      let remaining = UInt(size) - offset
      var got = remaining
      guard read(file, &got, base.advanced(by: Int(offset))) == 0, got > 0, got <= remaining else {
        return nil
      }
      offset += got
    }
    var extra: UInt8 = 0
    var n: UInt = 1
    guard read(file, &n, &extra) == 0, n == 0 else { return nil }
    return Int(size)
  }
#endif
