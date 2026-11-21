public enum BlockOp: Equatable {
  case read
  case write
  case flush
  case fua
  case discard
  case zero
  case zone
  case atomic
}
public enum IoQos: Equatable {
  case deadline
  case interactive
  case initiated
  case standard
  case utility
  case background
}
public enum BlockState: Equatable {
  case pending
  case issued
}

public struct BlockCommand: Equatable {
  public let op: BlockOp
  public let lba: UInt64
  public let blocks: UInt64
  public let qos: IoQos
  public let queue: UInt32

  public init(op: BlockOp, lba: UInt64, blocks: UInt64, qos: IoQos, queue: UInt32) {
    self.op = op
    self.lba = lba
    self.blocks = blocks
    self.qos = qos
    self.queue = queue
  }
}

public struct BlockTicket: Equatable {
  public let command: BlockCommand
  public let id: UInt64
  public internal(set) var state: BlockState
  public internal(set) var replay: Bool

  public init(command: BlockCommand, id: UInt64, state: BlockState, replay: Bool) {
    self.command = command
    self.id = id
    self.state = state
    self.replay = replay
  }
}

func priority(_ qos: IoQos) -> Int {
  return switch qos {
  case .deadline: 5
  case .interactive: 4
  case .initiated: 3
  case .standard: 2
  case .utility: 1
  case .background: 0
  }
}

func barrier(_ cmd: BlockCommand) -> Bool {
  return cmd.op == .flush || cmd.op == .zone
}

func conflicts(_ first: BlockCommand, _ second: BlockCommand) -> Bool {
  if barrier(first) || barrier(second) { return true }
  if first.op == .read && second.op == .read { return false }
  if first.lba <= second.lba { return second.lba - first.lba < first.blocks }
  return first.lba - second.lba < second.blocks
}

// One dispatch table per device, across all hardware queues. All operations
// run under its lock. IDs are never recycled, including after a restart.
public struct BlockQueue: Equatable {
  public let capacity: UInt64
  public let queueCount: UInt32
  public let pendingLimit: Int
  public let depth: UInt32
  public internal(set) var epoch: UInt64 = 1
  public internal(set) var lastId: UInt64 = 0
  public internal(set) var offline: Bool = false
  public internal(set) var count: Int = 0
  public internal(set) var entries: [BlockTicket] = []

  public mutating func enqueue(_ cmd: BlockCommand) -> UInt64 {
    if offline || cmd.queue >= queueCount || depth == 0 || count >= pendingLimit
      || lastId == 0xffff_ffff_ffff_ffff
    {
      return 0
    }
    if cmd.op == .flush {
      if cmd.lba != 0 || cmd.blocks != 0 { return 0 }
    } else {
      if cmd.blocks == 0 || cmd.lba >= capacity || cmd.blocks > capacity - cmd.lba { return 0 }
    }
    lastId += 1
    let ticket = BlockTicket(command: cmd, id: lastId, state: .pending, replay: false)
    if count < entries.count { entries[count] = ticket } else { entries.append(ticket) }
    count += 1
    return lastId
  }

  public mutating func dispatch(_ queue: UInt32) -> UInt64 {
    if offline || queue >= queueCount { return 0 }
    var active: UInt32 = 0
    var lowInFlight = false
    for index in 0..<count {
      let ticket = entries[index]
      if ticket.command.queue == queue && ticket.state == .issued {
        active += 1
        if priority(ticket.command.qos) <= 1 { lowInFlight = true }
      }
    }
    if active >= depth { return 0 }
    var best: Int = -1
    var rank: Int = -1
    for at in 0..<count {
      let t = entries[at]
      if t.command.queue != queue || t.state != .pending { continue }
      let qos = priority(t.command.qos)
      if qos <= 1 && lowInFlight { continue }
      var blocked = false
      for earlier in 0..<at {
        if conflicts(entries[earlier].command, t.command)
          || (t.replay && entries[earlier].replay && entries[earlier].state == .pending)
        {
          blocked = true
          break
        }
      }
      if blocked { continue }
      let score = t.replay ? 6 : qos
      if score > rank {
        best = Int(at)
        rank = score
      }
    }
    if best < 0 { return 0 }
    entries[best].state = .issued
    return entries[best].id
  }

  public mutating func complete(_ queue: UInt32, _ sourceEpoch: UInt64, _ id: UInt64) -> Bool {
    if offline || sourceEpoch != epoch { return false }
    for at in 0..<count {
      if entries[at].id == id && entries[at].command.queue == queue && entries[at].state == .issued
      {
        for src in (at + 1)..<count { entries[src - 1] = entries[src] }
        count -= 1
        return true
      }
    }
    return false
  }

  // Only called once old queues and DMA have been quiesced and reset.
  public mutating func restart() -> Bool {
    if offline || epoch == 0xffff_ffff_ffff_ffff { return false }
    epoch += 1
    for at in 0..<count {
      entries[at].state = .pending
      entries[at].replay = true
    }
    return true
  }

  public mutating func removeDevice(_ deviceRemoved: (UInt64) -> Void) {
    offline = true
    for index in 0..<count { deviceRemoved(entries[index].id) }
    count = 0
    entries = []
  }

  public init(capacity: UInt64, queueCount: UInt32, pendingLimit: Int, depth: UInt32) {
    self.capacity = capacity
    self.queueCount = queueCount
    self.pendingLimit = pendingLimit
    self.depth = depth
  }
}
