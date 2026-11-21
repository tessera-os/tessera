/// First thread only: checked against the unpublished private root, not
/// saved user state. The caller pins the zeroed frames and excludes aliases.
public struct ArmInitialControlStack {
  public let root, pointer: UInt64
  // Check return addresses and push on calls. No explicit EL0 stores/pushes.
  public static let control: UInt64 = (1 << 10) | (1 << 5) | 1

  public init?(
    tables: borrowing ArmUserTranslation, shadow: Range<UInt64>, physical: UInt64,
    stackBytes: UInt64
  ) {
    let page: UInt64 = 16384
    let limit: UInt64 = 1 << 46
    let bytes = shadow.upperBound - shadow.lowerBound
    guard tables.layout == .guarded, stackBytes >= page, stackBytes <= limit,
      stackBytes & (page - 1) == 0, shadow.lowerBound >= (1 << 43) + page,
      shadow.upperBound <= limit - page, (shadow.lowerBound | physical) & (page - 1) == 0,
      bytes == max(page, ((stackBytes / 8 + page - 1) / page) * page),
      physical != 0, physical <= (1 << 48) - bytes,
      tables.entryPage(shadow.lowerBound - page, is: .guardPage),
      tables.entryPage(shadow.upperBound, is: .guardPage)
    else { return nil }
    var offset: UInt64 = 0
    while offset < bytes {
      guard tables.mapsControlPage(shadow.lowerBound + offset, physical: physical + offset)
      else { return nil }
      offset += page
    }
    root = tables.physicalRoot
    // Last zero word is the end marker; a call pre-decrements this pointer.
    pointer = shadow.upperBound - 8
  }
}
