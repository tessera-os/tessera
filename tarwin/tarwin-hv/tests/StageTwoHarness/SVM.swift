// Private VMCB and fixed state for the two single-CPU long-mode diagnostics.
func configureSVM(_ vmcb: UnsafeMutableRawPointer, root: UInt64, cr3: UInt64, rip: UInt64) {
  func put<T: FixedWidthInteger>(_ offset: Int, _ value: T) {
    vmcb.storeBytes(of: value, toByteOffset: offset, as: T.self)
  }
  put(8, UInt32.max)  // intercept exceptions
  put(0xc, UInt32.max)  // intercept I/O, control and external events
  put(0x10, UInt32.max)  // including VMRUN and VMMCALL
  put(0x58, UInt32(1))  // ASID
  put(0x90, UInt64(1))  // nested paging
  put(0xb0, root)
  for seg in 0..<4 {  // ES, CS, SS, DS
    let off = 0x400 + seg * 16
    put(off, UInt16(seg == 1 ? 8 : 16))
    put(off + 2, UInt16(seg == 1 ? 0xa9b : 0xc93))
    put(off + 4, UInt32.max)
  }
  put(0x4d0, UInt64(0x1d00))  // EFER: SVME, NXE, LMA, LME
  put(0x548, UInt64(0x20))
  put(0x550, cr3)
  put(0x558, UInt64(0x8001_0011))
  put(0x560, UInt64(0x400))
  put(0x570, UInt64(2))
  put(0x578, rip)
}
