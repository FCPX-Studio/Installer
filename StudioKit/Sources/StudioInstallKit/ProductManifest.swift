import Foundation

/// Describes one product. Each installer target ships its own `Product.json`; the
/// installer code is identical for every plugin.
public struct ProductManifest: Codable, Sendable {
    public var productId: String
    public var displayName: String
    /// Major version of the plugin being installed, checked against the license.
    public var majorVersion: Int
    public var license: LicenseConfiguration
    public var hostApp: HostApp
    public var motionTemplates: [MotionTemplates]
    /// Optional plain-text agreement in the app resources (e.g. `EULA.txt`).
    public var licenseAgreementResource: String?

    public struct LicenseConfiguration: Codable, Sendable {
        public var apiBaseURL: URL
        /// Raw Ed25519 public key, base64.
        public var publicKey: String
        /// Team-ID-prefixed App Group shared with the FxPlug, e.g. `ABCDE12345.com.fcpxstudio`.
        public var appGroupIdentifier: String
    }

    /// FxPlug 4 container app, copied to `/Applications`.
    public struct HostApp: Codable, Sendable {
        /// Path relative to the installer's `Contents/SharedSupport` folder, e.g. `Payload/DepthStudio.app`.
        public var source: String
    }

    public struct MotionTemplates: Codable, Sendable {
        /// Path relative to the installer's `Contents/SharedSupport` folder.
        public var source: String
        /// Path relative to `~/Movies/Motion Templates.localized`, e.g. `Effects.localized/Depth Studio`.
        public var destination: String
    }

    public static func load(from bundle: Bundle = .main, resource: String = "Product") throws -> ProductManifest {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(resource).json"])
        }
        return try JSONDecoder().decode(ProductManifest.self, from: Data(contentsOf: url))
    }
}
