import Foundation
import XPC

public final class AudioLinkEnvelope: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }
    public let object: xpc_object_t
    public init(_ object: xpc_object_t) { self.object = object }
    public required init?(coder: NSCoder) {
        guard let coder = coder as? NSXPCCoder,
              let object = coder.decodeXPCObject(ofType: XPC_TYPE_DICTIONARY, forKey: "link") else { return nil }
        self.object = object
    }
    public func encode(with coder: NSCoder) {
        guard let coder = coder as? NSXPCCoder else {
            coder.failWithError(CocoaError(.coderInvalidValue)); return
        }
        coder.encodeXPCObject(object, forKey: "link")
    }
}
