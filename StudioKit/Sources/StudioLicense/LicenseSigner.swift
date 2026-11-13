import CryptoKit
import Foundation

/// Produces `SignedLicense` values exactly like the server must.
///
/// Used by the tests and by `studio-license-tool`. It is the reference implementation
/// for the server: sign the UTF-8 JSON bytes of the token, then base64 both parts.
/// The type itself is harmless; a real private key must never be embedded in a shipping product.
public struct LicenseSigner {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKeyBase64: String) throws {
        guard let raw = Data(base64Encoded: privateKeyBase64) else { throw LicenseVerifierError.invalidPublicKey }
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public func sign(_ token: LicenseToken) throws -> SignedLicense {
        try sign(payload: JSONEncoder.licenseToken.encode(token))
    }

    public func sign(payload: Data) throws -> SignedLicense {
        let signature = try privateKey.signature(for: payload)
        return SignedLicense(payload: payload.base64EncodedString(), signature: signature.base64EncodedString())
    }
}
