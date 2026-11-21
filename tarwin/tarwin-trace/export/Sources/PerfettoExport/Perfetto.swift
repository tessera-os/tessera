// The trace service emits standard perfetto.protos.Trace packets, not JSON
// pretending to be Perfetto. Strings are not interned; packets do not depend on earlier incremental state.
func varint(_ out: inout [UInt8], _ word: UInt64) {
  var n = word
  while n >= 128 {
    out.append(UInt8((n & 127) | 128))
    n = n >> 7
  }
  out.append(UInt8(n))
}
func integerField(_ out: inout [UInt8], _ field: UInt64, _ word: UInt64) {
  varint(&out, field << 3)
  varint(&out, word)
}
func dataField(_ out: inout [UInt8], _ field: UInt64, _ data: [UInt8]) {
  varint(&out, (field << 3) | 2)
  varint(&out, UInt64(data.count))
  for byte in data { out.append(byte) }
}
func wrapPacket(_ packet: [UInt8]) -> [UInt8] {
  var out: [UInt8] = []
  dataField(&out, 1, packet)
  return out
}
public func perfettoTrack(_ uuid: UInt64, _ label: String, _ counter: Bool) -> [UInt8] {
  var track: [UInt8] = []
  integerField(&track, 1, uuid)
  dataField(&track, 2, Array(label.utf8))
  if counter { dataField(&track, 8, []) }
  var packet: [UInt8] = []
  integerField(&packet, 10, 1)
  dataField(&packet, 60, track)
  return wrapPacket(packet)
}
public enum TrackType { case begin, end, instant, counter }
public func perfettoEvent(
  _ uuid: UInt64, _ monotonicNs: UInt64, _ kind: TrackType, _ category: String,
  _ name: String, _ counterBits: UInt64, subject: UInt64? = nil, value: UInt64? = nil
) -> [UInt8] {
  let t: UInt64 =
    switch kind {
    case .begin: 1
    case .end: 2
    case .instant: 3
    case .counter: 4
    }
  var event: [UInt8] = []
  integerField(&event, 9, t)
  integerField(&event, 11, uuid)
  if kind != .end {
    dataField(&event, 22, Array(category.utf8))
    dataField(&event, 23, Array(name.utf8))
  }
  if kind == .counter { integerField(&event, 30, counterBits) }
  for (label, number) in [("subject", subject), ("value", value)] {
    if let number {
      var arg: [UInt8] = []
      dataField(&arg, 10, Array(label.utf8))  // DebugAnnotation.name
      integerField(&arg, 3, number)  // uint_value
      dataField(&event, 4, arg)
    }
  }
  var packet: [UInt8] = []
  integerField(&packet, 8, monotonicNs)
  integerField(&packet, 58, 3)
  integerField(&packet, 10, 1)
  dataField(&packet, 11, event)
  return wrapPacket(packet)
}
