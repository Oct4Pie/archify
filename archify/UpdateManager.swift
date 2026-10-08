import Combine
import Sparkle
import SwiftUI

final class UpdateManager: ObservableObject {
    let updaterController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false

    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?
    private var automaticDownloadsObservation: NSKeyValueObservation?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = updaterController.updater

        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            self?.publishOnMain {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }

        automaticChecksObservation = updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            self?.publishOnMain {
                self?.automaticallyChecksForUpdates =
                    updater.automaticallyChecksForUpdates
            }
        }

        automaticDownloadsObservation = updater.observe(
            \.automaticallyDownloadsUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            self?.publishOnMain {
                self?.automaticallyDownloadsUpdates =
                    updater.automaticallyDownloadsUpdates
            }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
    }

    private func publishOnMain(_ change: @escaping () -> Void) {
        if Thread.isMainThread {
            change()
        } else {
            DispatchQueue.main.async(execute: change)
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        TabView {
            UpdateSettingsView(updateManager: updateManager)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            HelperSettingsView()
                .tabItem {
                    Label("Helper", systemImage: "lock.shield")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 580, height: 455)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArchifyPageHeader(
                    title: "Updates",
                    subtitle: "Keep Archify current while staying in control of what gets installed.",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                ArchifyCard(
                    title: "Automatic updates",
                    subtitle: "Updates are verified before installation.",
                    systemImage: "checkmark.shield"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Check for updates automatically",
                            isOn: automaticChecksBinding
                        )

                        Toggle(
                            "Download updates automatically",
                            isOn: automaticDownloadsBinding
                        )
                        .disabled(!updateManager.automaticallyChecksForUpdates)

                        Divider()

                        HStack {
                            Button("Check for Updates…") {
                                updateManager.checkForUpdates()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!updateManager.canCheckForUpdates)
                            Spacer()
                        }
                    }
                }

            }
            .padding(24)
        }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyDownloadsUpdates },
            set: { updateManager.setAutomaticallyDownloadsUpdates($0) }
        )
    }
}

struct HelperSettingsView: View {
    @State private var status = HelperToolManager.shared.serviceState()
    @State private var showTechnicalDetails = false
    /// Keeps the status current while macOS waits for approval, so turning
    /// the helper on in System Settings shows up here without a Refresh.
    private let statusPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
#if DEBUG
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)?
    @State private var showDeveloperTools = false
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArchifyPageHeader(
                    title: "Archify Helper",
                    subtitle: "A small administrator component handles only the protected app changes that macOS does not allow Archify to make directly.",
                    systemImage: "lock.shield"
                )

                ArchifyCard(
                    title: "Status",
                    subtitle: "Only protected changes inside /Applications need administrator access.",
                    systemImage: "heart.text.square"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) {
                                ArchifyStatusPill(
                                    text: status.displayTitle,
                                    systemImage: status.systemImage,
                                    color: status.tint
                                )
                                Text(status.userExplanation)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 16)

                            Button("Refresh") {
                                refreshStatus()
                            }
                            .buttonStyle(.bordered)
                        }

                        if status == .needsApproval {
                            Divider()
                            HStack {
                                Text("In Login Items & Extensions, turn on archify under Allow in the Background. This page updates automatically.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Open Login Items") {
                                    HelperToolManager.shared.openApprovalSettings()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else if status == .notSetUp {
                            Divider()
                            HStack {
                                Text("Set it up now so optimizing apps in /Applications doesn't stop to ask later.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Set Up Helper") {
                                    _ = HelperToolManager.shared.ensureHelperToolInstalled()
                                    refreshStatus()
                                    if status == .needsApproval {
                                        HelperToolManager.shared.openApprovalSettings()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                    }
                }

                if #available(macOS 13.0, *) {
                    ArchifyCard(
                        title: "Full Disk Access",
                        subtitle: "macOS protects notarized apps you've opened from changes by other software. "
                            + "To optimize those apps, turn on \(HelperToolManager.appDisplayName) in Full Disk Access. "
                            + "Archify asks only when macOS blocks a change, and uses it only on the apps you select.",
                        systemImage: "hand.raised"
                    ) {
                        HStack {
                            Button("Open Full Disk Access") {
                                HelperToolManager.shared.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                        }
                    }
                }

#if DEBUG
                ArchifyCard(
                    title: "Developer tools",
                    subtitle: "Only needed while developing or diagnosing Archify.",
                    systemImage: "hammer"
                ) {
                    ArchifyDisclosure(
                        "Helper connection test",
                        isExpanded: $showDeveloperTools
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(
                                "This read-only test verifies helper registration and authentication without modifying an app."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack {
                                Button(isTesting ? "Testing…" : "Test Helper Connection") {
                                    runHelperTest()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isTesting)

                                Spacer()

                                if let testResult {
                                    ArchifyStatusPill(
                                        text: testResult.success ? "Connected" : "Not connected",
                                        systemImage: testResult.success
                                            ? "checkmark.circle.fill"
                                            : "exclamationmark.triangle.fill",
                                        color: testResult.success ? .green : .orange
                                    )
                                }
                            }

                            if let testResult {
                                Text(testResult.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if status == .unavailableForAdHocDebug {
                                ArchifyNotice(
                                    title: "Administrator features are disabled in this development build",
                                    message: "Normal development features still work. Build the identified helper-test configuration when you need to test administrator actions.",
                                    kind: .warning
                                )
                            }
                        }
                        .padding(.top, 10)
                    }
                }
#endif

                ArchifyDisclosure(
                    "Technical details",
                    isExpanded: $showTechnicalDetails
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ArchifyLabeledValue(
                            title: "Service",
                            value: HelperService.currentLabel
                        )
                        ArchifyLabeledValue(
                            title: "Team ID",
                            value: HelperToolManager.shared.currentTeamIdentifier()
                                ?? "No Apple team identity"
                        )
                        ArchifyLabeledValue(
                            title: "Protection",
                            value: "Code-signing requirement + administrator authorization + path validation"
                        )
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
            .padding(24)
        }
        .onAppear(perform: refreshStatus)
        .onReceive(statusPoll) { _ in
            if status == .needsApproval {
                refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        status = HelperToolManager.shared.serviceState()
    }

#if DEBUG
    private func runHelperTest() {
        isTesting = true
        testResult = nil

        HelperToolManager.shared.testPrivilegedHelperConnection {
            success,
            message in
            DispatchQueue.main.async {
                isTesting = false
                testResult = (
                    success,
                    message ?? (
                        success
                            ? "The helper accepted the authenticated connection."
                            : "The helper could not be reached."
                    )
                )
                refreshStatus()
            }
        }
    }
#endif
}

struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
    }

    private var build: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "shippingbox.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 5) {
                Text("Archify")
                    .font(.title.weight(.semibold))
                Text("Simple macOS app optimization")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ArchifyStatusPill(
                    text: "Version \(version)",
                    systemImage: "tag",
                    color: .accentColor
                )
                Text("Build \(build)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(
                "Inspect first, change only what you choose, and keep the original untouched when using Optimize an App."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 430)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

private extension HelperServiceState {
    var displayTitle: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsApproval:
            return "Approval required"
        case .notSetUp:
            return "Available when needed"
        case .legacyReady:
            return "Ready"
        case .unavailableForAdHocDebug:
            return "Disabled in this development build"
        case .unknown:
            return "Status unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .ready, .legacyReady:
            return "checkmark.circle.fill"
        case .needsApproval:
            return "exclamationmark.triangle.fill"
        case .notSetUp:
            return "minus.circle.fill"
        case .unavailableForAdHocDebug:
            return "hammer.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .legacyReady:
            return .green
        case .needsApproval:
            return .orange
        case .notSetUp, .unavailableForAdHocDebug, .unknown:
            return .secondary
        }
    }

    var userExplanation: String {
        switch self {
        case .ready:
            return "Archify can perform approved changes to apps in /Applications when needed."
        case .needsApproval:
            return "macOS is waiting for administrator approval before Archify can use the helper."
        case .notSetUp:
            return "Archify will set it up automatically when a protected change needs it."
        case .legacyReady:
            return "Archify can make approved changes inside /Applications when needed."
        case .unavailableForAdHocDebug:
            return "This development build is intentionally prevented from installing or connecting to the administrator helper."
        case .unknown:
            return "Archify could not determine the helper's current registration state."
        }
    }
}

/// Step-by-step guidance for whatever is stopping Archify Helper, with a
/// direct link to the right System Settings pane. Resumes the interrupted
/// work once the user has fixed it.
struct HelperAccessSheet: View {
    let issue: HelperAccessIssue
    @ObservedObject var access: HelperAccess

    /// Approval in Login Items is detected automatically; Full Disk Access
    /// has no status API, so that path offers Try Again instead.
    private let approvalPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(intro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.accentColor))
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
            }

            if issue == .needsApproval {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for approval… Archify continues automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    access.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                buttons
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(approvalPoll) { _ in
            guard issue == .needsApproval else { return }
            switch HelperToolManager.shared.serviceState() {
            case .ready, .legacyReady:
                access.resolve()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch issue {
        case .needsApproval:
            Button("Open Login Items") {
                HelperToolManager.shared.openApprovalSettings()
            }
            .keyboardShortcut(.defaultAction)
        case .fullDiskAccessNeeded:
            if access.canRetry {
                Button("Try Again") {
                    access.resolve()
                }
            }
            Button("Open Full Disk Access") {
                HelperToolManager.shared.openFullDiskAccessSettings()
            }
            .keyboardShortcut(.defaultAction)
        case .unavailable:
            EmptyView()
        }
    }

    private var icon: String {
        switch issue {
        case .needsApproval: return "lock.shield"
        case .fullDiskAccessNeeded: return "hand.raised"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch issue {
        case .needsApproval: return "Allow Archify Helper"
        case .fullDiskAccessNeeded: return "Allow Archify to change protected apps"
        case .unavailable: return "Archify Helper isn’t available"
        }
    }

    private var intro: String {
        switch issue {
        case .needsApproval:
            return "Archify uses a small helper to change apps in /Applications. macOS asks you to allow it once."
        case .fullDiskAccessNeeded:
            return "macOS protects notarized apps you've opened from changes by other software. "
                + "To thin them or remove their languages, Archify needs Full Disk Access. "
                + "It uses it only on the apps you select. Nothing was changed."
        case .unavailable(let message):
            return message
        }
    }

    private var steps: [String] {
        switch issue {
        case .needsApproval:
            return [
                "Click Open Login Items.",
                "Under Allow in the Background, turn on archify.",
                "Come back here. Archify continues on its own."
            ]
        case .fullDiskAccessNeeded:
            let name = HelperToolManager.appDisplayName
            return [
                "Click Open Full Disk Access.",
                "Turn on \(name). If it isn’t listed, click + below the list and choose \(name) in Applications.",
                "If macOS offers to quit and reopen \(name), choose Later.",
                "Come back here and click Try Again."
            ]
        case .unavailable:
            return []
        }
    }
}
