import Foundation
import Security

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
public struct SystemImage {
    let url: URL
    let root: [UInt8]

    public static func load(from bundle: Bundle = .main) throws -> SystemImage? {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources))
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw DiskError.io("Invalid XPC service signature")
        }
        let metadata = bundle.object(forInfoDictionaryKey: "TesseraSystemRoot")
        let image = bundle.resourceURL?.appendingPathComponent("system.timg")
        let present = image.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if metadata == nil && !present { return nil }
        guard let image, present, let hex = metadata as? String, let root = decodeRoot(hex) else {
            throw DiskError.io("Bundled system image or root is missing or invalid")
        }
        return SystemImage(url: image, root: root)
    }

    static func decodeRoot(_ string: String) -> [UInt8]? {
        let hex = Array(string.utf8)
        guard hex.count == 64 else { return nil }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = digit(hex[index]), let low = digit(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }
}
