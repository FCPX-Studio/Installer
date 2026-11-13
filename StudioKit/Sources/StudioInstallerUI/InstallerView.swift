import AppKit
import StudioInstallKit
import StudioLicense
import SwiftUI

/// Branding shared by every installer.
enum Branding {
    static let companyName = "FCPX Studio"

    /// `StudioLogo` from the installer's asset catalog, or the app icon if missing.
    @MainActor static var logo: NSImage {
        NSImage(named: "StudioLogo") ?? NSApplication.shared.applicationIconImage
    }
}

/// Root view of every installer. Product-specific content comes from `ProductManifest`.
/// Designed for a window with a hidden title bar (`.windowStyle(.hiddenTitleBar)`).
public struct InstallerView: View {
    @State private var model: InstallerModel

    public init(manifest: ProductManifest) {
        _model = State(initialValue: InstallerModel(manifest: manifest))
    }

    public var body: some View {
        HStack(spacing: 0) {
            StepSidebar(model: model)
                .frame(width: 220)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 36)
                    .padding(.top, 52)
                Footer(model: model)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
            }
        }
        // Fill the area under the hidden title bar too. The fixed frame comes last: it sizes the
        // window's safe area, and the content then expands to cover the full window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .frame(width: 740, height: 460)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .agreement: AgreementStep(text: model.agreementText ?? "")
        case .activation: ActivationStep(model: model)
        case .installation: InstallationStep(model: model)
        case .finished: FinishedStep(model: model)
        }
    }
}

// MARK: - Chrome

private struct StepSidebar: View {
    let model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: Branding.logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text(model.manifest.displayName)
                .font(.title3.weight(.semibold))
                .padding(.top, 14)
            Text(Branding.companyName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(model.steps.enumerated()), id: \.element) { index, step in
                    StepRow(number: index + 1, title: step.title, state: state(of: step))
                }
            }
            .padding(.top, 36)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 56)
        .padding(.bottom, 24)
        // Fill the whole column before painting, so the background spans the full width and height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary)
    }

    private func state(of step: InstallerModel.Step) -> StepRow.State {
        if step == model.step { return .current }
        return step.rawValue < model.step.rawValue ? .done : .upcoming
    }
}

private struct StepRow: View {
    enum State { case done, current, upcoming }

    let number: Int
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .upcoming ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(state == .upcoming ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .frame(width: 20, height: 20)

            Text(title)
                .fontWeight(state == .current ? .semibold : .regular)
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Footer: View {
    let model: InstallerModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .working(let message):
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if model.step != .welcome && model.step != .finished {
                Button("Back") { model.goBack() }
                    .disabled(!model.canGoBack)
            }
            if model.step == .finished {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryTitle) { Task { await model.primaryAction() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
        }
        .controlSize(.large)
    }

    private var primaryTitle: String {
        switch model.step {
        case .agreement: "Agree"
        case .activation: model.isActivated ? "Continue" : "Activate"
        case .installation:
            if case .failed = model.phase { "Retry" } else { "Install" }
        default: "Continue"
        }
    }
}

private struct StepHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 24)
    }
}

private extension InstallerModel.Step {
    var title: String {
        switch self {
        case .welcome: "Introduction"
        case .agreement: "License"
        case .activation: "Activation"
        case .installation: "Installation"
        case .finished: "Done"
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Install \(model.manifest.displayName)",
                subtitle: "For Final Cut Pro and Motion."
            )
            if let error = model.configurationError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("You will need:")
                        .foregroundStyle(.secondary)
                    Label("Your license key", systemImage: "key")
                    Label("An Internet connection", systemImage: "network")
                }
                .font(.body)
            }
        }
    }
}

private struct AgreementStep: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "License Agreement")
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .padding(.bottom, 8)
        }
    }
}

private struct ActivationStep: View {
    @Bindable var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let token = model.existingLicense {
                StepHeader(title: "Already Activated")
                ResultRow(
                    systemImage: "checkmark.seal.fill",
                    title: "This Mac is activated",
                    detail: licenseDescription(token)
                )
            } else if let activation = model.activation, let token = model.activatedToken {
                StepHeader(title: "License Accepted")
                ResultRow(
                    systemImage: "checkmark.seal.fill",
                    title: "Your license is valid",
                    detail: licenseDescription(token)
                        + " · \(activation.activationsUsed) of \(activation.activationLimit) Macs activated"
                )
            } else {
                StepHeader(title: "Enter Your License Key", subtitle: "You'll find it in your purchase email.")
                TextField("License key", text: $model.licenseKey, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                    .textFieldStyle(.plain)
                    .font(.title2.monospaced())
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .frame(maxWidth: 420)
                    .disabled(model.isWorking)
                    .onSubmit { Task { await model.primaryAction() } }
            }
        }
    }
}

/// "Pro license", or "Trial license, expires 13 Dec 2026" when the license has an expiration date.
private func licenseDescription(_ token: LicenseToken) -> String {
    let license = "\(token.edition.capitalized) license"
    guard let expiresAt = token.expiresAt else { return license }
    return "\(license), expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))"
}

private struct ResultRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct InstallationStep: View {
    let model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Ready to Install", subtitle: "Quit Final Cut Pro and Motion first.")
            VStack(spacing: 0) {
                ItemRow(
                    systemImage: "puzzlepiece.extension",
                    title: model.hostAppDestination.deletingPathExtension().lastPathComponent,
                    location: "Applications"
                )
                ForEach(model.manifest.motionTemplates, id: \.destination) { templates in
                    Divider().padding(.leading, 44)
                    ItemRow(
                        systemImage: "folder",
                        title: URL(filePath: templates.destination).lastPathComponent,
                        location: "Motion Templates › \(category(of: templates))"
                    )
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10))
            .frame(maxWidth: 460)
        }
    }

    /// `Effects.localized/Depth Studio` → `Effects`
    private func category(of templates: ProductManifest.MotionTemplates) -> String {
        let first = templates.destination.split(separator: "/").first.map(String.init) ?? ""
        return first.replacingOccurrences(of: ".localized", with: "")
    }
}

private struct ItemRow: View {
    let systemImage: String
    let title: String
    let location: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(title)
            Spacer()
            Text(location)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct FinishedStep: View {
    let model: InstallerModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("\(model.manifest.displayName) Is Installed")
                .font(.largeTitle.weight(.semibold))
            Text("Open Final Cut Pro or Motion to start using it.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 52)
    }
}
