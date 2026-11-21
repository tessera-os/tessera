import TarwinFsWire
import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

/// A kernel File object's immutable identity. A replaced mount gets a fresh
/// nonzero epoch. Never resolve the payload from a user/server-provided ID.
public struct MountedFile {
  public let volume: UInt64, epoch: UInt64, node: UInt64
  public init?(volume: UInt64, epoch: UInt64, node: UInt64) {
    guard volume != 0, epoch != 0, node != 0 else { return nil }
    self.volume = volume
    self.epoch = epoch
    self.node = node
  }
}
public enum FileReadStart: ~Copyable {
  case ready(MountedRead)
  case unsupported, invalidHandle, wrongType, denied, invalid, unmounted, full
}
/// One positional read into a resolved, pinned destination. The mount worker
/// owns the operation until finish or abandon succeeds. Only a private staging
/// share is published to the server, never the client's destination memory.
public struct MountedRead: ~Copyable {
  private let file: MountedFile, offset: UInt64, share: FsShare?
  private var pinned: ObjectGrant?, credit: IoReservation?
  public private(set) var request: UInt64 = 0

  private init(
    _ file: MountedFile, _ offset: UInt64, _ share: FsShare?, _ grant: consuming ObjectGrant,
    _ credit: consuming IoReservation
  ) {
    self.file = file
    self.offset = offset
    self.share = share
    pinned = consume grant
    self.credit = consume credit
  }
  /// Copy and validate user iovecs first. The VM supplies an exclusive,
  /// writable, exact staging share and keeps both buffers valid until released.
  /// A zero-byte operation has no share. Serialize handle resolution and
  /// reservation with name invalidation; a read epoch alone is not a close lock.
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, name: UInt64, port: UInt64, key: UInt64, offset: UInt64, length: UInt32,
    stage: FsShare?,
    caller: borrowing ProcessExecution, ports: inout P,
    resolve: (UnsafePointer<ObjectHeader>) -> MountedFile?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> FileReadStart {
    guard call == TarwinCall.fileRead else { return .unsupported }
    guard caller.exit == nil else { return .denied }
    let table = caller.handleReader
    guard (length == 0) == (stage == nil), length == 0 || UInt64(length - 1) <= UInt64.max - offset
    else { return .invalid }
    if let s = stage {
      guard s.id != 0, s.backing != 0, s.writable, s.length == length,
        UInt64(length - 1) <= UInt64.max - s.offset
      else { return .invalid }
    }
    switch table.pinWithinEpoch(name, kind: TarwinKind.file, need: 4) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let f):
      guard let payload = resolve(f.header), stage == nil || stage?.volume == payload.volume else {
        f.drop(retire: retire)
        return .unmounted
      }
      switch table.pinWithinEpoch(port, kind: TarwinKind.port, need: 8) {
      case .invalidHandle:
        f.drop(retire: retire)
        return .invalidHandle
      case .wrongType:
        f.drop(retire: retire)
        return .wrongType
      case .accessDenied:
        f.drop(retire: retire)
        return .denied
      case .found(let p):
        let reserved = IoReservation(
          port: p.header.pointee.koid, object: f.header.pointee.koid, key: key, kind: 3,
          owner: OperationHandle(process: caller.header.pointee.koid, name: name), ports: &ports)
        p.drop(retire: retire)
        guard let reserved else {
          f.drop(retire: retire)
          return .full
        }
        return .ready(MountedRead(payload, offset, stage, consume f, consume reserved))
      }
    }
  }
  /// On ring backpressure retry this same operation. Request IDs are local
  /// to one serially owned mount session; never re-use its epoch.
  public mutating func publish(to session: inout FsRingSession) -> FsPublish {
    guard request == 0, credit != nil, session.volume == file.volume, session.epoch == file.epoch
    else { return .rejected }
    let s = share
    let result = session.submit(
      .read, node: VolumeNode(volume: file.volume, node: file.node),
      other: VolumeNode(volume: 0, node: 0), offset: offset,
      input: 0, inputBytes: 0, output: s?.id ?? 0, outputBytes: s?.length ?? 0,
      resolveShare: { $0 == s?.id ? s : nil })
    if case .ring(.transferred) = result { request = session.lastPublished }
    return result
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    credit?.matches(port: port, operation: operation) == true
  }
  /// If the read never reached the server, a worker may retire its staging
  /// grant synchronously and return credit without consuming a forged reply.
  @discardableResult public mutating func abandon<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, drain: () -> Bool, release: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard request == 0, credit != nil, drain() else { return false }
    settle(
      status: nil, count: 0, now: now, ports: &ports, commit: { _, _ in false }, release: release,
      retire: retire)
    return true
  }
  /// Commit only the retired prefix; a closed port or cancellation skips
  /// commit entirely. Under the port lock commit must be bounded, nonfaulting,
  /// all-or-nothing and nonreentrant. Release both VM pins on every outcome.
  @discardableResult public mutating func finish<P: IoPorts & ~Copyable>(
    _ done: FsReceipt, at now: UInt64, ports: inout P,
    commit: (UInt64, UInt32) -> Bool, release: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard request != 0, credit != nil, done.volume == file.volume, done.epoch == file.epoch,
      done.request == request,
      done.count <= share?.length ?? 0
    else { return false }
    settle(
      status: done.status, count: done.count, now: now, ports: &ports, commit: commit,
      release: release, retire: retire)
    return true
  }
  private mutating func settle<P: IoPorts & ~Copyable>(
    status: FsStatus?, count: UInt32, now: UInt64, ports: inout P,
    commit: (UInt64, UInt32) -> Bool, release: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) {
    let id = share?.id ?? 0
    credit.take()!.finish(at: now, ports: &ports) {
      var p = PortPacket()
      switch status {
      case .ok:
        if count == 0 || commit(id, count) { p.result0 = UInt64(count) } else { p.error = 90 }
      case nil: p.error = 70
      case .notFound: p.error = 20
      case .readOnly, .denied: p.error = 4
      case .invalid: p.error = 1
      case .noSpace: p.error = 31
      case .unsupported: p.error = 10
      case .busy: p.error = 22
      case .exists: p.error = 21
      case .notDirectory: p.error = 40
      case .notEmpty: p.error = 42
      case .io: p.error = 90
      }
      if p.error != 0 { p.subsystem = 1 }
      return p
    }
    release()
    pinned.take()!.drop(retire: retire)
  }
}
