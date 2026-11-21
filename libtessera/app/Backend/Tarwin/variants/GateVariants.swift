// Stage-0 Swift bridge until the TIR compiler emits all three base variants.
// Only compile this fixed instruction into the signed native user library.
import Foundation

enum BaseISA: String { case aarch64, x86_64, riscv64 }

func gate(_ isa: BaseISA, scalarHandle: Bool = false) -> String {
  let op: String
  let outputs: [String]
  let inputs: [String]
  let number: String
  let clobbers: [String]
  switch isa {
  case .aarch64:
    op = "svc #0"
    outputs = ["={x0}", "={x1}", "={x2}", "={x3}"]
    inputs = ["0", "1", "2", "3", "{x4}", "{x5}", "{x6}", "{x7}"]
    number = "{x16}"
    clobbers = ["~{memory}"]
  case .x86_64:
    op = "syscall"
    outputs = ["={ax}", "={dx}", "={si}", "={di}"]
    inputs = ["3", "2", "1", "{r10}", "{r8}", "{r9}"]
    number = "0"
    clobbers = ["~{rcx}", "~{r11}", "~{cc}", "~{memory}"]
  case .riscv64:
    op = "ecall"
    outputs = ["={a0}", "={a1}", "={a2}", "={a3}"]
    inputs = ["0", "1", "2", "3", "{a4}", "{a5}", "{a6}"]
    number = "{a7}"
    clobbers = ["~{memory}"]
  }
  let constraints = (outputs + inputs + [number] + clobbers).joined(separator: ",")
  let result = "{i64,i64,i64,i64}"
  var ir =
    scalarHandle
    ? "define hidden i64 @libtessera_tarwin_current_gate() nounwind {\n"
    : "define hidden void @libtessera_tarwin_enter(i64 %number, ptr nocapture readonly %words, ptr nocapture writeonly %out) nounwind {\n"
  var args = [String]()
  for i in inputs.indices {
    if scalarHandle {
      args.append("i64 0")
      continue
    }
    ir +=
      "%src\(i) = getelementptr i64, ptr %words, i64 \(i)\n%a\(i) = load i64, ptr %src\(i), align 8\n"
    args.append("i64 %a\(i)")
  }
  args.append(scalarHandle ? "i64 \(TarwinCall.processCurrent)" : "i64 %number")
  ir +=
    "%r = call \(result) asm sideeffect \"\(op)\", \"\(constraints)\"(\(args.joined(separator:",")))\n"
  if scalarHandle {
    return ir + """
      %status = extractvalue \(result) %r, 0
      %name = extractvalue \(result) %r, 2
      %ok = icmp eq i64 %status, 0
      %handle = select i1 %ok, i64 %name, i64 0
      ret i64 %handle
      }
      """
  }
  for i in outputs.indices {
    ir +=
      "%v\(i) = extractvalue \(result) %r, \(i)\n%dst\(i) = getelementptr i64, ptr %out, i64 \(i)\nstore i64 %v\(i), ptr %dst\(i), align 8\n"
  }
  return ir + "ret void\n}"
}

@main struct GenerateGate {
  static func main() {
    let args = CommandLine.arguments
    guard (2...3).contains(args.count), let isa = BaseISA(rawValue: args[1]),
      args.count == 2 || (isa == .aarch64 && args[2] == "--w1-process-current")
    else { exit(2) }
    print(gate(isa, scalarHandle: args.count == 3))
  }
}
