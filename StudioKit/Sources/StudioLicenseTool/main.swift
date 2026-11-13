import CryptoKit
import Foundation
import StudioLicense

// Development helper. Usage:
//   studio-license-tool keygen
//   studio-license-tool fingerprint <productId>
//   studio-license-tool sign <privateKeyBase64> <productId> [maxMajorVersion]   (signs for this Mac)
//   studio-license-tool serve <privateKeyBase64> [port] [maxMajorVersion]      (mock license server)
//   studio-license-tool check <publicKeyBase64> <productId> <appGroup | file.license> [majorVersion]

let usage = """
    commands:
      keygen
      fingerprint <productId>
      sign <privateKeyBase64> <productId> [maxMajorVersion]
      serve <privateKeyBase64> [port=8787] [maxMajorVersion]
      check <publicKeyBase64> <productId> <appGroupIdentifier | file.license> [majorVersion=1]
    """

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch arguments.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("privateKey (server only): \(key.rawRepresentation.base64EncodedString())")
    print("publicKey  (apps):        \(key.publicKey.rawRepresentation.base64EncodedString())")

case "fingerprint":
    guard arguments.count == 2 else { fail("usage: fingerprint <productId>") }
    print(MachineIdentity.fingerprint(productId: arguments[1]) ?? "unavailable")

case "sign":
    guard arguments.count >= 3 else { fail("usage: sign <privateKeyBase64> <productId> [maxMajorVersion]") }
    let productId = arguments[2]
    guard let fingerprint = MachineIdentity.fingerprint(productId: productId) else { fail("no machine identity") }
    let token = LicenseToken(
        licenseId: "lic_dev",
        activationId: "act_dev",
        productId: productId,
        edition: "dev",
        machineFingerprint: fingerprint,
        issuedAt: .now,
        maxMajorVersion: arguments.count > 3 ? Int(arguments[3]) : nil
    )
    do {
        let license = try LicenseSigner(privateKeyBase64: arguments[1]).sign(token)
        print(String(decoding: try license.encoded(), as: UTF8.self))
    } catch {
        fail("signing failed: \(error)")
    }

case "serve":
    guard arguments.count >= 2, let signer = try? LicenseSigner(privateKeyBase64: arguments[1]) else {
        fail("usage: serve <privateKeyBase64> [port] [maxMajorVersion]")
    }
    let port = arguments.count > 2 ? UInt16(arguments[2]) ?? 8787 : 8787
    let maxMajorVersion = arguments.count > 3 ? Int(arguments[3]) : nil
    print("Public key matching this server: \(signer.publicKeyBase64)")
    do {
        try MockLicenseServer(signer: signer, maxMajorVersion: maxMajorVersion).run(port: port)
    } catch {
        fail("could not start server: \(error)")
    }

case "check":
    // Reads the installed license exactly like the FxPlug will.
    guard arguments.count >= 4 else { fail("usage: check <publicKeyBase64> <productId> <appGroupIdentifier | file.license> [majorVersion]") }
    let majorVersion = arguments.count > 4 ? Int(arguments[4]) ?? 1 : 1
    guard let verifier = try? LicenseVerifier(publicKeyBase64: arguments[1], productId: arguments[2], majorVersion: majorVersion) else {
        fail("invalid public key")
    }
    if arguments[3].hasSuffix(".license") {
        // A license file, e.g. saved from your server's response for testing.
        guard let data = FileManager.default.contents(atPath: arguments[3]) else { fail("cannot read \(arguments[3])") }
        guard let license = try? SignedLicense(data: data) else { fail("Status: invalid(malformed)") }
        print("Status: \(verifier.verify(license))")
    } else {
        // This tool has no App Group entitlement, so build the container path directly.
        let store = LicenseStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/\(arguments[3])/Licenses"))
        print("License file: \(store.fileURL(productId: arguments[2]).path)")
        print("Status: \(verifier.status(in: store))")
    }

default:
    fail(usage)
}
