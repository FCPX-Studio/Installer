import Foundation
import Observation
import StudioActivation
import StudioInstallKit
import StudioLicense

/// Drives the installer screens:
/// welcome → agreement (optional) → activation → installation → finished.
///
/// `activate` is definitive server-side; activating the same Mac again reuses its slot.
/// The license is written to the App Group once the files are installed.
@MainActor @Observable
public final class InstallerModel {
    public enum Step: Int, CaseIterable, Identifiable {
        case welcome, agreement, activation, installation, finished
        public var id: Int { rawValue }
    }

    public enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    public let manifest: ProductManifest
    let agreementText: String?

    var step: Step = .welcome
    var phase: Phase = .idle
    var licenseKey = ""

    /// Activation obtained during this session, and its verified token.
    private(set) var activation: ActivationResponse?
    private(set) var activatedToken: LicenseToken?
    /// Valid license already present on this Mac (reinstall or update).
    private(set) var existingLicense: LicenseToken?
    /// Set when the configuration is unusable (bad public key, missing App Group entitlement…).
    private(set) var configurationError: String?

    private var filesInstalled = false
    private let verifier: LicenseVerifier?
    private let store: LicenseStore?
    private let client: LicenseAPIClient
    private let engine: InstallEngine
    private let appVersion: String

    public init(manifest: ProductManifest, bundle: Bundle = .main) {
        self.manifest = manifest
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        agreementText = manifest.licenseAgreementResource
            .flatMap { bundle.url(forResource: $0, withExtension: nil) }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        var apiBaseURL = manifest.license.apiBaseURL
        #if DEBUG
        // Launch argument `-LicenseAPIURL http://127.0.0.1:8787` targets the local mock server
        // (`studio-license-tool serve`). Licenses it returns are still checked with the public key.
        if let override = UserDefaults.standard.string(forKey: "LicenseAPIURL").flatMap(URL.init(string:)) {
            apiBaseURL = override
        }
        #endif
        client = LicenseAPIClient(baseURL: apiBaseURL)
        engine = InstallEngine(manifest: manifest, payloadBaseURL: bundle.sharedSupportURL ?? bundle.bundleURL)

        var errors: [String] = []
        verifier = try? LicenseVerifier(
            publicKeyBase64: manifest.license.publicKey,
            productId: manifest.productId,
            majorVersion: manifest.majorVersion
        )
        if verifier == nil { errors.append("The license public key is invalid.") }
        store = try? LicenseStore(appGroupIdentifier: manifest.license.appGroupIdentifier)
        if store == nil { errors.append("The App Group “\(manifest.license.appGroupIdentifier)” is not available.") }
        if MachineIdentity.fingerprint(productId: manifest.productId) == nil {
            errors.append("This Mac's hardware identifier could not be read.")
        }
        do { try engine.validatePayload() } catch { errors.append(error.localizedDescription) }
        configurationError = errors.isEmpty ? nil : errors.joined(separator: "\n")

        if let verifier, let store, case .valid(let token) = verifier.status(in: store) {
            existingLicense = token
        }
    }

    var steps: [Step] {
        Step.allCases.filter { $0 != .agreement || agreementText != nil }
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    var isActivated: Bool { existingLicense != nil || activation != nil }

    var canGoBack: Bool {
        !isWorking && step != .welcome && step != .finished && !filesInstalled
    }

    var canContinue: Bool {
        guard !isWorking, configurationError == nil else { return false }
        switch step {
        case .activation: return isActivated || !normalizedKey.isEmpty
        default: return true
        }
    }

    var hostAppDestination: URL { engine.hostAppDestination }

    var templatesDestination: URL { engine.locations.motionTemplates }

    private var normalizedKey: String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: - Navigation

    func goBack() {
        guard canGoBack, let index = steps.firstIndex(of: step), index > 0 else { return }
        phase = .idle
        step = steps[index - 1]
    }

    func primaryAction() async {
        guard canContinue else { return }
        switch step {
        case .activation where !isActivated:
            await activate()
        case .installation:
            await install()
        case .finished:
            break
        default:
            advance()
        }
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        phase = .idle
        step = steps[index + 1]
    }

    // MARK: - Activation

    func activate() async {
        guard let verifier, let fingerprint = MachineIdentity.fingerprint(productId: manifest.productId) else { return }
        phase = .working("Activating…")
        do {
            let response = try await client.activate(ActivationRequest(
                licenseKey: normalizedKey,
                productId: manifest.productId,
                machineFingerprint: fingerprint,
                machineName: Host.current().localizedName ?? "Mac",
                appVersion: appVersion,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ))
            // Check the token exactly as the FxPlug will, before installing anything.
            switch verifier.verify(response.license) {
            case .valid(let token):
                activation = response
                activatedToken = token
                advance()
            case .versionNotCovered:
                phase = .failed("This license does not cover version \(manifest.majorVersion) of \(manifest.displayName).")
            case .expired:
                phase = .failed("This license has expired.")
            case .missing, .invalid:
                phase = .failed("The license server returned an invalid license. Please contact support.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installation

    func install() async {
        let running = InstallEngine.runningHosts()
        guard running.isEmpty else {
            phase = .failed(InstallError.hostsRunning(running).localizedDescription)
            return
        }
        do {
            if !filesInstalled {
                phase = .working("Installing…")
                try await engine.install { step in
                    Task { @MainActor [weak self] in self?.phase = .working(step.message) }
                }
                filesInstalled = true
            }
            if let activation, let store {
                try store.save(activation.license, productId: manifest.productId)
            }
            advance()
        } catch {
            // Files may already be installed: retrying only re-runs the missing part.
            phase = .failed(error.localizedDescription)
        }
    }
}

private extension InstallStep {
    var message: String {
        switch self {
        case .copyingHostApp: "Installing the plugin…"
        case .copyingTemplates(let name): "Installing Motion Templates “\(name)”…"
        case .registeringExtensions: "Registering with Final Cut Pro and Motion…"
        }
    }
}
