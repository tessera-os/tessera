import Darwin
import TarwinHostedGate
import TarwinABI

public enum DemoCall {
    public static let console: UInt64 = 0xFFFF_0001
    public static let display: UInt64 = 0xFFFF_0002
    public static let input: UInt64 = 0xFFFF_0003
}
public enum GateWire {
    private static let headerSize = MemoryLayout<mach_msg_header_t>.size
    private static func packet<T>(_ body: (UnsafeMutableRawBufferPointer, UnsafeMutablePointer<mach_msg_header_t>) throws -> T) rethrows -> T {
        var words = [UInt64](repeating: 0, count: 64)
        return try words.withUnsafeMutableBytes { bytes in
            try body(bytes, bytes.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self))
        }
    }
    public static func call(on port: mach_port_t, number: UInt64, value: UInt64 = 0) throws -> GateReply {
        var reply: mach_port_t = 0
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply) == KERN_SUCCESS else { throw WireError.invalid }
        defer { mach_port_mod_refs(mach_task_self_, reply, MACH_PORT_RIGHT_RECEIVE, -1) }
        return try packet { bytes, head in
            var args = CallRegisters(); args[0] = value
            let request = GateRequest(threadID: 1, number: number, arguments: args)
            head.pointee = mach_msg_header_t(msgh_bits: UInt32(MACH_MSG_TYPE_COPY_SEND | (MACH_MSG_TYPE_MAKE_SEND_ONCE << 8)),
                msgh_size: UInt32(headerSize + GateRequest.byteCount), msgh_remote_port: port,
                msgh_local_port: reply, msgh_voucher_port: 0, msgh_id: GateRequest.messageID)
            _ = request.encode(into: UnsafeMutableRawBufferPointer(rebasing: bytes[headerSize..<headerSize + GateRequest.byteCount]))
            let code = mach_msg(head, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
                                head.pointee.msgh_size, UInt32(bytes.count), reply, 2000, 0)
            guard code == KERN_SUCCESS else { throw WireError.mach(code) }
            guard head.pointee.msgh_id == GateReply.messageID,
                  head.pointee.msgh_size == headerSize + GateReply.byteCount,
                  head.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX == 0,
                  let result = GateReply(decoding: UnsafeRawBufferPointer(rebasing: bytes[headerSize..<headerSize + GateReply.byteCount])) else {
                mach_msg_destroy(head); throw WireError.invalid
            }
            return result
        }
    }
    @discardableResult public static func serve(on port: mach_port_t, handler: (GateRequest) -> GateReply) -> Bool {
        packet { bytes, head in
            let code = mach_msg(head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, UInt32(bytes.count), port, 100, 0)
            guard code == KERN_SUCCESS else { return false }
            guard head.pointee.msgh_id == GateRequest.messageID,
                  head.pointee.msgh_size == headerSize + GateRequest.byteCount,
                  head.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX == 0,
                  head.pointee.msgh_bits & 0x1f == UInt32(MACH_MSG_TYPE_PORT_SEND_ONCE),
                  head.pointee.msgh_remote_port != 0,
                  let request = GateRequest(decoding: UnsafeRawBufferPointer(rebasing: bytes[headerSize..<headerSize + GateRequest.byteCount])) else {
                mach_msg_destroy(head); return false
            }
            let replyPort = head.pointee.msgh_remote_port
            let reply = handler(request)
            head.pointee = mach_msg_header_t(msgh_bits: UInt32(MACH_MSG_TYPE_MOVE_SEND_ONCE),
                msgh_size: UInt32(headerSize + GateReply.byteCount), msgh_remote_port: replyPort,
                msgh_local_port: 0, msgh_voucher_port: 0, msgh_id: GateReply.messageID)
            _ = reply.encode(into: UnsafeMutableRawBufferPointer(rebasing: bytes[headerSize..<headerSize + GateReply.byteCount]))
            let sent = mach_msg(head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, head.pointee.msgh_size, 0, 0, 1000, 0)
            if sent != KERN_SUCCESS { mach_port_deallocate(mach_task_self_, replyPort) }
            return sent == KERN_SUCCESS
        }
    }
    public enum WireError: Error { case invalid, mach(Int32) }
}
