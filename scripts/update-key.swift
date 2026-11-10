// Ed25519 keys and signatures for Deckhand updates.
//   swift scripts/update-key.swift generate        prints "private-base64 public-base64"
//   UPDATE_KEY=... swift scripts/update-key.swift sign FILE    prints the signature of FILE in base64
//   swift scripts/update-key.swift verify FILE SIGNATURE PUBLIC    exits 0 when the signature is valid
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst()
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch args.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: sign FILE") }
    guard let raw = ProcessInfo.processInfo.environment["UPDATE_KEY"].flatMap({ Data(base64Encoded: $0) }),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("UPDATE_KEY is missing or invalid") }
    guard let data = FileManager.default.contents(atPath: Array(args)[1]) else { fail("cannot read file") }
    print(try key.signature(for: data).base64EncodedString())
case "verify":
    let a = Array(args)
    guard a.count == 4, let data = FileManager.default.contents(atPath: a[1]),
          let sig = Data(base64Encoded: a[2]), let pubRaw = Data(base64Encoded: a[3]),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { fail("usage: verify FILE SIGNATURE PUBLIC") }
    exit(pub.isValidSignature(sig, for: data) ? 0 : 1)
default:
    fail("usage: generate | sign FILE | verify FILE SIGNATURE PUBLIC")
}
