import Foundation
import USBMassStorage

// qtest bridge for the assigned register window and three private pages.
final class QEMUBus: UHCITransport {
  struct BusError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }
  let process = Process(), input = Pipe(), output = Pipe()

  init(binary: String, image: URL) throws {
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = [
      "-machine", "pc,accel=qtest", "-m", "32M", "-display", "none",
      "-nodefaults", "-monitor", "none", "-serial", "none", "-qtest", "stdio", "-qtest-log", "none",
      "-device", "piix3-usb-uhci,id=hc,addr=05",
      "-drive", "file=" + image.path + ",format=raw,if=none,id=stick,cache=writeback",
      "-device", "usb-storage,bus=hc.0,port=1,drive=stick",
    ]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
  }
  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
  @discardableResult func q(_ line: String) throws -> String {
    try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    var b = [UInt8]()
    while b.count < 16384 {
      guard let byte = try output.fileHandleForReading.read(upToCount: 1)?.first else {
        throw BusError("qtest EOF")
      }
      if byte == 10 {
        let reply = String(decoding: b, as: UTF8.self)
        if reply == "OK" { return "" }
        guard reply.hasPrefix("OK ") else { throw BusError(line + ": " + reply) }
        return String(reply.dropFirst(3))
      }
      b.append(byte)
    }
    throw BusError("long qtest reply")
  }
  func num(_ cmd: String) throws -> Int {
    let reply = try q(cmd)
    guard reply.hasPrefix("0x"), let n = Int(reply.dropFirst(2), radix: 16) else {
      throw BusError("not a number: " + reply)
    }
    return n
  }
  func put(_ at: Int, _ bytes: [UInt8]) throws {
    if !bytes.isEmpty {
      try q("write \(at) \(bytes.count) 0x" + bytes.map { String(format: "%02x", $0) }.joined())
    }
  }
  func get(_ at: Int, _ count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    let s = Array(try q("read \(at) \(count)").utf8.dropFirst(2))
    guard s.count == count * 2 else { throw BusError("short qtest read") }
    return try stride(from: 0, to: s.count, by: 2).map { i in
      guard let b = UInt8(String(decoding: s[i...i + 1], as: UTF8.self), radix: 16) else {
        throw BusError("qtest hex")
      }
      return b
    }
  }
  func assign() throws {
    try q("outl 0xcf8 0x80002800")
    guard try num("inl 0xcfc") == 0x7020_8086 else { throw BusError("wrong PCI function") }
    try q("outl 0xcf8 0x80002820")
    try q("outl 0xcfc 0xc001")
    try q("outl 0xcf8 0x80002804")
    try q("outw 0xcfc 5")
  }
  func read16(_ offset: UInt16) throws -> UInt16 { UInt16(try num("inw \(0xc000 + Int(offset))")) }
  func write16(_ offset: UInt16, _ value: UInt16) throws {
    try q("outw \(0xc000 + Int(offset)) \(value)")
  }
  func write32(_ offset: UInt16, _ value: UInt32) throws {
    try q("outl \(0xc000 + Int(offset)) \(value)")
  }
  func loadDMA(_ address: UInt32, count: Int) throws -> [UInt8] { try get(Int(address), count) }
  func loadStatus(_ address: UInt32) throws -> UInt32 { UInt32(try num("readl \(address)")) }
  func storeDMA(_ address: UInt32, _ bytes: [UInt8]) throws { try put(Int(address), bytes) }
  func delay(milliseconds: Int) throws { try q("clock_step \(milliseconds*1_000_000)") }
}
