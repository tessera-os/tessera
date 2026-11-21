import TIRModel
import TIRTarget
import Testing
@testable import TarwinProfileCheck

@Test func rejectsWrongProfileTargetOrEmptyBodies() {
  let name = "KCore"
  for module in [Module(name: name, profile: .app, platform: .tessera),
                 Module(name: name, profile: .kernel, platform: .portable),
                 Module(name: name, profile: .kernel, platform: .tessera),
                 Module(name: "Wrong", profile: .kernel, platform: .tessera)] {
    #expect(throws: CheckError.self) { try check(module, named: name) }
  }
}

private func fixture() -> Module {
  var module = Module(name: "KCore", profile: .kernel, platform: .tessera)
  module.languages = ["swift"]
  var attrs = FunctionAttributes()
  attrs.isNoUnwind = true
  module.functions = ["arm", "intel", "riscv", "portable"].map {
    Function(name: $0, attributes: attrs, blocks: [Block(id: BlockID(0), instructions: [Instruction(.return)])])
  }
  return module
}

@Test func checksProfileAndIR() throws {
  var module = fixture()
  try check(module, named: module.name)
  module.functions[0].attributes.isNoUnwind = false
  #expect(throws: CheckError.self) { try check(module, named: module.name) }
  module.functions[0].attributes.isNoUnwind = true
  module.functions[0].blocks[0].instructions = []
  #expect(throws: CheckError.self) { try check(module, named: module.name) }
}

@Test func assemblyRequiresThreeFeatureFreeBaseBodies() throws {
  var module = fixture()
  module.functions[0].blocks[0].instructions.insert(Instruction(.asm), at: 0)
  #expect(throws: CheckError.self) { try checkVariants(module) }
  module.variantSets = [VariantSet(name: "variants", members: [
    .init(architecture: .aarch64, function: "arm"), .init(architecture: .x64, function: "intel"),
    .init(architecture: .rv64, features: ["optional"], function: "riscv"), .init(architecture: nil, function: "portable")])]
  #expect(throws: CheckError.self) { try checkVariants(module) }
  module.variantSets[0].members[2].features = []
  try checkVariants(module)
  module.variantSets[0].members[3].function = "arm"
  #expect(throws: CheckError.self) { try checkVariants(module) }
}
