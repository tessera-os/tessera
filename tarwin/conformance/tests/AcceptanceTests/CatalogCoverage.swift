import Testing

@testable import Acceptance

@Test func noHardwareNeverSuppressesAnUnknownGate() {
  let x = missingGates("x64", nil)
  #expect(Set(x).count == x.count)
  for key in [
    "hv.guest-windows", "hv.vmx-ept", "hv.svm-npt", "hv.nested", "hv.reject-nested",
    "hv.confidential-attestation", "hv.reject-confidential", "power.video",
    "power.10000-cycles", "deadline.release-p999-us", "tvmm.fs-grant-dax",
    "limits.vcpus", "diagnostic.TARWIN-H0001",
  ] {
    #expect(x.contains(key))
  }
  #expect(!x.contains("hv.hs-gstage"))
  #expect(missingGates("rv64", nil).contains("hv.hs-gstage"))
  #expect(missingGates("aarch64", nil).contains("hv.vhe-stage2"))
  #expect(x.filter { $0.hasPrefix("diagnostic.") }.count == 23)
  #expect(x.filter { $0.hasPrefix("limits.") }.count == 21)
}

@Test func inventoryNarrowsPlatformAndRefusalCases() throws {
  let row = "physical\tx64\tboard\tt1\tl1\tno\tno\tyes\tvmx"
  let ref = try #require(reference(row))
  #expect(ref.row == row)
  let keys = missingGates(ref.arch, ref)
  #expect(keys.contains("hv.reject-nested"))
  #expect(keys.contains("hv.confidential-attestation"))
  #expect(keys.contains("hv.vmx-ept"))
  #expect(!keys.contains("hv.svm-npt"))
  #expect(!keys.contains("power.idle"))
  #expect(!keys.contains("hv.nested"))
  #expect(reference(row + "x") == nil)
  #expect(reference(row.replacingOccurrences(of: "x64", with: "aarch64")) == nil)
}
