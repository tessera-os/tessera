import Foundation
import HostedSystemImage

do {
    let args = CommandLine.arguments
    guard args.count == 4 else {
        FileHandle.standardError.write(Data("Usage: tessera-pack-system <signed-init> <signed-libtessera> <new-system-image>\n".utf8))
        exit(2)
    }
    let root = try SystemImagePacker.pack(
        initImage: Data(contentsOf: URL(fileURLWithPath: args[1])),
        libTessera: Data(contentsOf: URL(fileURLWithPath: args[2])),
        to: URL(fileURLWithPath: args[3]))
    print(root.map { String(format: "%02x", $0) }.joined())
} catch {
    FileHandle.standardError.write(Data("tessera-pack-system: \(error)\n".utf8))
    exit(1)
}
