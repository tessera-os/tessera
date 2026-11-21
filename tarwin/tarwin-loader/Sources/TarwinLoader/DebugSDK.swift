// Historical #2310 freeze, not the additive SDK on main. The SDK is a
// separate protected installation input, never the framework's section.
public func withW1SDKContract<R>(_ sdk: UnsafeRawBufferPointer,
  _ body: (EarlyRIDLContract) -> R) -> R? {
  guard sdk.count == 83 else { return nil }
  let symbol: StaticString = "_RIDL110LibTessera14processCurrentF_v6f1b36cbca464ed8"
  let module: StaticString = "LibTessera"
  let c = EarlyRIDLContract(uuid: .init(rebasing: sdk[26..<42]),
    symbol: .init(start: symbol.utf8Start, count: symbol.utf8CodeUnitCount),
    textSHA256: .init(rebasing: sdk[47..<79]), typeTag: 0x8b65_40d3)
  let m = RIDLIdentity(name: .init(start: module.utf8Start, count: module.utf8CodeUnitCount),
    uuid: c.uuid)
  guard c.isW1ProcessCurrent, RIDLMetadata(bytes: sdk).supports(m, textSHA256: c.textSHA256)
  else { return nil }
  return body(c)
}

/// QEMU-only, out-of-band provisioning receipt, not a TIR package release.
/// Commits to the exact SDK, ISA, train, TIR and function identifier.
public func debugW1SDKMessage(_ sdk: UnsafeRawBufferPointer, machine: UInt16,
  into output: UnsafeMutableRawBufferPointer) -> Int? {
  let domain: StaticString = "Tarwin QEMU debug W1 SDK v1"
  let d = domain.utf8CodeUnitCount
  guard imagePage(machine) != 0 else { return nil }
  return withW1SDKContract(sdk) { c -> Int? in
    let end = d + 13 + sdk.count + c.symbol.count
    guard output.count >= end else { return nil }
    for i in 0..<d { output[i] = domain.utf8Start[i] }
    output[d] = 0
    output[d + 1] = UInt8(truncatingIfNeeded: machine)
    output[d + 2] = UInt8(machine >> 8)
    output[d + 3] = 26; output[d + 4] = 11; output[d + 5] = 1
    output[d + 6] = 26; output[d + 7] = 11; output[d + 8] = 2
    for i in 0..<4 { output[d + 9 + i] = UInt8(truncatingIfNeeded: c.typeTag >> (8 * i)) }
    for i in sdk.indices { output[d + 13 + i] = sdk[i] }
    for i in c.symbol.indices { output[d + 13 + sdk.count + i] = c.symbol[i] }
    return end
  } ?? nil
}
