/// Access is relative to a mapped BAR or to retained coherent DMA grants,
/// never physical host addresses. Release orders SQ writes before a doorbell;
/// acquire orders reads of CQ and payload after observing the phase tag.
public protocol NVMeAccess: AnyObject {
  var barBytes: UInt64 { get }
  func register(_ offset: UInt64) -> UInt32
  func setRegister(_ offset: UInt64, _ value: UInt32)
  func load(_ iova: UInt64) -> UInt32
  func store(_ iova: UInt64, _ value: UInt32)
  func acquire()
  func release()
  func nowNs() -> UInt64
  func pause()
}
public enum NVMeError: Error, Equatable {
  case configuration, busy, timeout, device, protocolFault
  case command(UInt16)
}
public struct NVMePages {
  let aSQ: UInt64, aCQ: UInt64, sq: UInt64, cq: UInt64, scratch: UInt64
  let lists: [UInt64]
  var pages: [UInt64] { [aSQ, aCQ, sq, cq, scratch] + lists }
  /// Queue, Identify and optional device-readable PRP list pages are pinned
  /// and exclusive to this controller epoch. No chained lists.
  public init?(
    adminSubmission: UInt64, adminCompletion: UInt64, submission: UInt64, completion: UInt64,
    identify: UInt64, prpLists: [UInt64] = []
  ) {
    aSQ = adminSubmission
    aCQ = adminCompletion
    sq = submission
    cq = completion
    scratch = identify
    lists = prpLists
    guard lists.count <= 63, pages.allSatisfy({ $0 != 0 && $0 & 4095 == 0 }),
      Set(pages).count == pages.count
    else { return nil }
  }
  func disjoint(_ addr: UInt64, _ length: UInt64) -> Bool {
    length != 0 && length - 1 <= .max - addr
      && pages.allSatisfy { addr >= $0 ? addr - $0 >= 4096 : $0 - addr >= length }
  }
}
struct Command {
  let opcode: UInt8
  var ns: UInt32 = 0, prp1: UInt64 = 0, prp2: UInt64 = 0, d10: UInt32 = 0, d11: UInt32 = 0,
    d12: UInt32 = 0
  init(_ op: UInt8) { opcode = op }
}
struct Done { let token: UInt64, status: UInt16, result: UInt32 }
struct Queue: ~Copyable {
  let id: Int, depth: Int, sq: UInt64, cq: UInt64, db: UInt64, stride: UInt64
  private var tail = 0, sqHead = 0, head = 0, phase: UInt32 = 1, next: UInt16 = 0
  private var live: [UInt16: (token: UInt64, fetchedAfter: UInt64, list: UInt64?)] = [:]
  private let listPages: [UInt64]
  private var issued: UInt64 = 0, fetched: UInt64 = 0
  private(set) var poisoned = false
  var idle: Bool { live.isEmpty }
  init(id: Int, depth: Int, sq: UInt64, cq: UInt64, stride: UInt64, lists: [UInt64] = []) {
    self.id = id
    self.depth = depth
    self.sq = sq
    self.cq = cq
    self.stride = stride
    listPages = lists
    db = 0x1000 + UInt64(2 * id) * stride
  }
  mutating func submit(
    _ cmd: Command, _ token: UInt64, _ io: any NVMeAccess,
    listEntries: ArraySlice<UInt64> = []
  ) throws {
    guard !poisoned else { throw NVMeError.protocolFault }
    let new = (tail + 1) % depth
    guard new != sqHead, issued != .max, live.count < depth - 1,
      !live.values.contains(where: { $0.token == token })
    else {
      throw NVMeError.busy
    }
    while live[next] != nil { next &+= 1 }
    var list: UInt64?
    if !listEntries.isEmpty {
      guard (2...512).contains(listEntries.count), cmd.prp2 == 0, !listPages.isEmpty
      else { throw NVMeError.configuration }
      guard let page = listPages.first(where: { page in !live.values.contains { $0.list == page } })
      else { throw NVMeError.busy }
      list = page
      for (i, addr) in listEntries.enumerated() {
        io.store(page + UInt64(i * 8), UInt32(truncatingIfNeeded: addr))
        io.store(page + UInt64(i * 8 + 4), UInt32(addr >> 32))
      }
    }
    let cid = next
    next &+= 1
    let entry = sq + UInt64(tail * 64)
    for i in 0..<16 {
      let v: UInt32 =
        switch i {
        case 0: UInt32(cid) << 16 | UInt32(cmd.opcode)
        case 1: cmd.ns
        case 6: UInt32(truncatingIfNeeded: cmd.prp1)
        case 7: UInt32(cmd.prp1 >> 32)
        case 8: UInt32(truncatingIfNeeded: list ?? cmd.prp2)
        case 9: UInt32((list ?? cmd.prp2) >> 32)
        case 10: cmd.d10
        case 11: cmd.d11
        case 12: cmd.d12
        default: 0
        }
      io.store(entry + UInt64(i * 4), v)
    }
    issued += 1
    live[cid] = (token, issued, list)
    tail = new
    io.release()
    io.setRegister(db, UInt32(tail))
  }
  mutating func poll(_ io: any NVMeAccess) throws -> Done? {
    guard !poisoned else { throw NVMeError.protocolFault }
    let entry = cq + UInt64(head * 16)
    let last = io.load(entry + 12)
    guard (last >> 16) & 1 == phase else { return nil }
    io.acquire()
    let sqInfo = io.load(entry + 8)
    let new = Int(sqInfo & 0xffff)
    let cid = UInt16(truncatingIfNeeded: last)
    let advanced = UInt64((new - sqHead + depth) % depth)
    guard Int(sqInfo >> 16) == id, new < depth, advanced <= issued - fetched,
      let item = live[cid], item.fetchedAfter <= fetched + advanced
    else {
      poisoned = true
      throw NVMeError.protocolFault
    }
    fetched += advanced
    live.removeValue(forKey: cid)
    let result = Done(token: item.token, status: UInt16(last >> 17), result: io.load(entry))
    sqHead = new
    head += 1
    if head == depth {
      head = 0
      phase ^= 1
    }
    io.release()
    io.setRegister(db + stride, UInt32(head))
    return result
  }
}
