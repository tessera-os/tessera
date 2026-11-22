import Foundation
import HostedSystemImage
import TRFSHosted
import XCTest

final class PackerTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testPinnedSystemVolumeContainsBothMembers() throws {
        let directory = try directory()
        let image = directory.appendingPathComponent("system.timg")
        let second = directory.appendingPathComponent("rebuilt.timg")
        let initImage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 / 256) })
        let library = Data((0..<4137).map { UInt8(truncatingIfNeeded: ~$0) })
        let root = try SystemImagePacker.pack(initImage: initImage, libTessera: library, to: image)
        XCTAssertEqual(root, try SystemImagePacker.pack(initImage: initImage, libTessera: library, to: second))
        XCTAssertEqual(try Data(contentsOf: image), try Data(contentsOf: second))

        var measured = false
        let disk = try root.withUnsafeBytes { bytes in
            try HostedTrfsDisk.openSystem(path: image.path, bootSetRoot: bytes) { _ in
                measured = true
                return true
            }
        }
        XCTAssertTrue(measured)
        try disk.withVolume { volume in
            let snapshot = try XCTUnwrap(volume.snapshot)
            let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
            defer { page.deallocate() }
            for (path, expected) in [
                ("System/Init/tessera.init", initImage),
                ("System/Library/Frameworks/LibTessera.framework/LibTessera", library),
            ] {
                guard case .found(let inode) = volume.resolve(
                    from: 1, relative: Array(path.utf8), followLinks: false, in: snapshot
                ) else { return XCTFail("Missing \(path)") }
                XCTAssertEqual(volume.length(inode, in: snapshot), UInt64(expected.count))
                var actual = Data()
                for offset in stride(from: 0, to: expected.count, by: page.count) {
                    let count = try XCTUnwrap(volume.readPage(inode, index: UInt64(offset / page.count),
                                                            in: snapshot, into: page))
                    actual.append(contentsOf: page.prefix(count))
                }
                XCTAssertEqual(actual, expected)
            }
            XCTAssertNil(volume.create(1, name: Array("extra".utf8), kind: .file))
        }
    }

    func testWrongRootAndReplacedImageFailBeforeMeasurement() throws {
        let directory = try directory()
        let image = directory.appendingPathComponent("system.timg")
        var root = try SystemImagePacker.pack(initImage: Data([1]), libTessera: Data([2]), to: image)
        root[0] ^= 1
        try root.withUnsafeBytes { bytes in
            XCTAssertThrowsError(try HostedTrfsDisk.openSystem(path: image.path, bootSetRoot: bytes) { _ in
                XCTFail("Measured an unauthenticated root")
                return true
            })
        }
        root[0] ^= 1
        try FileManager.default.removeItem(at: image)
        _ = try SystemImagePacker.pack(initImage: Data([1]), libTessera: Data([3]), to: image)
        try root.withUnsafeBytes { bytes in
            XCTAssertThrowsError(try HostedTrfsDisk.openSystem(path: image.path, bootSetRoot: bytes) { _ in
                XCTFail("Measured a substituted image")
                return true
            })
        }
    }

    func testEmptyMemberAndExistingOutputAreRejected() throws {
        let image = try directory().appendingPathComponent("system.timg")
        XCTAssertThrowsError(try SystemImagePacker.pack(initImage: Data(), libTessera: Data([1]), to: image))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        let original = Data([42])
        try original.write(to: image)
        XCTAssertThrowsError(try SystemImagePacker.pack(initImage: Data([1]), libTessera: Data([2]), to: image))
        XCTAssertEqual(try Data(contentsOf: image), original)
    }
}
