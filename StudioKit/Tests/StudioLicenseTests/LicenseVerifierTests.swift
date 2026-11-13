import CryptoKit
import Foundation
import Testing
@testable import StudioLicense

struct LicenseVerifierTests {
    let signer = LicenseSigner(privateKey: Curve25519.Signing.PrivateKey())
    let productId = "com.votresociete.depthstudio"
    let fingerprint = MachineIdentity.fingerprint(platformUUID: "UUID-1", serialNumber: "SN1", productId: "com.votresociete.depthstudio")

    func token(
        productId: String? = nil,
        fingerprint: String? = nil,
        expiresAt: Date? = nil,
        maxMajorVersion: Int? = 1
    ) -> LicenseToken {
        LicenseToken(
            licenseId: "lic_1",
            activationId: "act_1",
            productId: productId ?? self.productId,
            edition: "pro",
            machineFingerprint: fingerprint ?? self.fingerprint,
            issuedAt: Date(timeIntervalSince1970: 1_770_000_000),
            expiresAt: expiresAt,
            maxMajorVersion: maxMajorVersion
        )
    }

    func verifier(majorVersion: Int = 1, machine: String? = nil) throws -> LicenseVerifier {
        try LicenseVerifier(
            publicKeyBase64: signer.publicKeyBase64,
            productId: productId,
            majorVersion: majorVersion,
            machineFingerprint: machine ?? fingerprint
        )
    }

    @Test func validLicense() throws {
        let license = try signer.sign(token())
        #expect(try verifier().verify(license) == .valid(token()))
    }

    @Test func tamperedPayloadIsRejected() throws {
        var license = try signer.sign(token())
        var forged = token()
        forged.edition = "studio"
        license.payload = try JSONEncoder.licenseToken.encode(forged).base64EncodedString()
        #expect(try verifier().verify(license) == .invalid(.badSignature))
    }

    @Test func otherKeyIsRejected() throws {
        let other = LicenseSigner(privateKey: Curve25519.Signing.PrivateKey())
        let license = try other.sign(token())
        #expect(try verifier().verify(license) == .invalid(.badSignature))
    }

    @Test func wrongMachineIsRejected() throws {
        let license = try signer.sign(token())
        let otherMachine = MachineIdentity.fingerprint(platformUUID: "UUID-2", serialNumber: "SN2", productId: productId)
        #expect(try verifier(machine: otherMachine).verify(license) == .invalid(.wrongMachine))
    }

    @Test func wrongProductIsRejected() throws {
        let license = try signer.sign(token(productId: "com.votresociete.other"))
        #expect(try verifier().verify(license) == .invalid(.wrongProduct))
    }

    @Test func expiredLicense() throws {
        let expired = token(expiresAt: Date(timeIntervalSince1970: 1_770_000_100))
        let license = try signer.sign(expired)
        #expect(try verifier().verify(license, now: Date(timeIntervalSince1970: 1_780_000_000)) == .expired(expired))
    }

    @Test func newerMajorVersionIsNotCovered() throws {
        let license = try signer.sign(token(maxMajorVersion: 1))
        #expect(try verifier(majorVersion: 2).verify(license) == .versionNotCovered(token(maxMajorVersion: 1)))
    }

    @Test func fingerprintDependsOnProduct() {
        let other = MachineIdentity.fingerprint(platformUUID: "UUID-1", serialNumber: "SN1", productId: "com.votresociete.other")
        #expect(other != fingerprint)
        #expect(fingerprint.hasPrefix("SHA256:"))
    }

    @Test func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LicenseStore(directory: directory)

        #expect(try verifier().status(in: store) == .missing)
        try store.save(signer.sign(token()), productId: productId)
        #expect(try verifier().status(in: store).isLicensed)
        try store.remove(productId: productId)
        #expect(try verifier().status(in: store) == .missing)
    }
}
