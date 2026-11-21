import Darwin

func tempDir() -> String {
  var t = Array("/tmp/h4trfs.XXXXXX".utf8CString)
  return String(cString: mkdtemp(&t))
}
func removeTree(_ path: String) {
  if let d = opendir(path) {
    while let e = readdir(d) {
      let name = withUnsafeBytes(of: e.pointee.d_name) {
        String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
      }
      if name == "." || name == ".." { continue }
      removeTree(path + "/" + name)
    }
    closedir(d)
    rmdir(path)
  } else {
    unlink(path)
  }
}
func writeFile(_ path: String, _ text: String) {
  let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  close(fd)
}
func readFile(_ path: String) -> String? {
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else { return nil }
  defer { close(fd) }
  var b = [UInt8](repeating: 0, count: 65536)
  let n = b.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
  return String(decoding: b.prefix(max(0, n)), as: UTF8.self)
}
