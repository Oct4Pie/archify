//
//  BatchProcessingView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct BatchProcessingView: View {
    @EnvironmentObject var batchProcessing: BatchProcessing

    @State private var searchText = ""
    @State private var sortOption: BatchSortOption = .savingsDescending
    @State private var showProcessingConfirmation = false
    @State private var showActivity = false
    /// Selected apps that were open when Optimize was clicked.
    @State private var openApps: [NSRunningApplication] = []

    var body: some View {
        ArchifyPage {
            ArchifyPageHeader(
                title: "Optimize Multiple Apps",
                subtitle: "Scan, select, then optimize in place.",
                systemImage: "square.stack.3d.up"
            )

            scanCard

            if batchProcessing.isScanning {
                ArchifyProgressCard(
                    title: "Scanning for universal apps…",
                    detail: batchProcessing.currentApp,
                    progress: batchProcessing.scanningProgress,
                    control: batchProcessing.control
                )
            } else if batchProcessing.isQuittingApps {
                ArchifyProgressCard(
                    title: "Waiting for open apps to quit…",
                    detail: "Apps that stay open, for example to save your work, are skipped and left unchanged."
                )
            } else if batchProcessing.isProcessing {
                ArchifyProgressCard(
                    title: "Optimizing selected apps…",
                    detail: batchProcessing.currentApp,
                    progress: batchProcessing.processingProgress,
                    control: batchProcessing.control
                )
            } else if batchProcessing.scanWasStopped {
                ArchifyNotice(
                    title: "Scan canceled",
                    message: "The list shows only the apps scanned before you canceled. Scan Again to check every app.",
                    kind: .info
                )
            }

            if hasRunOutcome {
                resultsCard
            }

            if !batchProcessing.appSizes.isEmpty {
                appSelectionCard
                optimizeCard
            } else if !batchProcessing.isScanning {
                ArchifyCard {
                    ArchifyEmptyState(
                        title: "No scan results yet",
                        message: "Run a scan to find universal apps that contain architecture data your Mac does not need.",
                        systemImage: "magnifyingglass"
                    )
                }
            }

            if !batchProcessing.logMessages.isEmpty {
                ArchifyCard(
                    title: "Activity",
                    subtitle: "Technical details from the latest optimization run.",
                    systemImage: "text.alignleft"
                ) {
                    ArchifyDisclosure(
                        "Show technical details",
                        isExpanded: $showActivity
                    ) {
                        ArchifyLogView(text: batchProcessing.logMessages)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .confirmationDialog(
            openApps.isEmpty
                ? "Optimize selected apps?"
                : "Quit open apps before optimizing?",
            isPresented: $showProcessingConfirmation,
            titleVisibility: .visible
        ) {
            if openApps.isEmpty {
                Button(
                    batchProcessing.selectedApps.count == 1
                        ? "Optimize 1 App"
                        : "Optimize \(batchProcessing.selectedApps.count) Apps",
                    role: .destructive
                ) {
                    batchProcessing.startProcessingSelectedApps()
                }
            } else {
                Button("Quit and Optimize", role: .destructive) {
                    batchProcessing.quitAppsThenProcess(openApps)
                }
                if openSelectedAppCount < batchProcessing.selectedApps.count {
                    Button("Skip Open Apps") {
                        batchProcessing.processSkippingOpenApps()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(processingConfirmationMessage)
        }
    }

    private var scanCard: some View {
        ArchifyCard(
            title: "1. Scan apps",
            subtitle: "Find apps that can be reduced. No changes are made.",
            systemImage: "magnifyingglass"
        ) {
            HStack(spacing: 18) {
                Button {
                    batchProcessing.startCalculatingSizes()
                } label: {
                    Label(
                        batchProcessing.appSizes.isEmpty
                            ? "Scan Apps"
                            : "Scan Again",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    batchProcessing.isScanning
                        || batchProcessing.isProcessing
                        || batchProcessing.isQuittingApps
                )

                if !batchProcessing.appSizes.isEmpty {
                    ArchifyMetric(
                        title: "Optimizable apps",
                        value: "\(batchProcessing.appSizes.count)"
                    )
                    ArchifyMetric(
                        title: "Potential savings",
                        value: totalPotentialSavings.humanReadableSize(),
                        emphasis: .green
                    )
                }

                Spacer()
            }
        }
    }

    private var appSelectionCard: some View {
        ArchifyCard(
            title: "2. Choose apps",
            subtitle: "Select only the apps you want to change.",
            systemImage: "checklist"
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ArchifySearchField(
                        placeholder: "Search apps",
                        text: $searchText
                    )

                    Picker("Sort", selection: $sortOption) {
                        ForEach(BatchSortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 190)

                    Button("Select All") {
                        batchProcessing.selectAllApps()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        batchProcessing.deselectAllApps()
                    }
                    .buttonStyle(.bordered)
                    .disabled(batchProcessing.selectedApps.isEmpty)
                }

                Divider()

                if filteredAndSortedApps.isEmpty {
                    ArchifyEmptyState(
                        title: "No matching apps",
                        message: "Try a different search.",
                        systemImage: "magnifyingglass"
                    )
                } else {
                    List {
                        ForEach(filteredAndSortedApps, id: \.0) {
                            app,
                            totalSize,
                            savableSize in
                            BatchAppRow(
                                app: app,
                                totalSize: totalSize,
                                savableSize: savableSize,
                                isSelected: batchProcessing.selectedApps.contains(app)
                            ) {
                                if batchProcessing.selectedApps.contains(app) {
                                    batchProcessing.selectedApps.remove(app)
                                } else {
                                    batchProcessing.selectedApps.insert(app)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 260, maxHeight: 420)
                }
            }
        }
    }

    private var optimizeCard: some View {
        ArchifyCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Optimize selected")
                        .font(.headline)
                    Text(optimizeSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    openApps = batchProcessing.runningSelectedApps()
                    showProcessingConfirmation = true
                } label: {
                    Label(
                        batchProcessing.isProcessing
                            ? "Optimizing…"
                            : "Optimize Selected…",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    batchProcessing.selectedApps.isEmpty
                        || batchProcessing.isProcessing
                        || batchProcessing.isScanning
                        || batchProcessing.isQuittingApps
                )
            }
        }
    }

    /// Every finished run shows an outcome, including runs where every app
    /// failed, so a failure is never hidden in the collapsed activity log.
    private var hasRunOutcome: Bool {
        !batchProcessing.isProcessing
            && (
                !batchProcessing.processedAppSizes.isEmpty
                    || !batchProcessing.failedApps.isEmpty
                    || !batchProcessing.notStartedApps.isEmpty
            )
    }

    private var resultsTitle: String {
        if !batchProcessing.notStartedApps.isEmpty {
            return "Optimization canceled"
        }
        if batchProcessing.failedApps.isEmpty {
            return "Optimization results"
        }
        if batchProcessing.processedAppSizes.isEmpty {
            return "Optimization didn't complete"
        }
        return "Optimization finished with problems"
    }

    private var resultsSubtitle: String {
        var parts: [String] = []
        let failed = batchProcessing.failedApps.count
        if failed > 0 {
            parts.append(
                "\(failed) \(failed == 1 ? "app was" : "apps were") not changed. "
                    + "Each failed app was left as it was."
            )
        }
        let notStarted = batchProcessing.notStartedApps.count
        if notStarted > 0 {
            parts.append(
                "Canceled before \(notStarted) \(notStarted == 1 ? "app" : "apps"), "
                    + "which \(notStarted == 1 ? "is" : "are") unchanged and still selected."
            )
        }
        return parts.isEmpty
            ? "Space saved by the apps completed in the latest run."
            : parts.joined(separator: " ")
    }

    private var resultsCard: some View {
        ArchifyCard(
            title: resultsTitle,
            subtitle: resultsSubtitle,
            systemImage: !batchProcessing.notStartedApps.isEmpty
                ? "stop.circle.fill"
                : batchProcessing.failedApps.isEmpty
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
        ) {
            ForEach(batchProcessing.failedApps, id: \.path) { failure in
                ArchifyNotice(
                    title: (failure.path as NSString).lastPathComponent,
                    message: failure.reason,
                    kind: .destructive
                )
            }

            if !batchProcessing.processedAppSizes.isEmpty {
                HStack(spacing: 24) {
                    ArchifyMetric(
                        title: "Apps optimized",
                        value: "\(batchProcessing.processedAppSizes.count)"
                    )
                    ArchifyMetric(
                        title: "Before",
                        value: batchProcessing.initialTotalSize.humanReadableSize()
                    )
                    ArchifyMetric(
                        title: "After",
                        value: batchProcessing.finalTotalSize.humanReadableSize()
                    )
                    ArchifyMetric(
                        title: "Saved",
                        value: batchProcessing.totalSavedSpace.humanReadableSize(),
                        emphasis: .green
                    )
                }

                Divider()

                VStack(spacing: 0) {
                    ForEach(batchProcessing.processedAppSizes, id: \.0) {
                        app,
                        _,
                        savedSize in
                        HStack {
                            Text((app as NSString).lastPathComponent)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(savedSize.humanReadableSize())
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 8)

                        if app != batchProcessing.processedAppSizes.last?.0 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var filteredAndSortedApps: [(String, UInt64, UInt64)] {
        let filtered = batchProcessing.appSizes.filter {
            searchText.isEmpty
                || ($0.0 as NSString).lastPathComponent
                    .localizedCaseInsensitiveContains(searchText)
        }

        return filtered.sorted { lhs, rhs in
            switch sortOption {
            case .savingsDescending:
                return lhs.2 > rhs.2
            case .savingsAscending:
                return lhs.2 < rhs.2
            case .nameAscending:
                return (lhs.0 as NSString).lastPathComponent
                    .localizedCaseInsensitiveCompare(
                        (rhs.0 as NSString).lastPathComponent
                    ) == .orderedAscending
            case .nameDescending:
                return (lhs.0 as NSString).lastPathComponent
                    .localizedCaseInsensitiveCompare(
                        (rhs.0 as NSString).lastPathComponent
                    ) == .orderedDescending
            }
        }
    }

    private var totalPotentialSavings: UInt64 {
        batchProcessing.appSizes.reduce(0) { $0 + $1.2 }
    }

    private var selectedPotentialSavings: UInt64 {
        batchProcessing.appSizes.reduce(0) { total, item in
            batchProcessing.selectedApps.contains(item.0)
                ? total + item.2
                : total
        }
    }

    private var selectedSystemAppCount: Int {
        batchProcessing.selectedApps.filter {
            URL(fileURLWithPath: $0).path.hasPrefix("/Applications/")
        }.count
    }

    private var optimizeSummary: String {
        guard !batchProcessing.selectedApps.isEmpty else {
            return "Select one or more apps first."
        }

        var summary =
            "\(batchProcessing.selectedApps.count) "
            + (batchProcessing.selectedApps.count == 1 ? "app" : "apps")
            + " selected · "
            + "\(selectedPotentialSavings.humanReadableSize()) estimated savings."

        if selectedSystemAppCount > 0 {
            summary += " \(selectedSystemAppCount) in /Applications need an administrator password."
        }

        return summary
    }

    private var openSelectedAppCount: Int {
        RunningApplications.runningAppPaths(
            in: Array(batchProcessing.selectedApps)
        ).count
    }

    private var processingConfirmationMessage: String {
        var message = ""
        if !openApps.isEmpty {
            let names = ListFormatter.localizedString(
                byJoining: RunningApplications.names(of: openApps)
            )
            message += "\(names) \(openApps.count == 1 ? "is" : "are") open. "
                + "Changing an app while it runs can make it misbehave until it's reopened. "
                + "Archify asks each app to quit, as the Quit menu item would, so you can still save your work.\n\n"
        }
        message += "This modifies the selected apps in place."

        if selectedSystemAppCount > 0 {
            message += " Changes to apps in /Applications require an administrator password."
        }

        return message
    }
}

private enum BatchSortOption: String, CaseIterable, Identifiable {
    case savingsDescending
    case savingsAscending
    case nameAscending
    case nameDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .savingsDescending: return "Savings: High to Low"
        case .savingsAscending: return "Savings: Low to High"
        case .nameAscending: return "Name: A to Z"
        case .nameDescending: return "Name: Z to A"
        }
    }
}

private struct BatchAppRow: View {
    let app: String
    let totalSize: UInt64
    let savableSize: UInt64
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text((app as NSString).lastPathComponent)
                        .font(.subheadline.weight(.medium))
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(savableSize.humanReadableSize())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                    Text("of \(totalSize.humanReadableSize())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(isSelected ? "Selected" : "Not selected"), "
                + "\((app as NSString).lastPathComponent), "
                + "\(savableSize.humanReadableSize()) potential savings"
        )
    }
}

struct BatchProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        let batchProcessing = BatchProcessing()
        batchProcessing.appSizes = [
            ("/Applications/Sample.app", 1_000_000_000, 200_000_000),
            ("/Applications/Another.app", 2_000_000_000, 500_000_000)
        ]
        return BatchProcessingView()
            .environmentObject(batchProcessing)
    }
}
