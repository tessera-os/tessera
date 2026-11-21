import AndroidAgent
import AndroidWire
import Testing

@testable import TVMM

@Test func appChannelChecksBothPermissionsAndRoutesInputBackToOneWindow() throws {
  var guest = try #require(GuestWindows(epoch: 9, limit: 2))
  var host = try #require(AgentChannel(app: 11, epoch: 9))
  var bridge = AndroidBridge(epoch: 9, windowLimit: 4, grantLimit: 8)
  var last: [UInt8] = []
  var calls: [UInt64] = []
  var closed: [UInt64] = []
  func exchange(_ record: [UInt8]) -> Bool? {
    last = record
    return host.receive(
      record, bridge: &bridge, makeSurface: { app, win in app * 100 + win },
      closeSurface: { closed.append($0) },
      invoke: { _, handle, _, _ in
        calls.append(handle)
        return true
      })
  }
  func request(_ op: WindowOperation, _ token: UInt64 = 0, _ allows: Bool = true) -> Bool {
    guest.request(op, window: 7, token: token, androidAllows: { allows }, exchange: exchange)
  }
  #expect(bridge.bind(12, 7, 1207) == true)
  #expect(request(.open))
  #expect(
    bridge.issue(HostGrant(token: 2, app: 11, epoch: 9, service: .camera, handle: 200)) == true)
  #expect(!request(.folder, 2))
  #expect(!request(.camera, 2, false))
  #expect(request(.camera, 2))
  bridge.revoke(2)
  #expect(!request(.camera, 2))
  #expect(calls == [200])
  #expect(
    bridge.issue(HostGrant(token: 3, app: 11, epoch: 9, service: .input, handle: 300)) == true)
  var input: [UInt8] = []
  let routed = host.input(
    bridge: bridge, surface: 1107, grant: 3, payload: [4, 5],
    send: {
      input = $0
      return true
    })
  #expect(routed)
  #expect(guest.input(input, deliver: { $0 == 7 && $1 == [4, 5] }) == true)
  #expect(guest.input(input, deliver: { _, _ in true }) == false)
  #expect(request(.close))
  #expect(closed == [1107] && bridge.windows.count == 1 && bridge.windows[0].app == 12)
  #expect(!request(.camera, 2))
  #expect(request(.open))
  #expect(exchange(last) == nil)
  #expect(host.disconnected && bridge.grants.isEmpty && bridge.windows.count == 1)
}

@Test func frameRejectsUnboundDataAndLostAckStopsGuest() throws {
  var guest = try #require(GuestWindows(epoch: 1, limit: 1))
  var msg: [UInt8] = []
  let ok = guest.request(
    .open, window: 1, androidAllows: { true },
    exchange: {
      msg = $0
      return nil
    })
  #expect(!ok && guest.disconnected)
  #expect(WindowMessage(record: msg + [0]) == nil)
  msg[2] = 1
  #expect(WindowMessage(record: msg) == nil)
  #expect(
    guest.request(.open, window: 2, androidAllows: { true }, exchange: { _ in true }) == false)
}
