import Foundation

/// Claims signed by the license server. Dates are ISO 8601 (`2026-02-10T12:00:00Z`).
public struct LicenseToken: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var licenseId: String
    public var activationId: String
    public var productId: String
    public var edition: String
    public var machineFingerprint: String
    public var issuedAt: Date
    /// `nil` for a perpetual license.
    public var expiresAt: Date?
    /// Highest major version of the plugin covered by the license; `nil` means all versions.
    public var maxMajorVersion: Int?

    public init(
        formatVersion: Int = LicenseToken.currentFormatVersion,
        licenseId: String,
        activationId: String,
        productId: String,
        edition: String,
        machineFingerprint: String,
        issuedAt: Date,
        expiresAt: Date? = nil,
        maxMajorVersion: Int? = nil
    ) {
        self.formatVersion = formatVersion
        self.licenseId = licenseId
        self.activationId = activationId
        self.productId = productId
        self.edition = edition
        self.machineFingerprint = machineFingerprint
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.maxMajorVersion = maxMajorVersion
    }
}

/// The license file as returned by the server and stored on disk.
///
/// `payload` holds the exact bytes that were signed (base64 of the UTF-8 JSON of a
/// `LicenseToken`). The signature is checked against those bytes, never against a
/// re-serialized JSON, whose key order or formatting could differ.
public struct SignedLicense: Codable, Sendable, Equatable {
    public static let ed25519 = "Ed25519"

    public var payload: String
    public var signatureAlgorithm: String
    public var signature: String

    public init(payload: String, signatureAlgorithm: String = SignedLicense.ed25519, signature: String) {
        self.payload = payload
        self.signatureAlgorithm = signatureAlgorithm
        self.signature = signature
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(SignedLicense.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension JSONDecoder {
    static let licenseToken: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let licenseToken: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
