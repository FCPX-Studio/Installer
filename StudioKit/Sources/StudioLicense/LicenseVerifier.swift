import CryptoKit
import Foundation

public enum LicenseFailure: Sendable, Equatable {
    case malformed
    case unsupportedAlgorithm
    case unsupportedFormat
    case badSignature
    case wrongProduct
    case wrongMachine
    case machineUnavailable
}

public enum LicenseStatus: Sendable, Equatable {
    case valid(LicenseToken)
    case missing
    case invalid(LicenseFailure)
    case expired(LicenseToken)
    /// Valid license, but for an older major version than the running plugin.
    case versionNotCovered(LicenseToken)

    public var isLicensed: Bool {
        if case .valid = self { return true }
        return false
    }
}

public enum LicenseVerifierError: Error {
    case invalidPublicKey
}

/// Offline license check. Cheap enough to run when the plugin loads; cache the result
/// rather than calling it for every rendered frame.
public struct LicenseVerifier: Sendable {
    public let productId: String
    public let majorVersion: Int
    private let publicKey: Data
    private let machineFingerprint: String?

    /// - Parameters:
    ///   - publicKeyBase64: raw 32-byte Ed25519 public key, base64-encoded.
    ///   - majorVersion: major version of the running plugin, compared to `maxMajorVersion`.
    public init(publicKeyBase64: String, productId: String, majorVersion: Int) throws {
        try self.init(
            publicKeyBase64: publicKeyBase64,
            productId: productId,
            majorVersion: majorVersion,
            machineFingerprint: MachineIdentity.fingerprint(productId: productId)
        )
    }

    init(publicKeyBase64: String, productId: String, majorVersion: Int, machineFingerprint: String?) throws {
        guard let key = Data(base64Encoded: publicKeyBase64),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil
        else { throw LicenseVerifierError.invalidPublicKey }
        self.publicKey = key
        self.productId = productId
        self.majorVersion = majorVersion
        self.machineFingerprint = machineFingerprint
    }

    /// Loads the license from `store` and verifies it.
    public func status(in store: LicenseStore, now: Date = .now) -> LicenseStatus {
        do {
            guard let license = try store.load(productId: productId) else { return .missing }
            return verify(license, now: now)
        } catch {
            return .invalid(.malformed)
        }
    }

    public func verify(_ license: SignedLicense, now: Date = .now) -> LicenseStatus {
        guard license.signatureAlgorithm == SignedLicense.ed25519 else { return .invalid(.unsupportedAlgorithm) }
        guard let payload = Data(base64Encoded: license.payload),
              let signature = Data(base64Encoded: license.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return .invalid(.malformed) }

        // Authenticity first: nothing in the payload is trusted before this succeeds.
        guard key.isValidSignature(signature, for: payload) else { return .invalid(.badSignature) }
        guard let token = try? JSONDecoder.licenseToken.decode(LicenseToken.self, from: payload) else {
            return .invalid(.malformed)
        }
        guard token.formatVersion == LicenseToken.currentFormatVersion else { return .invalid(.unsupportedFormat) }
        guard token.productId == productId else { return .invalid(.wrongProduct) }
        guard let machineFingerprint else { return .invalid(.machineUnavailable) }
        guard token.machineFingerprint == machineFingerprint else { return .invalid(.wrongMachine) }
        if let expiresAt = token.expiresAt, expiresAt <= now { return .expired(token) }
        if let maxMajor = token.maxMajorVersion, majorVersion > maxMajor { return .versionNotCovered(token) }
        return .valid(token)
    }
}
