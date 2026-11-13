import Foundation
import StudioLicense

public struct ActivationRequest: Codable, Sendable {
    public var licenseKey: String
    public var productId: String
    public var machineFingerprint: String
    public var machineName: String
    public var appVersion: String
    public var macOSVersion: String

    public init(
        licenseKey: String,
        productId: String,
        machineFingerprint: String,
        machineName: String,
        appVersion: String,
        macOSVersion: String
    ) {
        self.licenseKey = licenseKey
        self.productId = productId
        self.machineFingerprint = machineFingerprint
        self.machineName = machineName
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
    }
}

/// The activation is definitive. Activating the same Mac again returns the same `activationId`.
public struct ActivationResponse: Codable, Sendable {
    public var activationId: String
    public var license: SignedLicense
    public var activationLimit: Int
    public var activationsUsed: Int
}

public enum LicenseAPIError: LocalizedError, Sendable {
    /// Error reported by the server, e.g. `invalid_key`, `license_expired`, `activation_limit_reached`, `revoked`.
    case server(status: Int, code: String, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .server(_, _, let message): message
        case .invalidResponse: "The license server returned an unexpected response."
        }
    }
}

/// HTTPS client for the license server.
///
/// Expected error body for any non-2xx status: `{"error": {"code": "...", "message": "..."}}`.
public struct LicenseAPIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `POST /v1/licenses/activate`
    public func activate(_ request: ActivationRequest) async throws -> ActivationResponse {
        try await post("v1/licenses/activate", body: request)
    }

    /// `POST /v1/licenses/deactivate`, frees the activation slot of this Mac.
    ///
    /// Both values come from the signed token stored on this Mac, so the license key is not needed.
    public func deactivate(activationId: String, machineFingerprint: String) async throws {
        let _: Empty = try await post("v1/licenses/deactivate", body: [
            "activationId": activationId,
            "machineFingerprint": machineFingerprint,
        ])
    }

    private struct Empty: Decodable {}
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseAPIError.invalidResponse }

        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw LicenseAPIError.server(status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw LicenseAPIError.invalidResponse
        }
        if Response.self == Empty.self, let empty = Empty() as? Response { return empty }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LicenseAPIError.invalidResponse
        }
    }
}
