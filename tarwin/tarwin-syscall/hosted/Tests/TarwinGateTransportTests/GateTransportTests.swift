import Darwin
import Dispatch
import TarwinABI
import TarwinGateTransport
import TarwinHostedGate
import Testing

@Test func portSetRoutesAndDefersReplies() throws {
  var receive: mach_port_t = 0
  try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &receive) == KERN_SUCCESS)
  defer { dropReceive(receive) }
  try #require(mach_port_insert_right(
    mach_task_self_, receive, receive, UInt32(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
  defer { _ = mach_port_deallocate(mach_task_self_, receive) }
  let ports = try GatePortSet()
  try #require(ports.insert(receive) == KERN_SUCCESS)
  defer { _ = ports.remove(receive) }
  let first = submit(thread: 1, on: receive)
  let blocked = try ports.receive(timeout: 1_000).get()
  #expect(blocked.senderPID == getpid())
  #expect(blocked.gatePort == receive)
  #expect(blocked.request.threadID == 1)
  #expect(blocked.request.number == 7)
  #expect(blocked.request.arguments.a7 == 0x5457)

  let next = submit(thread: 2, on: receive)
  let immediate = try ports.receive(timeout: 1_000).get()
  #expect(immediate.request.threadID == 2)
  try immediate.reply.send(GateReply(result: CallResult(first: 2))).get()
  #expect(next.wait(timeout: .now() + .seconds(1)) == .success)
  #expect(first.wait(timeout: .now()) == .timedOut)
  try blocked.reply.send(GateReply(result: CallResult(first: 1))).get()
  #expect(first.wait(timeout: .now() + .seconds(1)) == .success)
  if case .failure(let failure) = blocked.reply.send(GateReply(result: CallResult())) {
    #expect(failure == .spentReply)
  } else {
    Issue.record("a send-once right was reused")
  }
}

private func submit(thread: UInt64, on gate: mach_port_t) -> DispatchSemaphore {
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { done.signal() }
    var receive: mach_port_t = 0
    guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &receive) == KERN_SUCCESS
    else { Issue.record("could not allocate reply port"); return }
    defer { dropReceive(receive) }
    let request = GateRequest(threadID: thread, number: 7, arguments: CallRegisters(0, 0, 0, 0, 0, 0, 0, 0x5457))
    let reply = try? GateClient.call(request, on: gate, replyPort: receive, timeout: 2_000).get()
    #expect(reply?.result.first == thread)
  }
  return done
}

private func dropReceive(_ port: mach_port_t) {
  _ = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
}
