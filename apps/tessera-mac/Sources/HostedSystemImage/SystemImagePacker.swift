import Foundation
import TRFS
import TRFSHosted
import TarwinBlockHosted

public enum SystemImagePacker {
    public static let initPath = "System/Init/tessera.init"
    public static let libraryPath = "System/Library/Frameworks/LibTessera.framework/LibTessera"

    public enum Failure: Error, Equatable {
        case emptyMember(String), format, write(String), root
    }

    /// Packs already-signed members. The returned digest must be authenticated
    /// separately from the image before it is supplied to the kernel.
    public static func pack(initImage: Data, libTessera: Data, to image: URL) throws -> Data {
        let members = [(initPath, initImage), (libraryPath, libTessera)]
        let pageSize = HostedBlockDevice.blockBytes
        var entries: Set<String> = []
        var blocks: UInt64 = 2
        for (path, data) in members {
            guard !data.isEmpty else { throw Failure.emptyMember(path) }
            var prefix = ""
            for component in path.split(separator: "/") {
                prefix += "/" + component
                entries.insert(prefix)
            }
            let pages = (UInt64(data.count) - 1) / UInt64(pageSize) + 1
            blocks += 3 * pages
        }
        blocks += 2 * UInt64(entries.count)

        let device = try HostedBlockDevice.create(path: image.path, blocks: blocks)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: image) } }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: pageSize, alignment: pageSize)
        defer { scratch.deallocate() }
        guard var volume = TrfsVolume(media: HostedTrfsMedia(device: device), scratch: scratch),
              volume.formatBlank() else { throw Failure.format }

        var directories: [String: UInt64] = ["": 1]
        for (path, data) in members {
            let components = path.split(separator: "/")
            var prefix = ""
            var parent: UInt64 = 1
            for component in components.dropLast() {
                prefix += "/" + component
                if let directory = directories[prefix] {
                    parent = directory
                } else {
                    guard let directory = volume.create(parent, name: Array(component.utf8), kind: .directory)
                    else { throw Failure.write(prefix) }
                    directories[prefix] = directory
                    parent = directory
                }
            }
            guard let inode = volume.create(parent, name: Array(components.last!.utf8), kind: .file)
            else { throw Failure.write(path) }
            try data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: pageSize) {
                    let page = UnsafeRawBufferPointer(rebasing: bytes[offset..<min(offset + pageSize, bytes.count)])
                    guard volume.writePage(inode, index: UInt64(offset / pageSize), bytes: page)
                    else { throw Failure.write(path) }
                }
            }
        }
        var root = Data(count: 32)
        guard let digest = volume.snapshot?.digest, root.withUnsafeMutableBytes({ digest.encode(into: $0) })
        else { throw Failure.root }
        success = true
        return root
    }
}
