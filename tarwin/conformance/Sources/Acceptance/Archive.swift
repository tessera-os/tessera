import Foundation

extension Reference {
  var row: String {
    if target == .qemu { return ["qemu", arch, serial, tarwin].joined(separator: "\t") }
    return
      ([
        "physical", arch, serial, tarwin, linux, battery ? "yes" : "no",
        nested ? "yes" : "no", confidential ? "yes" : "no",
      ] + (backend.map { [$0] } ?? [])
      + (storage.map {
        ["storage=" + ($0.isEmpty ? "none" : $0.joined(separator: ","))]
      } ?? [])).joined(separator: "\t")
  }
}

// The controller owns this metadata. A read-only archive is still required:
// unkeyed hashes detect changed captures, not an operator replacing a whole run.
func archiveID(_ root: String, _ refs: [Reference], create: Bool) -> UUID? {
  let dir = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
  let url = dir.appendingPathComponent("collection.tsv")
  let manifest = refs.map(\.row).sorted().joined(separator: "\n") + "\n"
  if create {
    let id = UUID()
    let data = Data((id.uuidString + "\n" + manifest).utf8)
    guard (try? data.write(to: url, options: .withoutOverwriting)) != nil else { return nil }
    return id
  }
  guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
    let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
    info.isRegularFile == true, info.fileSize == 37 + manifest.utf8.count,
    let text = try? String(contentsOf: url, encoding: .utf8),
    let id = UUID(uuidString: String(text.prefix(36))),
    text == id.uuidString + "\n" + manifest
  else { return nil }
  return id
}

func captureHashes(_ root: String, _ ref: Reference, _ plan: [Sample]) -> Data? {
  let dir = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
    .appendingPathComponent(ref.serial)
  let paths = plan.flatMap { [$0.stem + ".tsv", $0.stem + ".log"] }
  for path in paths {
    guard captureExists(dir.appendingPathComponent(path)) else { return nil }
  }
  let child = Process()
  #if os(macOS)
    child.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    child.arguments = ["-a", "256", "-b", "--"] + paths
  #else
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
    child.arguments = ["-b", "--"] + paths
  #endif
  child.currentDirectoryURL = dir
  child.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
  child.standardInput = FileHandle.nullDevice
  let out = Pipe()
  child.standardOutput = out
  guard (try? child.run()) != nil else { return nil }
  let data = out.fileHandleForReading.readDataToEndOfFile()
  child.waitUntilExit()
  guard child.terminationReason == .exit, child.terminationStatus == 0,
    let text = String(data: data, encoding: .utf8)
  else { return nil }
  let lines = text.split(separator: "\n")
  guard lines.count == paths.count else { return nil }
  for (line, path) in zip(lines, paths) {
    guard line.count == 66 + path.count, line.hasSuffix(" *" + path),
      line.prefix(64).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
  }
  return data
}
