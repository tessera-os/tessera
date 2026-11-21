import CryptoKit
import Foundation
import TarwinLoader

// Issuance check for the single freeze supported by the debug W1 runtime.
// The expected contract is a producer input, not a claim from the images.
func verifyUserPair(_ executable: Data, _ library: Data, machine: UInt16) throws {
  let uuid = UUID(uuidString: "6F1B36CB-CA46-4ED8-9885-486FCCF2A255")!
  let name = Data("_RIDL110LibTessera14processCurrentF_v6f1b36cbca464ed8".utf8)
  let text = Data("struct Handle { let raw : U64 } function processCurrent ( ) -> Handle".utf8)
  var hashes = stack()
  let accepted = withUnsafeBytes(of: uuid.uuid) { id in
    SHA256.hash(data: text).withUnsafeBytes { digest in
      name.withUnsafeBytes { n in
        let contract = EarlyRIDLContract(uuid: id, symbol: n, textSHA256: digest, typeTag: 0x8b65_40d3)
        return contract.isW1ProcessCurrent && executable.withUnsafeBytes { e in
          library.withUnsafeBytes { l in
            hashes.withUnsafeMutableBufferPointer { scratch in
              inspectEarlyRIDLBinding(executable: e, framework: l, machine: machine,
                addressLimit: 1 << 32, scratch: scratch, contract: contract) != nil
            }
          }
        }
      }
    }
  }
  try require(accepted, "W1 images do not bind the independently frozen processCurrent ABI")
}
