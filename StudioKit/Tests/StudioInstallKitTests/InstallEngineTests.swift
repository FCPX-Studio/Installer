import Foundation
import Testing
@testable import StudioInstallKit

struct InstallEngineTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "StudioInstallKitTests-\(UUID().uuidString)")

    var resources: URL { root.appending(path: "Resources") }
    var locations: InstallLocations {
        InstallLocations(
            applications: root.appending(path: "Applications"),
            motionTemplates: root.appending(path: "Movies/Motion Templates.localized")
        )
    }

    func manifest(templates: [ProductManifest.MotionTemplates]) -> ProductManifest {
        ProductManifest(
            productId: "com.votresociete.depthstudio",
            displayName: "Depth Studio",
            majorVersion: 1,
            license: .init(
                apiBaseURL: URL(string: "https://example.com")!,
                publicKey: "",
                appGroupIdentifier: "TEAM.com.votresociete.studio"
            ),
            hostApp: .init(source: "Payload/Depth Studio.app"),
            motionTemplates: templates,
            licenseAgreementResource: nil
        )
    }

    func write(_ text: String, to relativePath: String, in base: URL) throws {
        let url = base.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relativePath: String, in base: URL) -> String? {
        (try? Data(contentsOf: base.appending(path: relativePath))).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func installsAndReplacesExistingItems() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("new app", to: "Payload/Depth Studio.app/Contents/Info.plist", in: resources)
        try write("new template", to: "Payload/Templates/Effects/Depth Studio/Effect.moef", in: resources)
        try write("old app", to: "Depth Studio.app/Contents/Info.plist", in: locations.applications)

        let engine = InstallEngine(
            manifest: manifest(templates: [
                .init(source: "Payload/Templates/Effects/Depth Studio", destination: "Effects.localized/Depth Studio"),
            ]),
            payloadBaseURL: resources,
            locations: locations
        )
        try await engine.install()

        #expect(read("Depth Studio.app/Contents/Info.plist", in: locations.applications) == "new app")
        #expect(read("Effects.localized/Depth Studio/Effect.moef", in: locations.motionTemplates) == "new template")
    }

    @Test func missingPayloadIsReportedBeforeTouchingAnything() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("new app", to: "Payload/Depth Studio.app/Contents/Info.plist", in: resources)
        try write("old app", to: "Depth Studio.app/Contents/Info.plist", in: locations.applications)

        let engine = InstallEngine(
            manifest: manifest(templates: [.init(source: "Payload/Missing", destination: "Effects.localized/X")]),
            payloadBaseURL: resources,
            locations: locations
        )
        await #expect(throws: InstallError.self) { try await engine.install() }
        #expect(read("Depth Studio.app/Contents/Info.plist", in: locations.applications) == "old app")
    }

    @Test func rollbackRestoresPreviousVersion() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("new", to: "new/file.txt", in: root)
        try write("old", to: "dest/file.txt", in: root)

        let transaction = InstallTransaction()
        try transaction.place(root.appending(path: "new"), at: root.appending(path: "dest"))
        #expect(read("dest/file.txt", in: root) == "new")
        transaction.rollback()
        #expect(read("dest/file.txt", in: root) == "old")
    }
}
