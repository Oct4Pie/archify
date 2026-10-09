//
//  LanguageCleanerView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct LanguageCleanerView: View {
    @EnvironmentObject var viewModel: LanguageCleaner
    @State private var languageSearch = ""
    @State private var appSearch = ""
    @State private var showApps = false
    @State private var showActivity = false
    @State private var showRemovalConfirmation = false
    /// Affected apps that were open when Remove was clicked.
    @State private var openApps: [NSRunningApplication] = []

    var body: some View {
        ArchifyPage {
            ArchifyPageHeader(
                title: "Remove Languages",
                subtitle: "Free up space by removing translations you don't need. Your own languages are always kept.",
                systemImage: "character.book.closed.fill"
            )

            if viewModel.isScanning {
                ArchifyProgressCard(
                    title: "Scanning installed apps…",
                    detail: viewModel.currentlyScanningApp,
                    progress: viewModel.progress,
                    control: viewModel.control
                )
            } else if viewModel.isQuittingApps {
                ArchifyProgressCard(
                    title: "Waiting for open apps to quit…",
                    detail: "Apps that stay open, for example to save your work, are skipped and left unchanged."
                )
            } else if viewModel.isRemoving {
                ArchifyProgressCard(
                    title: "Removing languages…",
                    detail: viewModel.currentlyRemovingFile,
                    progress: viewModel.progress,
                    control: viewModel.control
                )
            } else {
                scanCard
                resultNotices

                if viewModel.apps.isEmpty {
                    ArchifyCard {
                        ArchifyEmptyState(
                            title: "Scan to find languages",
                            message: "Archify lists the languages your apps include and how much space each one uses. Scanning doesn't change anything.",
                            systemImage: "magnifyingglass"
                        )
                    }
                } else if summaries.isEmpty {
                    ArchifyNotice(
                        title: "Nothing to remove",
                        message: "Every language found is one you use or one an app needs.",
                        kind: .success
                    )
                } else {
                    languagesCard
                    if !viewModel.selectedLanguages.isEmpty {
                        appsCard
                    }
                    actionCard
                }
            }

            if !viewModel.removedFilesLog.isEmpty {
                ArchifyCard(title: "Activity", systemImage: "text.alignleft") {
                    ArchifyDisclosure("Show details", isExpanded: $showActivity) {
                        ArchifyLogView(
                            text: viewModel.removedFilesLog,
                            emptyMessage: "No language files have been removed."
                        )
                        .padding(.top, 8)
                    }
                }
            }
        }
        .confirmationDialog(
            openApps.isEmpty ? confirmationTitle : "Quit open apps before removing languages?",
            isPresented: $showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if openApps.isEmpty {
                Button("Remove", role: .destructive) {
                    viewModel.removeSelected()
                }
            } else {
                Button("Quit and Remove", role: .destructive) {
                    viewModel.quitAppsThenRemove(openApps)
                }
                if viewModel.openAffectedAppCount < viewModel.selectedAppCount {
                    Button("Skip Open Apps") {
                        viewModel.removeSkippingOpenApps()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                openAppsMessage
                    + "This frees about \(formatSize(viewModel.selectedSize)). "
                    + "Your languages and each app's main language are kept. "
                    + "Apps in /Applications require an administrator password. "
                    + "To get a language back, reinstall the app."
            )
        }
    }

    // MARK: - Step 1: scan

    private var scanCard: some View {
        ArchifyCard(
            title: "1. Scan apps",
            subtitle: "Find the languages your apps include. No changes are made.",
            systemImage: "magnifyingglass"
        ) {
            HStack(spacing: 18) {
                Button {
                    viewModel.scanForAppsAndLanguages()
                } label: {
                    Label(
                        viewModel.apps.isEmpty ? "Scan Apps" : "Scan Again",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)

                if !viewModel.apps.isEmpty {
                    ArchifyMetric(title: "Apps", value: "\(viewModel.apps.count)")
                    ArchifyMetric(title: "Removable languages", value: "\(summaries.count)")
                    ArchifyMetric(
                        title: "Space available",
                        value: formatSize(viewModel.totalRemovableSize),
                        emphasis: .green
                    )
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var resultNotices: some View {
        if viewModel.scanWasStopped {
            ArchifyNotice(
                title: "Scan canceled",
                message: "The list shows only the apps scanned before you canceled. Scan Again to check every app.",
                kind: .info
            )
        }

        if viewModel.notStartedCount > 0 {
            ArchifyNotice(
                title: "Removal canceled",
                message: "\(viewModel.notStartedCount) language \(viewModel.notStartedCount == 1 ? "folder was" : "folders were") not started and \(viewModel.notStartedCount == 1 ? "is" : "are") unchanged. They're still selected, so Remove continues where it stopped.",
                kind: .info
            )
        }

        if let result = viewModel.lastRemoval, result.folders > 0 {
            ArchifyNotice(
                title: "Freed \(formatSize(result.bytes))",
                message: result.folders == 1
                    ? "Removed 1 language folder."
                    : "Removed \(result.folders) language folders.",
                kind: .success
            )
        }

        if let failure = viewModel.removalFailures.first {
            let count = viewModel.removalFailures.count
            ArchifyNotice(
                title: count == 1
                    ? "1 language folder was not removed"
                    : "\(count) language folders were not removed",
                message: failure.reason + " They are still selected, so Remove tries them again.",
                kind: .destructive
            )
        }
    }

    // MARK: - Step 2: languages

    private var languagesCard: some View {
        ArchifyCard(
            title: "2. Choose languages to remove",
            subtitle: "Sorted by the space each language uses across your apps.",
            systemImage: "globe"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ArchifySearchField(placeholder: "Search languages", text: $languageSearch)

                    Button("Select All") {
                        viewModel.selectAllLanguages()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        viewModel.clearLanguages()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedLanguages.isEmpty)
                }

                if filteredSummaries.isEmpty {
                    ArchifyEmptyState(
                        title: "No matching languages",
                        message: "Try a different search.",
                        systemImage: "magnifyingglass"
                    )
                    .frame(minHeight: 160)
                } else {
                    List(filteredSummaries) { summary in
                        LanguageRow(
                            summary: summary,
                            isSelected: viewModel.selectedLanguages.contains(summary.key),
                            sizeText: formatSize(summary.removableSize)
                        ) {
                            viewModel.toggleLanguage(summary.key)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 240, maxHeight: 360)
                }

                if !viewModel.keptLanguageNames.isEmpty {
                    Label {
                        Text(
                            "Always kept: \(ListFormatter.localizedString(byJoining: viewModel.keptLanguageNames)) "
                                + "(your languages), plus each app's main language."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 3: apps

    private var appsCard: some View {
        ArchifyCard(
            title: "3. Review apps",
            subtitle: "Optional. Uncheck any app you want to leave unchanged.",
            systemImage: "square.grid.2x2"
        ) {
            ArchifyDisclosure(
                isExpanded: $showApps,
                content: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ArchifySearchField(placeholder: "Search apps", text: $appSearch)

                            Button("Check All") {
                                viewModel.includeAllApps()
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.excludedApps.isEmpty)

                            Button("Uncheck All") {
                                viewModel.excludeAllApps()
                            }
                            .buttonStyle(.bordered)
                        }
                        List(filteredAffectedApps) { app in
                            AppRemovalRow(
                                app: app,
                                isIncluded: !viewModel.excludedApps.contains(app.id),
                                detail: appDetail(app)
                            ) {
                                viewModel.toggleApp(app.id)
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 200, maxHeight: 320)
                    }
                    .padding(.top, 10)
                },
                label: {
                    Text(appsDisclosureTitle)
                        .font(.subheadline.weight(.medium))
                }
            )
        }
    }

    // MARK: - Action

    private var actionCard: some View {
        ArchifyCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(actionTitle)
                        .font(.headline)
                    Text(actionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    openApps = viewModel.runningAffectedApps()
                    showRemovalConfirmation = true
                } label: {
                    Label("Remove…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(viewModel.selectedFolderCount == 0)
            }
        }
    }

    // MARK: - Derived text

    private var openAppsMessage: String {
        guard !openApps.isEmpty else { return "" }
        let names = ListFormatter.localizedString(
            byJoining: RunningApplications.names(of: openApps)
        )
        return "\(names) \(openApps.count == 1 ? "is" : "are") open. "
            + "Changing an app while it runs can make it misbehave until it's reopened. "
            + "Archify asks each app to quit, as the Quit menu item would, so you can still save your work.\n\n"
    }

    private var summaries: [LanguageSummary] { viewModel.languageSummaries }

    private var filteredSummaries: [LanguageSummary] {
        guard !languageSearch.isEmpty else { return summaries }
        return summaries.filter {
            $0.displayName.localizedCaseInsensitiveContains(languageSearch)
                || $0.key.localizedCaseInsensitiveContains(languageSearch)
        }
    }

    private var filteredAffectedApps: [AppLanguage] {
        let apps = viewModel.affectedApps
        guard !appSearch.isEmpty else { return apps }
        return apps.filter { $0.appName.localizedCaseInsensitiveContains(appSearch) }
    }

    private var selectedLanguageNames: [String] {
        summaries
            .filter { viewModel.selectedLanguages.contains($0.key) }
            .map(\.displayName)
    }

    private var actionTitle: String {
        let count = selectedLanguageNames.count
        switch count {
        case 0: return "Select languages to remove"
        case 1: return "Remove \(selectedLanguageNames[0])"
        default: return "Remove \(count) languages"
        }
    }

    private var actionSummary: String {
        guard !viewModel.selectedLanguages.isEmpty else {
            return "Pick one or more languages above."
        }
        let appCount = viewModel.selectedAppCount
        guard appCount > 0 else {
            return "Every app that has these languages is unchecked."
        }
        return "From \(appCount) \(appCount == 1 ? "app" : "apps") · frees \(formatSize(viewModel.selectedSize))"
    }

    private var confirmationTitle: String {
        let appCount = viewModel.selectedAppCount
        let apps = "\(appCount) \(appCount == 1 ? "app" : "apps")"
        let names = selectedLanguageNames
        if names.count == 1 {
            return "Remove \(names[0]) from \(apps)?"
        }
        return "Remove \(names.count) languages from \(apps)?"
    }

    private var appsDisclosureTitle: String {
        let total = viewModel.affectedApps.count
        let excluded = viewModel.affectedApps.filter { viewModel.excludedApps.contains($0.id) }.count
        let base = "Show the \(total) \(total == 1 ? "app" : "apps") that will change"
        return excluded == 0 ? base : base + " (\(excluded) unchecked)"
    }

    private func appDetail(_ app: AppLanguage) -> String {
        let names = app.languages
            .filter { viewModel.selectedLanguages.contains($0) && !viewModel.isProtected($0, in: app) }
            .map { LanguageProtection.displayName(forKey: $0) }
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count > 3 ? " +\(names.count - 3) more" : ""
        return "\(shown)\(more) · \(formatSize(viewModel.removableSize(in: app, ignoringExclusion: true)))"
    }
}

/// Language folders are often only a few kilobytes, so sizes include KB.
private func formatSize(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

private struct LanguageRow: View {
    let summary: LanguageSummary
    let isSelected: Bool
    let sizeText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("\(summary.key) · in \(summary.removableAppCount) \(summary.removableAppCount == 1 ? "app" : "apps")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(sizeText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(isSelected ? "Selected" : "Not selected"), \(summary.displayName), "
                + "\(summary.removableAppCount) apps, \(sizeText)"
        )
    }
}

private struct AppRemovalRow: View {
    let app: AppLanguage
    let isIncluded: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: app.appName).deletingPathExtension().lastPathComponent)
                        .font(.subheadline.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(isIncluded ? 1 : 0.5)

                Spacer()

                if !isIncluded {
                    Text("Left unchanged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.appPath)
        .accessibilityLabel(
            "\(isIncluded ? "Included" : "Left unchanged"), \(app.appName), \(detail)"
        )
    }
}
