import Foundation
import TarwinABI
import TarwinArchHosted
import TarwinIPCChannels
import TarwinObject
import TarwinSched
import TarwinSync
import TarwinSyncCalls
import TarwinSyscall
import TarwinTime
import TRFSHosted
import TarwinNetHosted

final class KernelState: @unchecked Sendable {
  let lock = NSLock()
  let arena = Arena()
  let config: TarwindConfig
  let host: any TarwindHost
  let devices: HostDeviceRegistry
  let clock = HostClock()
  let events: HostEventQueue
  let source = KoidSource()
  private let addressWaitStorage = WaitStorage()
  private let objectWaitStorage = WaitStorage()
  var waits: UnsafeMutablePointer<AddressQueue> { addressWaitStorage.queue }
  var objectWaits: UnsafeMutablePointer<AddressQueue> { objectWaitStorage.queue }
  func queue(for pending: PendingCall) -> UnsafeMutablePointer<AddressQueue> {
    pending.object == nil ? waits : objectWaits
  }
  let clocks: SystemClocks
  let page: UnsafeMutableRawBufferPointer
  let writer: UnsafeMutablePointer<TimePageWriter>
  let timers: UnsafeMutablePointer<OneShotTimers>
  var scheduler = BootstrapCPU(now: 0, identity: 1)
  var worker: HostThread?
  var tick: HostEventToken?
  var exceptionService: HostExceptionPort?
  var exceptionPorts: [TarwindProcessID: HostExceptionPort] = [:]
  var processes: [TarwindProcessID: KernelProcess] = [:]
  var eventObjects: [UInt64: UnsafeMutablePointer<EventEndpoints>] = [:]
  var channelObjects: [UInt64: UnsafeMutablePointer<ChannelPair>] = [:]
  var headers: [UnsafeMutablePointer<ObjectHeader>] = []
  var pending: [TarwindContinuationID: PendingCall] = [:]
  var completions: [TarwindContinuationID: CallResult] = [:]
  var usedSlots: Set<Int> = []
  var retired: [UnsafePointer<ObjectHeader>] = []
  var stopped = false
  var dataVolume: HostedTrfsDisk?
  var systemVolume: HostedTrfsDisk?
  var sharedFolders: [String: SharedFolder] = [:]
  let network = HostedNetwork(policy: NetPolicy(rules: [NetRule(.allow)]))
  var sockets: [UInt64: TarwindSocket] = [:]
  var socketEvents: [HostEventToken: (TarwindSocket, UInt32)] = [:]
  var nextProcess: UInt64 = 0
  var nextContinuation: UInt64 = 0
  let workerKey = DispatchKey(qos: SchedClass.normal, readySince: 0, virtualStart: 0,
    virtualDeadline: 0, classVirtualTime: 0, absoluteDeadline: 0, remainingBudget: 0, threadId: 1)

  init(config: TarwindConfig, host: any TarwindHost, devices: HostDeviceRegistry) throws {
    self.config = config; self.host = host
    self.devices = devices
    events = try HostEventQueue()
    host.bootStage("time")
    clocks = SystemClocks(frequency: 1_000_000_000, counter: clock.absoluteNanos())!
    page = arena.raw(count: 4096, alignment: 4096)
    writer = arena.store(TimePageWriter(freshPage: page)!)
    guard writer.pointee.publish(clocks) else { throw TarwindError.unavailable }
    timers = arena.store(OneShotTimers(storage: arena.initialized(TimerSlot(), count: 64),
      identity: 1, domain: .monotonic, wakesSystem: false)!)
    host.bootStage("objects")
    host.bootStage("syscalls")
    host.bootStage("storage")
    dataVolume = try HostedTrfsDisk.openData(path: config.diskPath, blocks: 1 << 16)
    systemVolume = try openSystemVolume(config: config, host: host)
    host.bootStage("network")
  }

  func now() -> SystemTime { clocks.read(counter: clock.absoluteNanos())! }

  func start() throws {
    host.bootStage("scheduler")
    guard scheduler.create(id: 1, qos: workerKey.qos), scheduler.wake(1, now: now().monotonic) else {
      throw TarwindError.unavailable
    }
    _ = scheduler.select(now: now().monotonic)
    exceptionService = try HostExceptionPort(sink: ExceptionSink(state: self, process: nil))
    tick = try events.registerTimer(deadlineNanos: clock.absoluteNanos() + 1_000_000,
      repeatingNanos: 1_000_000)
    worker = try HostCPU().startWorker(name: "tarwind.kernel", qos: hostedSchedulingPolicy(workerKey)) { [weak self] in
      self?.run()
    }
    if let worker { try applyHostedSchedulingChange(workerKey, to: worker) }
    host.bootStage("ready")
    host.ready()
  }

  func run() {
    while !lock.withLock({ stopped }) {
      do {
        let delivered = try events.wait(timeoutNanos: 10_000_000)
        if !delivered.isEmpty {
          lock.withLock {
            for event in delivered { networkReady(event) }
            serviceTimers()
          }
        }
      } catch {
        host.console("hosted event service failed: \(error)")
        lock.withLock { stopped = true }
      }
    }
  }

  func serviceTimers() {
    guard !stopped else { return }
    let time = now()
    while let cookie = timers.pointee.takeDue(at: time) {
      let id = TarwindContinuationID(value: cookie)
      if let wait = pending[id] {
        _ = queue(for: wait).pointee.finish(wait.ticket, reason: .timeout, change: { changed($0) })
      }
    }
    _ = scheduler.select(now: time.monotonic)
    drainRetired()
  }

  func createProcess(name: String) -> TarwindProcessID {
    lock.withLock {
      guard !stopped, processes.count < 64, nextProcess < UInt64.max else {
        return TarwindProcessID(value: 0)
      }
      nextProcess += 1
      let id = TarwindProcessID(value: nextProcess)
      processes[id] = KernelProcess(name: name, arena: arena, salt: UInt8(truncatingIfNeeded: nextProcess))
      return id
    }
  }

  func changed(_ event: AddressChange) {
    guard case .ready(let ticket, _, _, let reason) = event,
      let wait = pending.values.first(where: { $0.ticket == ticket }) else { return }
    pending.removeValue(forKey: wait.id)
    if let timer = wait.timer { _ = timers.pointee.cancel(timer) }
    let result = waitCallCompletion(reason)
    completions[wait.id] = CallResult(status: result.status, first: UInt64(wait.object?.pointee.signals ?? 0))
    if let object = wait.object, object.pointee.release() == .destroy { retired.append(object) }
    usedSlots.remove(ticket.slot)
  }

  func notify(_ object: UnsafePointer<ObjectHeader>) {
    let matches = pending.values.filter { $0.object == object && object.pointee.signals & $0.mask != 0 }
    for wait in matches {
      _ = objectWaits.pointee.finish(wait.ticket, reason: .woken, change: { changed($0) })
    }
  }

  func invalidate(_ name: UInt64, process: TarwindProcessID) {
    let matches = pending.values.filter { $0.process == process && $0.name == name }
    for wait in matches {
      _ = queue(for: wait).pointee.finish(wait.ticket, reason: .cancelled, change: { changed($0) })
    }
  }

  func drainRetired() {
    while !retired.isEmpty {
      let object = retired.removeLast()
      if let event = eventObjects[object.pointee.koid] {
        event.pointee.destroy(object, notify: { notify($0) })
      }
      if let pair = channelObjects[object.pointee.koid], let end = pair.pointee.end(of: object) {
        pair.pointee.close(end, retire: { retired.append($0) })
      }
    }
  }

  func fault(process: TarwindProcessID, kind: HostException.Kind, code: UInt64, address: UInt64, pc: UInt64) {
    let removed = lock.withLock { () -> Bool in
      guard let record = processes.removeValue(forKey: process) else { return false }
      let exit = TaskExit(.crashed, code: Int64(bitPattern: code))
      let waitsForProcess = pending.values.filter { $0.process == process }
      for wait in waitsForProcess {
        _ = queue(for: wait).pointee.finish(wait.ticket, reason: .cancelled, change: { changed($0) })
      }
      record.table.pointee.drain(retire: { retired.append($0) })
      for socket in Array(sockets.values) where socket.process == process { closeSocket(socket) }
      exceptionPorts.removeValue(forKey: process)
      drainRetired()
      return exit.reason == .crashed
    }
    if removed {
      host.console("process \(process.value) exception \(kind) code=\(code) address=\(address) pc=\(pc); terminated")
    }
  }

  func shutdown() {
    let thread: HostThread? = lock.withLock {
      stopped = true
      for socket in Array(sockets.values) { closeSocket(socket) }
      for folder in sharedFolders.values { folder.stop() }
      sharedFolders.removeAll()
      dataVolume = nil; systemVolume = nil
      for wait in Array(pending.values) {
        _ = queue(for: wait).pointee.finish(wait.ticket, reason: .cancelled, change: { changed($0) })
      }
      for process in processes.values { process.table.pointee.drain(retire: { retired.append($0) }) }
      processes.removeAll()
      drainRetired()
      exceptionPorts.removeAll(); exceptionService = nil
      if let tick { try? events.cancel(tick); self.tick = nil }
      let thread = worker; worker = nil
      return thread
    }
    thread?.waitUntilFinished()
  }

}

final class ExceptionSink: HostExceptionSink, @unchecked Sendable {
  weak var state: KernelState?
  let process: TarwindProcessID?
  let pager: (@Sendable (TarwindProcessID, HostException) throws -> HostExceptionDisposition?)?
  init(state: KernelState, process: TarwindProcessID?,
    pager: (@Sendable (TarwindProcessID, HostException) throws -> HostExceptionDisposition?)? = nil) {
    self.state = state; self.process = process; self.pager = pager
  }
  func handle(_ exception: HostException) -> HostExceptionDisposition {
    if let process {
      if let disposition = try? pager?(process, exception), case .resume = disposition {
        return disposition
      }
      state?.fault(process: process, kind: exception.kind, code: exception.code,
        address: exception.faultAddress, pc: exception.pc)
    } else {
      state?.host.console("unbound host exception \(exception.kind) pc=\(exception.pc)")
    }
    return .terminate
  }
}
