import KCore

// A.1 is a byte protocol, not the memory representation of this struct.
public struct BootInfo {
  public var year: UInt8
  public var month: UInt8
  public var week: UInt8
  public var mapAddress: UInt64
  public var mapCount: UInt64
  public var rsdp: UInt64
  public var deviceTree: UInt64
  public var uefiTable: UInt64
  public var framebuffer: UInt64
  public var bootSet: UInt64
  public var bootSetSize: UInt64
  public var entropy0: UInt64
  public var entropy1: UInt64
  public var entropy2: UInt64
  public var entropy3: UInt64
  public var entropy4: UInt64
  public var entropy5: UInt64
  public var entropy6: UInt64
  public var entropy7: UInt64
  public var logAddress: UInt64
  public var logSize: UInt64
  public var kernelVirtual: UInt64
  public var kernelPhysical: UInt64
  public var options: UInt64
  public var panicRecord: UInt64
  public var width: UInt32
  public var height: UInt32
  public var stride: UInt32
  public var format: UInt32
  public var slot: UInt8
  public var security: UInt8
}

public func emptyBootInfo() -> BootInfo {
  return BootInfo(
    year: 0,
    month: 0,
    week: 0,
    mapAddress: 0,
    mapCount: 0,
    rsdp: 0,
    deviceTree: 0,
    uefiTable: 0,
    framebuffer: 0,
    bootSet: 0,
    bootSetSize: 0,
    entropy0: 0,
    entropy1: 0,
    entropy2: 0,
    entropy3: 0,
    entropy4: 0,
    entropy5: 0,
    entropy6: 0,
    entropy7: 0,
    logAddress: 0,
    logSize: 0,
    kernelVirtual: 0,
    kernelPhysical: 0,
    options: 0,
    panicRecord: 0,
    width: 0,
    height: 0,
    stride: 0,
    format: 0,
    slot: 0,
    security: 0)
}

public func bootBlockFits(_ address: UInt64, capacity: UInt64) -> Bool {
  return capacity >= 4096 && alignedTo(address, alignment: 4096)
    && validExtent(address, length: 4096)
}

// Address arithmetic here does not confer ownership of external memory.
public func validBootInfo(_ info: BootInfo) -> Bool {
  if info.mapAddress == 0 || info.mapCount == 0
    || info.mapCount > UInt64(0xffff_ffff_ffff_ffff) / 32
  {
    return false
  }
  if !validExtent(info.mapAddress, length: info.mapCount * 32) { return false }
  if info.rsdp == 0 && info.deviceTree == 0 { return false }
  if info.bootSet == 0 || !validExtent(info.bootSet, length: info.bootSetSize) { return false }
  if info.logSize != 0
    && (info.logAddress == 0 || !validExtent(info.logAddress, length: info.logSize))
  {
    return false
  }
  return info.slot <= 2 && (info.security & 0xe0) == 0 && info.month >= 1 && info.month <= 12
    && info.week >= 1
}

func packedBootWord(_ info: BootInfo, offset: UInt64) -> UInt64 {
  if offset == 0 {
    return UInt64(0x4249_4254) | (UInt64(info.year) << 32) | (UInt64(info.month) << 40)
      | (UInt64(info.week) << 48) | (UInt64(1) << 56)
  }
  if offset == 8 { return 4096 }
  if offset == 64 { return UInt64(info.width) | (UInt64(info.height) << 32) }
  if offset == 72 { return UInt64(info.stride) | (UInt64(info.format) << 32) }
  if offset == 176 { return UInt64(info.slot) | (UInt64(info.security) << 8) }
  if offset == 16 { return info.mapAddress }
  if offset == 24 { return info.mapCount }
  if offset == 32 { return info.rsdp }
  if offset == 40 { return info.deviceTree }
  if offset == 48 { return info.uefiTable }
  if offset == 56 { return info.framebuffer }
  if offset == 80 { return info.bootSet }
  if offset == 88 { return info.bootSetSize }
  if offset == 96 { return info.entropy0 }
  if offset == 104 { return info.entropy1 }
  if offset == 112 { return info.entropy2 }
  if offset == 120 { return info.entropy3 }
  if offset == 128 { return info.entropy4 }
  if offset == 136 { return info.entropy5 }
  if offset == 144 { return info.entropy6 }
  if offset == 152 { return info.entropy7 }
  if offset == 160 { return info.logAddress }
  if offset == 168 { return info.logSize }
  if offset == 184 { return info.kernelVirtual }
  if offset == 192 { return info.kernelPhysical }
  if offset == 200 { return info.options }
  if offset == 208 { return info.panicRecord }
  return 0
}

// After checking bootBlockFits and validBootInfo, emit offsets [0,4096).
public func bootInfoByte(_ info: BootInfo, offset: UInt64) -> UInt8 {
  let word = packedBootWord(info, offset: offset & UInt64(0xffff_ffff_ffff_fff8))
  return UInt8((word >> ((offset & 7) * 8)) & 255)
}

func unpackBootWord(_ info: inout BootInfo, offset: UInt64, value: UInt64) -> Bool {
  if offset == 0 {
    if (value & 0xffff_ffff) != 0x4249_4254 || value >> 56 != 1 { return false }
    info.year = UInt8((value >> 32) & 255)
    info.month = UInt8((value >> 40) & 255)
    info.week = UInt8((value >> 48) & 255)
  } else if offset == 8 {
    return value == 4096
  } else if offset == 64 {
    info.width = UInt32(value & 0xffff_ffff)
    info.height = UInt32(value >> 32)
  } else if offset == 72 {
    info.stride = UInt32(value & 0xffff_ffff)
    info.format = UInt32(value >> 32)
  } else if offset == 176 {
    if value >> 16 != 0 { return false }
    info.slot = UInt8(value & 255)
    info.security = UInt8(value >> 8)
  } else if offset == 16 {
    info.mapAddress = value
  } else if offset == 24 {
    info.mapCount = value
  } else if offset == 32 {
    info.rsdp = value
  } else if offset == 40 {
    info.deviceTree = value
  } else if offset == 48 {
    info.uefiTable = value
  } else if offset == 56 {
    info.framebuffer = value
  } else if offset == 80 {
    info.bootSet = value
  } else if offset == 88 {
    info.bootSetSize = value
  } else if offset == 96 {
    info.entropy0 = value
  } else if offset == 104 {
    info.entropy1 = value
  } else if offset == 112 {
    info.entropy2 = value
  } else if offset == 120 {
    info.entropy3 = value
  } else if offset == 128 {
    info.entropy4 = value
  } else if offset == 136 {
    info.entropy5 = value
  } else if offset == 144 {
    info.entropy6 = value
  } else if offset == 152 {
    info.entropy7 = value
  } else if offset == 160 {
    info.logAddress = value
  } else if offset == 168 {
    info.logSize = value
  } else if offset == 184 {
    info.kernelVirtual = value
  } else if offset == 192 {
    info.kernelPhysical = value
  } else if offset == 200 {
    info.options = value
  } else if offset == 208 {
    info.panicRecord = value
  } else {
    return value == 0
  }
  return true
}

public struct BootDecoder {
  fileprivate var info: BootInfo
  fileprivate var nextByte: UInt64
  fileprivate var pending: UInt64
  fileprivate var invalid: Bool

  public var decoded: BootInfo? { completeBootInfo(self) ? info : nil }
}

public func beginBootInfo(_ address: UInt64, capacity: UInt64) -> BootDecoder {
  return BootDecoder(
    info: emptyBootInfo(), nextByte: 0, pending: 0,
    invalid: !bootBlockFits(address, capacity: capacity))
}

public func acceptBootByte(_ state: inout BootDecoder, byte: UInt8) -> Bool {
  if state.invalid || state.nextByte >= 4096 {
    state.invalid = true
    return false
  }
  let index = state.nextByte & 7
  state.pending = state.pending | (UInt64(byte) << (index * 8))
  state.nextByte += 1
  if index == 7 {
    state.invalid = !unpackBootWord(&state.info, offset: state.nextByte - 8, value: state.pending)
    state.pending = 0
  }
  return !state.invalid
}

// The caller checks the producing train against the 52-entry release history
// and validates all external physical spans before handing these to the MM.
public func completeBootInfo(_ state: BootDecoder) -> Bool {
  return !state.invalid && state.nextByte == 4096 && validBootInfo(state.info)
}
