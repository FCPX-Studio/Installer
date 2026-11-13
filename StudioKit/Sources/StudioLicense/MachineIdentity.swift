import CryptoKit
import Foundation
import IOKit

/// Stable, privacy-preserving identifier of the current Mac.
///
/// The installer and the FxPlug MUST compute this exactly the same way, which is why
/// it lives in this shared module. Changing the inputs or the salt invalidates every
/// license already issued.
public enum MachineIdentity {
    /// Namespace mixed into every fingerprint. It is not a secret: it only keeps our
    /// hashes distinct from those computed by other software from the same hardware IDs.
    static let salt = "com.fcpxstudio.studiokit.machine.v1"

    /// Returns `SHA256:<hex>` for this Mac and product, or `nil` if the hardware UUID
    /// cannot be read (should not happen on real hardware).
    public static func fingerprint(productId: String) -> String? {
        guard let uuid = platformProperty(kIOPlatformUUIDKey) else { return nil }
        // Some virtual machines have no serial number; the UUID alone is still stable.
        let serial = platformProperty(kIOPlatformSerialNumberKey) ?? ""
        return fingerprint(platformUUID: uuid, serialNumber: serial, productId: productId)
    }

    static func fingerprint(platformUUID: String, serialNumber: String, productId: String) -> String {
        let input = [platformUUID, serialNumber, productId, salt].joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        return "SHA256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a string property of the platform expert device. Works inside the sandbox.
    private static func platformProperty(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? String
    }
}
