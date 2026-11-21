import TarwinArchAarch64

@_extern(c, "tarwin_w1_load_user_word")
private func load(_ address: UInt64, _ word: UnsafeMutablePointer<UInt64>) -> UInt32

@_extern(c, "tarwin_w1_store_user_word")
private func store(_ address: UInt64, _ word: UInt64) -> UInt32

private struct ProbeRoots: ~Copyable {
  let host: ArmFinishedKernelRoot
  let a, b: ArmFinishedUserRoot
}

// Before enabling the MMU the test CPU owns and can address all three
// table arenas physically. None is mapped writable in either finished root.
@_cdecl("tarwin_vhe_build_roots")
public func buildRoots(
  _ kernel: UInt64, _ a: UInt64, _ b: UInt64, _ stack: UInt64,
  _ context: UInt64, _ text: UInt64, _ sample: UInt64, _ scheduler: UInt64
) -> UInt32 {
  let high: UInt64 = 0xffff_8000_0000_0000
  let page: UInt64 = 16384
  let base: UInt64 = 1 << 32
  func arena(_ p: UInt64, pages: Int = 4) -> UnsafeMutableRawBufferPointer {
    .init(start: UnsafeMutableRawPointer(bitPattern: UInt(p)), count: pages * 16384)
  }
  #if TEST_GCS
    let layout = ArmPermissionLayout.guarded
  #else
    let layout = ArmPermissionLayout.direct
  #endif
  guard var k = ArmKernelTranslation(backing: arena(kernel), physical: kernel, layout: layout),
    var p = ArmUserTranslation(backing: arena(a), physical: a),
    var q = ArmUserTranslation(backing: arena(b, pages: 7), physical: b, layout: layout)
  else { return 1 }
  for i: UInt64 in 0..<2 {
    let pa = text + i * page
    guard k.insert(virtual: high + pa, physical: pa, write: false, execute: true) else { return 2 }
  }
  for i: UInt64 in 0..<2 {
    let pa = stack + i * page
    let next = scheduler + i * page
    guard k.insert(virtual: high + pa, physical: pa, write: true, execute: false),
      k.insert(virtual: high + next, physical: next, write: true, execute: false)
    else { return 3 }
  }
  guard
    let stacks = ArmStopStacks(
      tables: k, outgoingVA: high + stack, outgoingPA: stack,
      schedulerVA: high + scheduler, schedulerPA: scheduler),
    let storage = UnsafeMutablePointer<ArmStopStacks>(bitPattern: UInt(context + 64))
  else { return 3 }
  storage.initialize(to: stacks)
  #if TEST_GCS
    let shadow = (UInt64(1) << 43) + page
    let ro = base + 2 * page
    guard q.insertControlPage(virtual: shadow, physical: sample + 3 * page),
      q.insert(virtual: base + 4 * page, physical: sample + 6 * page, write: false, execute: true),
      q.insert(virtual: shadow + 7 * page, physical: sample + 7 * page, write: true, execute: false),
      q.insert(virtual: shadow + 9 * page, physical: sample + 8 * page, write: true, execute: false),
      q.mapsControlPage(shadow, physical: sample + 3 * page),
      q.insert(virtual: ro, physical: sample + 4 * page, write: true, execute: false),
      q.sealReadOnly(ro..<ro + page),
      q.insert(virtual: ro + page, physical: sample + 5 * page, write: true, execute: false),
      let gcs = ArmInitialControlStack(tables: q, shadow: shadow..<shadow + page,
        physical: sample + 3 * page, stackBytes: 8 * page)
    else { return 5 }
    let bank = UnsafeMutablePointer<UInt64>(bitPattern: UInt(context + 32))!
    bank[0] = gcs.root
    bank[1] = gcs.pointer
    bank[2] = ArmInitialControlStack.control
  #endif
  guard k.insert(virtual: high + context, physical: context, write: true, execute: false),
    p.insert(virtual: base, physical: sample, write: false, execute: false),
    q.insert(virtual: base, physical: sample + page, write: false, execute: false),
    let kr = k.finish(), let ar = p.finish(), let br = q.finish(),
    kr.physical == kernel, ar.physical == a, br.physical == b,
    kr.layout == layout, ar.layout == .direct, br.layout == layout
  else { return 4 }
  UnsafeMutablePointer<ProbeRoots>(bitPattern: UInt(context + 128))!.initialize(
    to: ProbeRoots(host: kr, a: ar, b: br))
  return 0
}

@_cdecl("tarwin_vhe_switch")
public func switchRoot(_ context: UInt64, _ second: UInt32) -> UInt32 {
  let roots = UnsafePointer<ProbeRoots>(bitPattern: UInt(context + 128))!
  if second == 0 { return switchArmUserRoot(roots.pointee.a, host: roots.pointee.host) ? 1 : 0 }
  return switchArmUserRoot(roots.pointee.b, host: roots.pointee.host) ? 1 : 0
}

// This diagnostic captures no task. It exercises only the checked stack
// selection and pivot, with a synthetic trap frame on the outgoing stack.
@_cdecl("tarwin_w1_stop_stack_top")
public func destination(_ context: UInt64, _ frame: UInt64, _ root: UInt64) -> UInt64 {
  guard let storage = UnsafePointer<ArmStopStacks>(bitPattern: UInt(context + 64)) else { return 0 }
  return storage.pointee.destination(frame: frame, hostRoot: root) ?? 0
}

// Called on a private host stack. The diagnostic never enters EL0.
@_cdecl("tarwin_vhe_copy_probe")
public func probe() -> Int32 {
  let base: UInt64 = 1 << 32
  var pair = InlineArray<2, UInt64>(repeating: .max)
  return withUnsafeMutableBytes(of: &pair) { bytes in
    let words = bytes.bindMemory(to: UInt64.self)
    func copy(_ at: UInt64) -> Bool {
      copyArmUserWords(from: at, range: base..<base + 5 * 16384, into: words) {
        load($0, $1) == 1
      }
    }
    func write(_ at: UInt64) -> Bool {
      writeArmUserWords(to: at, range: base..<base + 5 * 16384, from: .init(words)) {
        store($0, $1) == 1
      }
    }
    guard copy(base), words[0] == 0x1234, words[1] == 0x5678 else { return 1 }
    // Last word is readable; the next page faults. No partial result survives.
    guard !copy(base + 16384 - 8), words[0] == 0 && words[1] == 0 else { return 2 }
    guard !copy(base + 32768), words[0] == 0 && words[1] == 0 else { return 3 }
    words[0] = 0xabcd
    words[1] = 0x9876
    let rw = base + 3 * 16384
    guard write(rw), copy(rw), words[0] == 0xabcd, words[1] == 0x9876 else { return 4 }
    guard !write(base), !write(base + 16384), !write(base + 32768),
      copy(base), words[0] == 0x1234, words[1] == 0x5678
    else { return 5 }
    guard !write(rw + 16384 - 8), !write(rw + 3), !write(base - 8) else { return 6 }
    return 0
  }
}
