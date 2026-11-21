import Foundation

public enum DiskError: Error { case io(String) }
public enum DiskImage {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessera/Disks/system.trfsdisk")
    }
    @discardableResult public static func prepareForBoot(at url: URL) throws -> URL? {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard files.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let legacyMagic = Data("TRFSDISK\n1\n".utf8)
        guard try file.read(upToCount: legacyMagic.count) == legacyMagic else { return nil }
        let backup = url.appendingPathExtension("legacy-" + UUID().uuidString)
        try files.moveItem(at: url, to: backup)
        return backup
    }
}
public enum SystemImage {
    public static func locate(in bundle: Bundle = .main) throws -> URL {
        guard let resources = bundle.resourceURL else { throw DiskError.io("Missing app Resources directory") }
        return resources.appendingPathComponent("system.timg")
    }
}
