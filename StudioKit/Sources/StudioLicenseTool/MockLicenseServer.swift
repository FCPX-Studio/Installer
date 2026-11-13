import Foundation
import Network
import StudioLicense

/// Minimal in-memory implementation of the license server contract (see README), for
/// testing installers locally. Keys are interpreted by prefix:
/// `TEST-` perpetual, `TRIAL-` expires in 30 days, `EXPIRED-` expired trial,
/// `REVOKED-` revoked, anything else unknown. Each key allows 2 Macs.
final class MockLicenseServer: @unchecked Sendable {
    private struct Activation {
        var licenseKey: String
        var productId: String
        var fingerprint: String
        var license: SignedLicense
    }

    private struct HTTPError: Error {
        var status: Int
        var code: String
        var message: String
    }

    private struct ActivateBody: Decodable {
        var licenseKey: String
        var productId: String
        var machineFingerprint: String
        var machineName: String
    }

    private struct DeactivateBody: Decodable {
        var activationId: String
        var machineFingerprint: String
    }

    private let signer: LicenseSigner
    private let activationLimit = 2
    private let maxMajorVersion: Int?
    // All state is only touched on `queue`.
    private let queue = DispatchQueue(label: "mock-license-server")
    private var activations: [String: Activation] = [:]
    /// Like the `ExpirationDate` column of a real database: fixed per key, set on first use.
    private var trialExpirations: [String: Date] = [:]

    init(signer: LicenseSigner, maxMajorVersion: Int?) {
        self.signer = signer
        self.maxMajorVersion = maxMajorVersion
    }

    func run(port: UInt16) throws -> Never {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { fail("invalid port") }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        print("Mock license server on http://127.0.0.1:\(port)")
        print("Keys: TEST-… perpetual, TRIAL-… 30-day trial, EXPIRED-…, REVOKED-…; \(activationLimit) Macs per key. Ctrl-C to stop.")
        dispatchMain()
    }

    // MARK: - HTTP plumbing

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (path, body) = parseRequest(buffer) {
                respond(on: connection, route(path: path, body: body))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Returns the path and body once the whole request has been received.
    private func parseRequest(_ data: Data) -> (String, Data)? {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return (path, Data(body.prefix(length)))
    }

    private func respond(on connection: NWConnection, _ result: (status: Int, json: Any)) {
        let body = (try? JSONSerialization.data(withJSONObject: result.json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(result.status) \(result.status < 300 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(path: String, body: Data) -> (status: Int, json: Any) {
        do {
            let json: Any
            switch path {
            case "/v1/licenses/activate": json = try activate(decode(body))
            case "/v1/licenses/deactivate": json = try deactivate(decode(body))
            default: throw HTTPError(status: 404, code: "not_found", message: "Unknown endpoint \(path).")
            }
            print("200 \(path)")
            return (200, json)
        } catch let error as HTTPError {
            print("\(error.status) \(path) \(error.code)")
            return (error.status, ["error": ["code": error.code, "message": error.message]])
        } catch {
            print("400 \(path) \(error)")
            return (400, ["error": ["code": "bad_request", "message": "Malformed request."]])
        }
    }

    private func decode<T: Decodable>(_ body: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }

    // MARK: - Endpoints

    private func activate(_ request: ActivateBody) throws -> Any {
        let expiresAt = try expiration(of: request.licenseKey)

        // Same Mac activating again (reinstall, update): reuse its activation and slot.
        let existing = activations.first {
            $0.value.licenseKey == request.licenseKey && $0.value.productId == request.productId
                && $0.value.fingerprint == request.machineFingerprint
        }
        let activationId: String
        if let existing {
            activationId = existing.key
        } else {
            guard usedSlots(request.licenseKey, request.productId) < activationLimit else {
                throw HTTPError(
                    status: 409, code: "activation_limit_reached",
                    message: "This license is already activated on \(activationLimit) Macs. Deactivate one first."
                )
            }
            activationId = "act_" + UUID().uuidString.prefix(8).lowercased()
            print("    new activation \(activationId) for \(request.machineName)")
        }

        // A fresh token on every call, so `issuedAt` and `expiresAt` reflect the server's current data.
        let token = LicenseToken(
            licenseId: "lic_" + request.licenseKey.lowercased(),
            activationId: activationId,
            productId: request.productId,
            edition: expiresAt == nil ? "pro" : "trial",
            machineFingerprint: request.machineFingerprint,
            issuedAt: .now,
            expiresAt: expiresAt,
            maxMajorVersion: maxMajorVersion
        )
        let license = try signer.sign(token)
        activations[activationId] = Activation(
            licenseKey: request.licenseKey,
            productId: request.productId,
            fingerprint: request.machineFingerprint,
            license: license
        )
        return [
            "activationId": activationId,
            "activationLimit": activationLimit,
            "activationsUsed": usedSlots(request.licenseKey, request.productId),
            "license": try JSONSerialization.jsonObject(with: license.encoded()),
        ]
    }

    private func deactivate(_ request: DeactivateBody) throws -> Any {
        guard let activation = activations[request.activationId],
              activation.fingerprint == request.machineFingerprint
        else {
            throw HTTPError(status: 404, code: "activation_not_found", message: "This Mac is not activated.")
        }
        activations[request.activationId] = nil
        print("    removed \(request.activationId)")
        return [String: String]()
    }

    /// Validates the key and returns its expiration date (`nil` for a perpetual license).
    private func expiration(of key: String) throws -> Date? {
        if key.hasPrefix("REVOKED-") {
            throw HTTPError(status: 403, code: "revoked", message: "This license has been revoked.")
        }
        if key.hasPrefix("EXPIRED-") {
            throw HTTPError(status: 403, code: "license_expired", message: "This license has expired.")
        }
        if key.hasPrefix("TRIAL-") {
            if let date = trialExpirations[key] { return date }
            // Whole seconds: the token format has no fractional seconds.
            let date = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 30 * 86_400).rounded(.down))
            trialExpirations[key] = date
            return date
        }
        guard key.hasPrefix("TEST-") else {
            throw HTTPError(status: 404, code: "invalid_key", message: "This license key is not valid.")
        }
        return nil
    }

    private func usedSlots(_ key: String, _ productId: String) -> Int {
        activations.values.count { $0.licenseKey == key && $0.productId == productId }
    }
}
