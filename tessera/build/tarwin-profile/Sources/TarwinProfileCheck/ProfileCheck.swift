import Foundation
import KLFLanguage
import KLFSession
import KLFSource
import SwiftLanguage
import TIRBinary
import TIRModel
import TIRTarget
import TIRVerify

struct CheckError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

// Never retag hosted output as kernel, even when it contains only scalar code.
func check(_ module: Module, named name: String) throws {
  guard module.name == name else { throw CheckError("unexpected module: " + module.name) }
  guard module.profile == .kernel && module.platform == .tessera else {
    throw CheckError("compiler emitted " + module.profile.keyword + "/" + module.platform.keyword + "; required kernel/tessera")
  }
  guard module.functions.contains(where: { !$0.isDeclaration }) else { throw CheckError("no function bodies") }
  guard module.version == .current, module.languages == ["swift"] else { throw CheckError("expected current Swift TIR") }
  guard module.functions.allSatisfy({ $0.attributes.engine == .native && $0.attributes.isNoUnwind && !$0.isGPU })
    else { throw CheckError("kernel functions must be native CPU nounwind functions") }
  let diagnostics = Verifier().verify(module)
  if diagnostics.hasErrors { throw CheckError(diagnostics.diagnostics.map(\.description).joined(separator: "\n")) }
  try checkVariants(module)
}

func checkVariants(_ module: Module) throws {
  let architectures: Set<CPUArchitecture> = [.aarch64, .x64, .rv64]
  let assembly = Set(module.functions.filter { function in
    function.allInstructions.contains { $0.instruction.opcode == .asm || $0.instruction.opcode == .asmGoto }
  }.map(\.name))
  var covered: Set<String> = []
  for set in module.variantSets {
    var bases: Set<CPUArchitecture> = []
    var hasPortable = false
    var hasAssembly = false
    for member in set.members {
      guard let body = module.function(named: member.function), !body.isDeclaration
        else { throw CheckError("missing variant body in " + set.name) }
      if assembly.contains(member.function) {
        guard let arch = member.architecture, architectures.contains(arch)
          else { throw CheckError("assembly outside a CPU variant: " + member.function) }
        covered.insert(member.function)
        hasAssembly = true
      }
      guard member.features.isEmpty else { continue }
      if let arch = member.architecture { bases.insert(arch) } else { hasPortable = true }
    }
    guard (!hasAssembly && hasPortable) || architectures.isSubset(of: bases)
      else { throw CheckError("TIR-ARCH-0003: missing base variants in " + set.name) }
  }
  guard assembly.isSubset(of: covered) else { throw CheckError("assembly outside a variant set") }
}

func compile(_ sources: [SourceFile], named name: String) async throws -> Data {
  let session = Session(options: SessionOptions(packageName: name, platform: .tessera), sources: sources)
  let modules: [Module]
  do { modules = try await SwiftLanguage().compile(in: session) } catch {
    let details = await session.diagnostics.diagnostics.map(\.description).joined(separator: "\n")
    throw CheckError(details.isEmpty ? String(describing: error) : details)
  }
  guard !(await session.hasErrors), modules.count == 1, let module = modules.first else {
    throw CheckError("compiler did not emit one complete module")
  }
  try check(module, named: name)
  let bytes = try TIRBinaryWriter.encode(module)
  try check(TIRBinaryReader(verifiesCanonicalEncoding: true).read(bytes), named: name)
  return Data(bytes)
}

@main enum ProfileCheck {
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count >= 3 else { throw CheckError("usage: tarwin-profile-check MODULE NEW-OUTPUT.tirb INPUT.swift ...") }
      let out = URL(fileURLWithPath: args[1])
      guard !FileManager.default.fileExists(atPath: out.path) else { throw CheckError("output already exists: " + out.path) }
      let sources = try args.dropFirst(2).map { path in
        SourceFile(path: path, text: try String(contentsOfFile: path, encoding: .utf8))
      }
      try await compile(sources, named: args[0]).write(to: out, options: .withoutOverwriting)
    } catch {
      FileHandle.standardError.write(Data(("\(error)\n").utf8))
      exit(1)
    }
  }
}
