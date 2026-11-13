import Foundation

public enum LicenseStoreError: Error {
    /// The process lacks the `com.apple.security.application-groups` entitlement for this group.
    case appGroupUnavailable(String)
}

/// License files shared between the installer and the sandboxed FxPlug through an App Group:
/// `~/Library/Group Containers/<TEAMID>.com.fcpxstudio/Licenses/<productId>.license`
public struct LicenseStore: Sendable {
    public let directory: URL

    /// - Parameter appGroupIdentifier: Team-ID-prefixed group, e.g. `ABCDE12345.com.fcpxstudio`.
    ///   Both the installer and the FxPlug extension must declare it in their entitlements.
    public init(appGroupIdentifier: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { throw LicenseStoreError.appGroupUnavailable(appGroupIdentifier) }
        self.init(directory: container.appending(path: "Licenses", directoryHint: .isDirectory))
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(productId: String) -> URL {
        directory.appending(path: "\(productId).license", directoryHint: .notDirectory)
    }

    /// Returns `nil` when no license has been saved for this product.
    public func load(productId: String) throws -> SignedLicense? {
        let url = fileURL(productId: productId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SignedLicense(data: Data(contentsOf: url))
    }

    public func save(_ license: SignedLicense, productId: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try license.encoded().write(to: fileURL(productId: productId), options: .atomic)
    }

    public func remove(productId: String) throws {
        let url = fileURL(productId: productId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
