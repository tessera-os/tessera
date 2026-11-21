// Stage-0 Swift bridge until the TIR compiler emits all three base variants.
// Only compile this fixed instruction into the signed native user library.
import Foundation

enum BaseISA: String { case aarch64, x86_64, riscv64 }

func gate(_ isa: BaseISA) -> String {
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
    "define hidden void @libtessera_tarwin_enter(i64 %number, ptr nocapture readonly %words, ptr nocapture writeonly %out) nounwind {\n"
  var args = [String]()
  for i in inputs.indices {
    ir +=
      "%src\(i) = getelementptr i64, ptr %words, i64 \(i)\n%a\(i) = load i64, ptr %src\(i), align 8\n"
    args.append("i64 %a\(i)")
  }
  args.append("i64 %number")
  ir +=
    "%r = call \(result) asm sideeffect \"\(op)\", \"\(constraints)\"(\(args.joined(separator:",")))\n"
  for i in outputs.indices {
    ir +=
      "%v\(i) = extractvalue \(result) %r, \(i)\n%dst\(i) = getelementptr i64, ptr %out, i64 \(i)\nstore i64 %v\(i), ptr %dst\(i), align 8\n"
  }
  return ir + "ret void\n}"
}

guard CommandLine.arguments.count == 2, let isa = BaseISA(rawValue: CommandLine.arguments[1]) else {
  exit(2)
}
print(gate(isa))
