import Foundation
import Darwin

public enum DiskError: Error { case invalidHeader, io(String) }
public struct DiskImage {
    public static let defaultSize: Int64 = 64 * 1024 * 1024 * 1024
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessera/Disks/system.trfsdisk")
    }
    public let url: URL
    public let uuid: UUID
    public let created: Date
    public static func create(at url: URL, size: Int64 = defaultSize) throws -> DiskImage {
        guard size >= 8192 else { throw DiskError.invalidHeader }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw DiskError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard ftruncate(fd, size) == 0 else { throw DiskError.io("ftruncate failed") }
        let uuid = UUID(), created = Date()
        let header = "TRFSDISK\n1\n\(uuid.uuidString)\n\(created.timeIntervalSince1970)\n"
        var block = Data(header.utf8); block.append(Data(count: 4096 - block.count))
        let count = block.withUnsafeBytes { pwrite(fd, $0.baseAddress!, $0.count, 0) }
        guard count == 4096, fcntl(fd, F_FULLFSYNC) == 0 else { throw DiskError.io("header flush failed") }
        return DiskImage(url: url, uuid: uuid, created: created)
    }
    public static func open(at url: URL) throws -> DiskImage {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 4096) ?? Data()
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard data.count == 4096, fields.count >= 4, fields[0] == "TRFSDISK", fields[1] == "1",
              let uuid = UUID(uuidString: String(fields[2])), let date = Double(fields[3]), date.isFinite,
              (try file.seekToEnd()) >= 8192 else { throw DiskError.invalidHeader }
        return DiskImage(url: url, uuid: uuid, created: Date(timeIntervalSince1970: date))
    }
    public func incrementBootCount() throws -> UInt64 {
        let file = try FileHandle(forUpdating: url); defer { try? file.close() }
        try file.seek(toOffset: 4096)
        let data = try file.read(upToCount: 8) ?? Data()
        let old = data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        let next = old &+ 1
        try file.seek(toOffset: 4096)
        try file.write(contentsOf: Data((0..<8).map { UInt8(truncatingIfNeeded: next >> ($0 * 8)) }))
        guard fcntl(file.fileDescriptor, F_FULLFSYNC) == 0 else { throw DiskError.io("boot counter flush failed") }
        return next
    }
}
public enum SystemImage {
    public static func locate(in bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "system", withExtension: "timg") else {
            throw DiskError.io("Missing bundled system.timg")
        }
        return url
    }
}
