import Darwin

@_silgen_name("sandbox_init")
private func installSandbox(
  _ profile: UnsafePointer<CChar>, _ flags: UInt64,
  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

enum TaskSandbox {
  static func install() -> Bool {
    let profile: StaticString = """
      (version 1)
      (deny default)
      """
    return profile.withUTF8Buffer { bytes in
      installSandbox(
        UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self), 0, nil) == 0
    }
  }
}
