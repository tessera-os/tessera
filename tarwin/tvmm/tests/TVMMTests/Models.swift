import Testing

@testable import TVMM

func chainOk(_ b: [UInt8], _ slots: Int, _ head: Int) -> Bool {
  switch descriptorChain(b, slots, head, GuestAperture(base: 0, length: 4096)) {
  case .success: return true
  case .failure(let e): return false
  }
}

@Test
func descriptorWalkIsBoundedAndNeverEscapesGuestRam() {
  var b: [UInt8] = [
    0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 1, 0, 1, 0,
    0, 4, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2, 0, 0, 0,
  ]
  #expect(chainOk(b, 2, 0))
  b[14] = 0
  #expect(!chainOk(b, 2, 0))
  b[14] = 1
  b[23] = 255
  #expect(!chainOk(b, 2, 0))
  b[23] = 0
  b[12] = 5
  #expect(!chainOk(b, 2, 0))
  b[12] = 3
  b[28] = 0
  #expect(!chainOk(b, 2, 0))
  #expect(needEvent(65535, 0, 65535))
  #expect(!needEvent(0, 0, 65535))
}

func blockAllowed(_ h: [UInt8], _ read: UInt64, _ write: UInt64, _ ro: Bool) -> Bool {
  switch blockRequest(h, read, write, 2, ro, true, true, true) {
  case .success: return true
  case .failure(let e): return false
  }
}

@Test
func blockRequestsCheckDirectionCapacityAndReadOnly() {
  var h: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
  #expect(blockAllowed(h, 0, 512, true))
  #expect(!blockAllowed(h, 0, 513, true))
  #expect(!blockAllowed(h, 0, 1024, true))
  h[0] = 1
  #expect(!blockAllowed(h, 512, 0, true))
  #expect(blockAllowed(h, 512, 0, false))
  #expect(!blockAllowed(h, 0, 512, false))
  h[15] = 255
  #expect(!blockAllowed(h, 512, 0, false))
}

@Test
func pickerAuthorityStaysWithTheHostBoundAppWindow() {
  var bridge = AndroidBridge(epoch: 1, windowLimit: 3, grantLimit: 2)
  #expect(bridge.bind(11, 17, 33) == true)
  #expect(bridge.bind(12, 19, 37) == true)
  #expect(bridge.bind(12, 22, 33) == false)
  #expect(
    bridge.issue(HostGrant(token: 7, app: 11, epoch: 1, service: .folder, handle: 77)) == true)
  #expect(bridge.route(11, 17, 33, 1, .folder, 7) == 77)
  #expect(bridge.route(12, 19, 37, 1, .folder, 7) == 0)
  #expect(bridge.route(11, 17, 33, 2, .folder, 7) == 0)
  #expect(bridge.route(11, 17, 33, 1, .camera, 7) == 0)
  bridge.revoke(7)
  #expect(bridge.route(11, 17, 33, 1, .folder, 7) == 0)
}

@Test
func migrationCommitNeverLetsBothHostsResume() {
  var moveState = Checkpoint(epoch: 9, requiredDevices: 3, requiredCpus: 2)
  #expect(moveState.start(9) == true)
  #expect(moveState.stopped(true, false, true) == false)
  #expect(moveState.stopped(true, true, true) == true)
  #expect(moveState.cpuSaved(0) == true)
  #expect(moveState.cpuSaved(0) == false)
  #expect(moveState.cpuSaved(1) == true)
  #expect(moveState.devicesSaved(1) == true)
  #expect(moveState.seal(true, true, true) == false)
  #expect(moveState.devicesSaved(2) == true)
  #expect(moveState.seal(true, true, true) == true)
  #expect(moveState.prepared(8, true) == false)
  #expect(moveState.prepared(9, true) == true)
  #expect(moveState.commit(false, true) == false)
  #expect(moveState.commit(true, true) == true)
  #expect(moveState.abort() == false)
  #expect(moveState.retired(9) == true)
}
