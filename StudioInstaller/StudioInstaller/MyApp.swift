import StudioInstallKit
import StudioInstallerUI
import SwiftUI

@main struct MyApp: App {
    private let manifest = Result { try ProductManifest.load() }

    var body: some Scene {
        // A single `Window` (not `WindowGroup`): closing it quits the installer.
        Window(windowTitle, id: "installer") {
            switch manifest {
            case .success(let manifest):
                InstallerView(manifest: manifest)
            case .failure(let error):
                ContentUnavailableView(
                    "Damaged Installer",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Product.json could not be read: \(error.localizedDescription)")
                )
                .frame(width: 480, height: 300)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    private var windowTitle: String {
        guard case .success(let manifest) = manifest else { return "Installer" }
        return "\(manifest.displayName) Installer"
    }
}
