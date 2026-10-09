//
//  AppProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppProcessingView: View {
    @EnvironmentObject var appState: AppState

    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showAdvanced = false
    @State private var showActivity = false
    @State private var showReplaceConfirmation = false

    private enum SigningMode: String, CaseIterable, Identifiable {
        case preserve = "Preserve signature"
        case adHoc = "Re-sign locally"
        case ldid = "Use LDID"

        var id: String { rawValue }
    }

    var body: some View {
        ArchifyPage {
            ArchifyPageHeader(
                title: "Optimize an App",
                subtitle: "Create a smaller copy. The original stays untouched.",
                systemImage: "shippingbox.and.arrow.backward.fill"
            )

            sourceCard
            architectureCard
            advancedCard
            actionCard

            if appState.isProcessing {
                ArchifyProgressCard(
                    title: "Optimizing app…",
                    detail: "Archify is working on the copied app. The original remains unchanged.",
                    progress: nil
                )
            }

            if hasResults {
                resultsCard
            }

            if !appState.logMessages.isEmpty {
                ArchifyCard(
                    title: "Activity",
                    subtitle: "Technical details from the current run.",
                    systemImage: "text.alignleft"
                ) {
                    ArchifyDisclosure(
                        "Show technical details",
                        isExpanded: $showActivity
                    ) {
                        ArchifyLogView(text: appState.logMessages)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .alert("Can't Start Processing", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            if appState.selectedArch.isEmpty {
                appState.selectedArch = ProcessInfo.processInfo.machineArchitecture
            }
        }
    }

    private var sourceCard: some View {
        ArchifyCard(
            title: "1. Choose app & destination",
            systemImage: "doc.on.doc"
        ) {
            VStack(spacing: 14) {
                ArchifyPathSelector(
                    title: "Application",
                    help: "Choose the .app you want to optimize.",
                    systemImage: "app",
                    path: $appState.inputDir
                ) {
                    if let url = openPanel(
                        canChooseFiles: true,
                        canChooseDirectories: false
                    ) {
                        appState.inputDir = url.path
                        appState.outputName = nil
                        appState.lastCopyPath = nil
                    }
                }

                Divider()

                ArchifyPathSelector(
                    title: "Save optimized copy to",
                    help: "Choose a folder for the new copy.",
                    systemImage: "folder",
                    path: $appState.outputDir
                ) {
                    if let url = openPanel(
                        canChooseFiles: false,
                        canChooseDirectories: true
                    ) {
                        appState.outputDir = url.path
                        appState.outputName = nil
                        appState.lastCopyPath = nil
                    }
                }

                if destinationConflict, destinationIsLatestCopy {
                    savedCopyNotice
                } else if destinationConflict {
                    destinationConflictNotice
                } else if let outputName = appState.outputName {
                    ArchifyNotice(
                        title: "The copy will be saved as “\(outputName)”",
                        message: "The existing app with the same name is kept.",
                        kind: .info
                    )
                }
            }
        }
    }

    private var architectureCard: some View {
        ArchifyCard(
            title: "2. Target Mac",
            systemImage: "cpu"
        ) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(architectureDisplayName(appState.selectedArch))
                        .font(.headline)
                    Text(targetsThisMac ? "Recommended for this Mac" : "For a different Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu("Change…") {
                    Button("Apple Silicon") {
                        appState.selectedArch = "arm64"
                    }
                    Button("Intel") {
                        appState.selectedArch = "x86_64"
                    }
                }
            }

            if !targetsThisMac {
                ArchifyNotice(
                    title: "Different from this Mac",
                    message: "The optimized copy may not run here.",
                    kind: .warning
                )
            }
        }
    }

    private var advancedCard: some View {
        ArchifyCard(
            title: "Advanced",
            subtitle: "Leave these off unless an app needs special handling.",
            systemImage: "slider.horizontal.3"
        ) {
            ArchifyDisclosure(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 16) {
                    if appState.selectedArch != "x86_64" {
                        Toggle("Use arm64e target", isOn: arm64eBinding)
                            .help("Use only when the app contains an arm64e slice.")

                        Divider()
                    }

                    signingControls

                    Divider()

                    Toggle(
                        "Open the copied app once before optimizing",
                        isOn: $appState.launchSign
                    )
                    .help("Runs the copied app once for normal first-launch setup.")
                }
                .padding(.top, 12)
            } label: {
                HStack {
                    Text(showAdvanced ? "Hide" : "Show")
                    Spacer()
                    if advancedOptionCount > 0 {
                        ArchifyStatusPill(
                            text: "\(advancedOptionCount) enabled",
                            systemImage: "checkmark",
                            color: .accentColor
                        )
                    }
                }
            }
        }
    }

    private var signingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signature handling")
                .font(.subheadline.weight(.semibold))

            Picker("Signature handling", selection: signingModeBinding) {
                ForEach(SigningMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 380, alignment: .leading)

            if signingModeBinding.wrappedValue != .preserve {
                Text(signingModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if signingModeBinding.wrappedValue == .ldid {
                ArchifyPathSelector(
                    title: "External LDID executable",
                    help: "Choose a compatible LDID executable.",
                    systemImage: "terminal",
                    path: $appState.ldidPath
                ) {
                    if let url = openExecutablePanel() {
                        appState.ldidPath = url.path
                    }
                }

                Toggle("Reuse extracted entitlements", isOn: $appState.entitlements)
                    .padding(.leading, 2)
                    .help("Reuse the copied app's existing entitlements.")
            } else if signingModeBinding.wrappedValue == .adHoc {
                Toggle("Reuse extracted entitlements", isOn: $appState.entitlements)
                    .padding(.leading, 2)
                    .help("Reuse the copied app's existing entitlements.")
            }
        }
    }

    private var actionCard: some View {
        ArchifyCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to create the optimized copy?")
                        .font(.headline)
                    Text(actionHint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    startProcessing()
                } label: {
                    Label(
                        appState.isProcessing ? "Processing…" : "Optimize Copy",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canProcess)
            }
        }
    }

    private var resultsCard: some View {
        ArchifyCard(
            title: "Optimization complete",
            subtitle: "Comparison of the copied app before and after optimization.",
            systemImage: "checkmark.circle"
        ) {
            HStack(spacing: 24) {
                if appState.initialAppSize != 0 {
                    ArchifyMetric(
                        title: "Before",
                        value: appState.initialAppSize.humanReadableSize()
                    )
                }

                if appState.finalAppSize != 0 {
                    ArchifyMetric(
                        title: "After",
                        value: appState.finalAppSize.humanReadableSize()
                    )
                }

                if appState.initialAppSize != 0 && appState.finalAppSize != 0 {
                    let saved = StorageUtilities.savedSpace(
                        originalSize: appState.initialAppSize,
                        newSize: appState.finalAppSize
                    )
                    let percent = StorageUtilities.savedPercentage(
                        originalSize: appState.initialAppSize,
                        newSize: appState.finalAppSize
                    )
                    ArchifyMetric(
                        title: "Saved",
                        value: "\(saved.humanReadableSize()) · \(String(format: "%.1f%%", percent))",
                        emphasis: .green
                    )
                }
            }
        }
    }

    private var signingModeBinding: Binding<SigningMode> {
        Binding(
            get: {
                if appState.useLDID { return .ldid }
                if appState.useCodesign { return .adHoc }
                return .preserve
            },
            set: { mode in
                appState.useLDID = mode == .ldid
                appState.useCodesign = mode == .adHoc
                if mode == .preserve {
                    appState.entitlements = false
                }
            }
        )
    }

    private var signingModeDescription: String {
        switch signingModeBinding.wrappedValue {
        case .preserve:
            return ""
        case .adHoc:
            return "Creates a local signature for the copied app."
        case .ldid:
            return "Uses an external LDID executable."
        }
    }

    private var targetsThisMac: Bool {
        let host = ProcessInfo.processInfo.machineArchitecture
        if host == "arm64" || host == "arm64e" {
            return appState.selectedArch == "arm64"
                || appState.selectedArch == "arm64e"
        }
        return appState.selectedArch == host
    }

    private var arm64eBinding: Binding<Bool> {
        Binding(
            get: { appState.selectedArch == "arm64e" },
            set: { enabled in
                appState.selectedArch = enabled ? "arm64e" : "arm64"
            }
        )
    }

    private func architectureDisplayName(_ architecture: String) -> String {
        switch architecture {
        case "arm64": return "Apple Silicon"
        case "arm64e": return "Apple Silicon (arm64e)"
        case "x86_64": return "Intel"
        default: return architecture
        }
    }

    private var advancedOptionCount: Int {
        var count = 0
        if appState.selectedArch == "arm64e" { count += 1 }
        if appState.useLDID || appState.useCodesign { count += 1 }
        if appState.launchSign { count += 1 }
        return count
    }

    private var canProcess: Bool {
        !appState.inputDir.isEmpty
            && !appState.outputDir.isEmpty
            && !appState.selectedArch.isEmpty
            && !destinationConflict
            && !appState.isProcessing
    }

    private var actionHint: String {
        if appState.inputDir.isEmpty {
            return "Choose an app to continue."
        }
        if appState.outputDir.isEmpty {
            return "Choose where the optimized copy should be saved."
        }
        if destinationConflict, destinationIsLatestCopy, !appState.isProcessing {
            return "Done. Choose Keep Both to make another copy."
        }
        if destinationConflict, !destinationIsLatestCopy {
            return "Choose Keep Both or Replace above."
        }
        if appState.isProcessing {
            return "Archify is processing the copied app."
        }
        return "Your original app stays untouched."
    }

    /// Where the copy will be saved, or nil until both paths are chosen.
    private var destinationURL: URL? {
        guard !appState.inputDir.isEmpty, !appState.outputDir.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: appState.outputDir, isDirectory: true)
            .appendingPathComponent(
                appState.outputName
                    ?? URL(fileURLWithPath: appState.inputDir).lastPathComponent,
                isDirectory: true
            )
    }

    private var destinationConflict: Bool {
        guard let destinationURL else { return false }
        return FileManager.default.fileExists(atPath: destinationURL.path)
    }

    /// The existing item at the destination is the app being copied, for
    /// example when saving to the app's own folder. It must never be
    /// replaced.
    private var destinationIsOriginal: Bool {
        guard let destinationURL else { return false }
        return canonicalPath(destinationURL.path) == canonicalPath(appState.inputDir)
    }

    /// The item at the destination is the copy the latest run just made.
    private var destinationIsLatestCopy: Bool {
        guard let destinationURL, let lastCopy = appState.lastCopyPath else {
            return false
        }
        return canonicalPath(destinationURL.path) == canonicalPath(lastCopy)
    }

    private var savedCopyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArchifyNotice(
                title: appState.isProcessing
                    ? "Saving the optimized copy as “\(destinationURL?.lastPathComponent ?? "")”"
                    : "Optimized copy saved as “\(destinationURL?.lastPathComponent ?? "")”",
                message: "Your original app is unchanged. To make another copy here, choose Keep Both.",
                kind: appState.isProcessing ? .info : .success
            )
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    if let destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                    }
                }
                .buttonStyle(.bordered)

                Button("Keep Both") {
                    appState.outputName = nextAvailableName()
                }
                .buttonStyle(.bordered)
                .disabled(appState.isProcessing)

                Spacer()
            }
        }
    }

    private var destinationConflictNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArchifyNotice(
                title: destinationIsOriginal
                    ? "This folder already contains the original app"
                    : "“\(destinationURL?.lastPathComponent ?? "")” already exists here",
                message: destinationIsOriginal
                    ? "Keep both to save the optimized copy under a new name, or choose another folder."
                    : "Keep both to save under a new name, or replace the existing copy. Replacing moves it to the Trash, so you can restore it.",
                kind: .warning
            )
            HStack(spacing: 8) {
                Button("Keep Both") {
                    appState.outputName = nextAvailableName()
                }
                .buttonStyle(.borderedProminent)

                if !destinationIsOriginal {
                    Button("Replace…") {
                        showReplaceConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }

                Button("Show in Finder") {
                    if let destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .confirmationDialog(
            "Move “\(destinationURL?.lastPathComponent ?? "")” to the Trash?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                replaceExistingCopy()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing copy at \(appState.outputDir) goes to the Trash, and the new optimized copy takes its place. You can restore the old one from the Trash.")
        }
    }

    /// "Example 2.app", "Example 3.app", … — the first name not taken.
    private func nextAvailableName() -> String {
        let base = URL(fileURLWithPath: appState.inputDir)
            .deletingPathExtension()
            .lastPathComponent
        let folder = URL(fileURLWithPath: appState.outputDir, isDirectory: true)
        for number in 2...999 {
            let candidate = "\(base) \(number).app"
            if !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(candidate).path
            ) {
                return candidate
            }
        }
        return "\(base) \(UUID().uuidString.prefix(8)).app"
    }

    private func replaceExistingCopy() {
        guard let destinationURL, !destinationIsOriginal else { return }
        // Trash the copy only through a folder no other user can change, so
        // the name cannot be redirected to someone else's app meanwhile.
        guard let realFolder = realpath(appState.outputDir, nil) else { return }
        let folder = String(cString: realFolder)
        free(realFolder)
        guard ApplicationThinner.isTrustedDirectory(folder) else {
            alertMessage = "Choose a destination folder that other users can't change."
            showAlert = true
            return
        }
        let existingCopy = URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
        guard canonicalPath(existingCopy.path) != canonicalPath(appState.inputDir) else {
            return
        }
        do {
            try FileManager.default.trashItem(at: existingCopy, resultingItemURL: nil)
            appState.outputName = nil
            appState.appendLog("Moved the existing \(destinationURL.lastPathComponent) to the Trash.")
        } catch {
            alertMessage = "Archify couldn't move the existing copy to the Trash: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
    }

    private var hasResults: Bool {
        appState.initialAppSize != 0 || appState.finalAppSize != 0
    }

    private func startProcessing() {
        guard canProcess else { return }

        if appState.useLDID {
            guard let ldidPath = appState.findLdid() else {
                alertMessage =
                    "Archify could not find a compatible LDID executable. "
                    + "Choose one in Advanced options, use ad hoc codesign, "
                    + "or preserve the existing signature."
                showAlert = true
                return
            }
            appState.ldidPath = ldidPath
        }

        appState.initialAppSize = 0
        appState.finalAppSize = 0
        appState.logMessages = ""
        // Starting is disabled while the destination is taken, so whatever
        // appears there from now on is this run's copy. Recording it up
        // front keeps a large copy in progress from looking like a conflict.
        appState.lastCopyPath = destinationURL?.path
        appState.isProcessing = true
        appState.processApp()
    }

    private func openPanel(
        canChooseFiles: Bool,
        canChooseDirectories: Bool
    ) -> URL? {
        let dialog = NSOpenPanel()
        dialog.title = canChooseFiles ? "Choose an Application" : "Choose a Destination Folder"
        dialog.canChooseDirectories = canChooseDirectories
        dialog.canChooseFiles = canChooseFiles
        dialog.allowsMultipleSelection = false
        if canChooseFiles && !canChooseDirectories {
            dialog.allowedContentTypes = [.application]
        }

        return dialog.runModal() == .OK ? dialog.url : nil
    }

    private func openExecutablePanel() -> URL? {
        let dialog = NSOpenPanel()
        dialog.title = "Choose an LDID Executable"
        dialog.canChooseDirectories = false
        dialog.canChooseFiles = true
        dialog.allowsMultipleSelection = false
        dialog.treatsFilePackagesAsDirectories = false

        return dialog.runModal() == .OK ? dialog.url : nil
    }
}

struct AppProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        AppProcessingView()
            .environmentObject(AppState())
    }
}
