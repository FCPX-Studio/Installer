import AppKit
import CoreServices
import Foundation

public struct InstallLocations: Sendable {
    public var applications: URL
    public var motionTemplates: URL

    public init(applications: URL, motionTemplates: URL) {
        self.applications = applications
        self.motionTemplates = motionTemplates
    }

    /// Requires a non-sandboxed process, so that the home directory is the real one.
    public static var standard: InstallLocations {
        InstallLocations(
            applications: URL(filePath: "/Applications", directoryHint: .isDirectory),
            motionTemplates: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Movies/Motion Templates.localized", directoryHint: .isDirectory)
        )
    }
}

public enum InstallStep: Sendable, Equatable {
    case copyingHostApp
    case registeringExtensions
    case copyingTemplates(String)
}

public enum InstallError: LocalizedError, Sendable {
    case missingPayload(String)
    case hostsRunning([String])
    case copyFailed(String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .missingPayload(let path):
            "The installer is damaged: “\(path)” is missing."
        case .hostsRunning(let names):
            "Quit \(names.formatted(.list(type: .and))) before installing."
        case .copyFailed(let path, let underlying):
            "Could not install “\(path)”: \(underlying)"
        }
    }
}

/// Copies the FxPlug container app and the Motion Templates, with rollback on failure.
/// No privileged helper is needed: admin users can write to `/Applications` and the
/// templates live in the user's home folder.
public struct InstallEngine: Sendable {
    public static let hostBundleIdentifiers = ["com.apple.FinalCut", "com.apple.FinalCutTrial", "com.apple.motionapp"]

    public let manifest: ProductManifest
    public let payloadBaseURL: URL
    public let locations: InstallLocations

    public init(manifest: ProductManifest, payloadBaseURL: URL, locations: InstallLocations = .standard) {
        self.manifest = manifest
        self.payloadBaseURL = payloadBaseURL
        self.locations = locations
    }

    /// Names of Final Cut Pro / Motion instances currently running. They cache plugins
    /// and templates at launch, so they must be quit first.
    @MainActor public static func runningHosts() -> [String] {
        hostBundleIdentifiers
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .compactMap(\.localizedName)
    }

    public var hostAppDestination: URL {
        locations.applications.appending(path: URL(filePath: manifest.hostApp.source).lastPathComponent)
    }

    /// Checks that every payload item is present in the installer bundle.
    public func validatePayload() throws {
        let sources = [manifest.hostApp.source] + manifest.motionTemplates.map(\.source)
        for source in sources where !FileManager.default.fileExists(atPath: payloadBaseURL.appending(path: source).path) {
            throw InstallError.missingPayload(source)
        }
    }

    public func install(progress: @Sendable (InstallStep) -> Void = { _ in }) async throws {
        try validatePayload()
        let transaction = InstallTransaction()
        do {
            progress(.copyingHostApp)
            try transaction.place(payloadBaseURL.appending(path: manifest.hostApp.source), at: hostAppDestination)

            for templates in manifest.motionTemplates {
                progress(.copyingTemplates(URL(filePath: templates.destination).lastPathComponent))
                try transaction.place(
                    payloadBaseURL.appending(path: templates.source),
                    at: locations.motionTemplates.appending(path: templates.destination)
                )
            }

            progress(.registeringExtensions)
            await registerExtensions(in: hostAppDestination)
            transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    public func uninstall() async throws {
        await runPluginKit("-r", extensions(in: hostAppDestination))
        let targets = [hostAppDestination] + manifest.motionTemplates.map {
            locations.motionTemplates.appending(path: $0.destination)
        }
        for url in targets where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Extension registration

    /// Registers the container app with Launch Services and its FxPlug extensions with
    /// PlugInKit, so Final Cut Pro and Motion see them without launching the app first.
    /// Failures are not fatal: launching the container app once also registers them.
    private func registerExtensions(in app: URL) async {
        LSRegisterURL(app as CFURL, true)
        await runPluginKit("-a", extensions(in: app))
    }

    private func extensions(in app: URL) -> [URL] {
        let plugIns = app.appending(path: "Contents/PlugIns", directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        // FxPlug 4 extensions are `.pluginkit` bundles; `.appex` covers other app extensions.
        return contents.filter { ["pluginkit", "appex"].contains($0.pathExtension) }
    }

    private func runPluginKit(_ flag: String, _ extensions: [URL]) async {
        for appex in extensions {
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/pluginkit")
                process.arguments = [flag, appex.path]
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume() }
            }
        }
    }
}

/// Records every item placed so that a failed install restores the previous state.
final class InstallTransaction {
    private var entries: [(destination: URL, backup: URL?)] = []
    private let fileManager = FileManager.default

    func place(_ source: URL, at destination: URL) throws {
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var backup: URL?
            if fileManager.fileExists(atPath: destination.path) {
                let directory = try fileManager.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true
                )
                let moved = directory.appending(path: destination.lastPathComponent)
                try fileManager.moveItem(at: destination, to: moved)
                backup = moved
            }
            // Record before copying so a partial copy is cleaned up by `rollback`.
            entries.append((destination, backup))
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw InstallError.copyFailed(destination.path, underlying: error.localizedDescription)
        }
    }

    func rollback() {
        for entry in entries.reversed() {
            try? fileManager.removeItem(at: entry.destination)
            if let backup = entry.backup {
                try? fileManager.moveItem(at: backup, to: entry.destination)
            }
        }
        entries.removeAll()
    }

    func commit() {
        for case let backup? in entries.map(\.backup) {
            try? fileManager.removeItem(at: backup.deletingLastPathComponent())
        }
        entries.removeAll()
    }
}
