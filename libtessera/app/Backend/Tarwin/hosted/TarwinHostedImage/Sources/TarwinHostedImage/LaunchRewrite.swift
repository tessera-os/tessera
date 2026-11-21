import Foundation

extension HostedTrapRewrite {
  public static func rewrite(
    _ code: Data, _ rva: UInt64, _ imageBase: UInt64, _ veneersAt: UInt64,
    verifiedTrapRVAs: [UInt64]
  ) throws -> (text: Data, veneers: Data, siteMap: [UInt64: UInt64]) {
    let (base, baseOverflow) = imageBase.addingReportingOverflow(rva)
    let (end, endOverflow) = rva.addingReportingOverflow(UInt64(code.count))
    guard !baseOverflow, !endOverflow, code.count % 4 == 0 else {
      throw HostedRewriteError.invalidLayout
    }
    let words = code.withUnsafeBytes { raw in
      stride(from: 0, to: raw.count, by: 4).map {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
      }
    }
    let sites = try verifiedTrapRVAs.filter { (rva..<end).contains($0) }.map { site in
      let (address, overflow) = imageBase.addingReportingOverflow(site)
      guard !overflow else { throw HostedRewriteError.invalidLayout }
      return address
    }
    let rewritten = try rewrite(text: words, at: base, listedTraps: sites, veneersAt: veneersAt)
    func bytes(_ words: [UInt32]) -> Data {
      words.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }
    return (bytes(rewritten.text), bytes(rewritten.veneers), rewritten.gateTrapSites)
  }
}
