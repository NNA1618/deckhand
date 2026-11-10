import CryptoKit
import Foundation

extension SelfTest {
    /// The updater's version rule, signature check and manifest format. No network.
    static func updates(_ check: Check) {
        let url = URL(string: "https://github.com/NNA1618/deckhand/releases/download/v0.6.0/Deckhand.zip")!
        var manifest = UpdateManifest(version: "0.6.0", build: 7, url: url, signature: "", minimumSystem: "15.0", notes: nil)
        let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
        check(Updater.isNewer(manifest, than: 6, system: sequoia), "update: a higher build is newer")
        check(!Updater.isNewer(manifest, than: 7, system: sequoia), "update: the same build is not newer")
        check(!Updater.isNewer(manifest, than: 8, system: sequoia), "update: never downgrades")
        manifest.minimumSystem = "26.1"
        check(!Updater.isNewer(manifest, than: 6, system: sequoia), "update: skips a build the system can't run")
        check(Updater.isNewer(manifest, than: 6, system: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)),
              "update: minimum system is inclusive")

        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("Deckhand.zip bytes".utf8)
        let signature = (try? key.signature(for: data).base64EncodedString()) ?? ""
        check(Updater.verify(data, signature: signature, publicKey: pub), "update: a good signature passes")
        check(!Updater.verify(Data("tampered".utf8), signature: signature, publicKey: pub), "update: a changed archive fails")
        check(!Updater.verify(data, signature: signature), "update: a signature from another key fails")
        check(!Updater.verify(data, signature: "not base64"), "update: a broken signature fails")
        check(Data(base64Encoded: UpdateKey.publicKey)?.count == 32, "update: the built-in public key is an Ed25519 key")

        let json = #"{"version":"0.6.0","build":7,"url":"https://example.com/D.zip","signature":"abc","minimumSystem":"15.0","notes":{"en":"New","ru":"Новое"}}"#
        let decoded = try? JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        check(decoded?.build == 7 && decoded?.notes?["ru"] == "Новое", "update: manifest decodes")
    }
}
