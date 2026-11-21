import AppKit
import Darwin
import HostedDeviceWire
import TarwinArchHosted

public enum HIDKeycodes {
  private static let table: [UInt8] = [
      4,22,7,9,11,10,29,27,6,25,0,5,20,26,8,21,
      28,23,30,31,32,33,35,34,46,38,36,45,37,39,48,18,
      24,47,12,19,40,15,13,52,14,51,49,54,56,17,16,55,
      43,44,53,42,0,41,231,227,225,57,226,224,229,230,228,0,
      108,99,0,85,0,87,0,83,0,0,0,84,88,0,86,109,
      110,103,98,89,90,91,92,93,94,95,111,96,97,137,135,133,
      62,63,64,60,65,66,145,68,144,104,107,105,0,67,0,69,
      0,106,73,74,75,76,61,77,59,78,58,80,79,81,82,
    ]
  public static func usage(for key: UInt16) -> UInt8? {
    guard Int(key) < table.count, table[Int(key)] != 0 else { return nil }
    return table[Int(key)]
  }
}

@MainActor public final class HIDEventTranslator {
  public var onLEDs: ((UInt8) -> Void)?
  public private(set) var focused = false
  private let channel: any HostedDeviceChannel
  private var held: InlineArray<256, Bool> = .init(repeating: false)
  private var modifiers: UInt8 = 0
  private var buttons: UInt8 = 0
  private var sequence: UInt64 = 0
  private var tabletInRange = false
  public init(channel: any HostedDeviceChannel) {
    self.channel = channel
  }
  public static func nowNs() -> UInt64 {
    clock.monotonicNanos()
  }
  private static let clock = HostClock()
  public func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let frame = FrameView(bytes), frame.family == 1, frame.kind == HIDKind.leds,
      frame.payload.count == 1 else { return }
    onLEDs?(frame.payload[0])
  }
  public func setFocused(_ value: Bool, timestampNs: UInt64? = nil) {
    if focused && !value {
      for i in 0..<256 { held[i] = false }
      modifiers = 0; buttons = 0
      keyboard(timestampNs ?? Self.nowNs())
      emit(HIDKind.pointer, size: 17, time: timestampNs ?? Self.nowNs()) { _ in }
      tabletInRange = false
      emit(HIDKind.tablet, size: 13, time: timestampNs ?? Self.nowNs()) { _ in }
    }
    focused = value
  }
  private func emit(_ kind: UInt16, size: Int, flags: UInt16 = 0, time: UInt64,
    fill: (UnsafeMutableRawBufferPointer) -> Void) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { payload in
      payload.initialize(repeating: 0)
      let p = UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(payload)[..<size])
      fill(p)
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 96) { storage in
        let out = UnsafeMutableRawBufferPointer(storage)
        sequence &+= 1
        if let count = FrameView.encode(family: 1, kind: kind, flags: flags,
          sequence: sequence, timestampNs: time, payload: UnsafeRawBufferPointer(p), into: out) {
          channel.send(frame: UnsafeRawBufferPointer(rebasing: out[..<count]))
        }
      }
    }
  }
  private func keyboard(_ time: UInt64) {
    emit(HIDKind.keyboard, size: 8, time: time) { p in
      p[0] = modifiers
      var count = 0
      for i in 0..<224 where held[i] {
        if count < 6 { p[2 + count] = UInt8(i) }; count += 1
      }
      if count > 6 { for i in 2..<8 { p[i] = 1 } }
    }
  }
  private func signed(_ value: Double) -> UInt64 {
    UInt64(UInt16(bitPattern: Int16(value.isFinite ? max(-32768, min(32767, value.rounded())) : 0)))
  }
  private func normalized(_ value: Double) -> UInt64 {
    UInt64(value.isFinite ? max(0, min(65535, (value * 65535).rounded())) : 0)
  }
  private func fixed(_ value: Double) -> UInt64 {
    UInt64(UInt32(bitPattern: Int32(value.isFinite
      ? max(Double(Int32.min), min(Double(Int32.max), (value * 65536).rounded())) : 0)))
  }
  private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
    for (flag, left, right) in [(NSEvent.ModifierFlags.control, UInt8(1), UInt8(16)),
      (.shift, 2, 32), (.option, 4, 64), (.command, 8, 128)] {
      if !flags.contains(flag) { modifiers &= ~(left | right) }
      else if modifiers & (left | right) == 0 { modifiers |= left }
    }
  }
  public func translate(_ event: NSEvent, windowSize: CGSize, timestampNs: UInt64? = nil) {
    guard focused else { return }
    let time = timestampNs ?? Self.nowNs()
    let point = event.locationInWindow
    let x = normalized(windowSize.width > 0 ? point.x / windowSize.width : 0)
    let y = normalized(windowSize.height > 0 ? point.y / windowSize.height : 0)
    switch event.type {
    case .keyDown, .keyUp:
      guard let usage = HIDKeycodes.usage(for: event.keyCode) else { return }
      syncModifiers(event.modifierFlags)
      held[Int(usage)] = event.type == .keyDown
      keyboard(time)
    case .flagsChanged:
      if let usage = HIDKeycodes.usage(for: event.keyCode), usage >= 0xe0 {
        let bit = UInt8(1 << (usage - 0xe0))
        let flag: NSEvent.ModifierFlags = switch usage {
        case 0xe0,0xe4: .control
        case 0xe1,0xe5: .shift
        case 0xe2,0xe6: .option
        default: .command
        }
        if event.modifierFlags.contains(flag) { modifiers ^= bit }
        else { modifiers &= ~(bit | (usage < 0xe4 ? bit << 4 : bit >> 4)) }
      }
      if event.keyCode == 57 {
        held[57] = true; keyboard(time); held[57] = false
      }
      keyboard(time)
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
         .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
         .scrollWheel:
      if [.leftMouseDown,.rightMouseDown,.otherMouseDown,.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(event.type),
        event.buttonNumber >= 0, event.buttonNumber < 5 {
        let bit = UInt8(1 << event.buttonNumber)
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type) { buttons |= bit }
        else { buttons &= ~bit }
      }
      let scroll = event.type == .scrollWheel
      emit(HIDKind.pointer, size: 17, flags: scroll && event.hasPreciseScrollingDeltas ? 1 : 0, time: time) { p in
        p[0] = buttons
        Wire.write(signed(scroll ? 0 : event.deltaX), to: p, at: 1, width: 2)
        Wire.write(signed(scroll ? 0 : event.deltaY), to: p, at: 3, width: 2)
        Wire.write(fixed(scroll ? event.scrollingDeltaY : 0), to: p, at: 5, width: 4)
        Wire.write(fixed(scroll ? event.scrollingDeltaX : 0), to: p, at: 9, width: 4)
        Wire.write(x, to: p, at: 13, width: 2); Wire.write(y, to: p, at: 15, width: 2)
      }
    case .magnify, .rotate, .swipe, .smartMagnify:
      emit(HIDKind.gesture, size: 17, time: time) { p in
        p[0] = event.type == .magnify ? 1 : event.type == .rotate ? 2 : event.type == .swipe ? 3 : 4
        let values = (event.type == .magnify ? Double(event.magnification) : event.type == .rotate ? Double(event.rotation) : event.deltaX, event.deltaY)
        for (offset, value) in [(1, values.0), (5, values.1)] {
          let fixed = Int32(value.isFinite ? max(Double(Int32.min), min(Double(Int32.max), value * 65536)) : 0)
          Wire.write(UInt64(UInt32(bitPattern: fixed)), to: p, at: offset, width: 4)
        }
        Wire.write(UInt64(event.phase.rawValue), to: p, at: 9, width: 4)
        Wire.write(UInt64(event.momentumPhase.rawValue), to: p, at: 13, width: 4)
      }
    case .tabletPoint, .tabletProximity:
      if event.type == .tabletProximity { tabletInRange = event.isEnteringProximity }
      else { tabletInRange = true }
      emit(HIDKind.tablet, size: 13, time: time) { p in
        let isPoint = event.type == .tabletPoint
        p[0] = (isPoint && event.pressure > 0 ? 1 : 0) | (tabletInRange ? 2 : 0)
        Wire.write(x, to: p, at: 1, width: 2); Wire.write(y, to: p, at: 3, width: 2)
        if isPoint {
          Wire.write(normalized(Double(event.pressure)), to: p, at: 5, width: 2)
          Wire.write(signed(event.tilt.x * 90), to: p, at: 7, width: 2)
          Wire.write(signed(event.tilt.y * 90), to: p, at: 9, width: 2)
          let rotation = event.rotation.isFinite ? max(0, min(360, event.rotation)) : 0
          Wire.write(UInt64(rotation), to: p, at: 11, width: 2)
        }
      }
    default: break
    }
  }
}
