//
//  UniversalAppsView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct AppInfo: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let type: String
    let architectures: String
    let icon: NSImage?
}

struct UniversalAppsView: View {
    @EnvironmentObject var viewModel: UniversalAppsViewModel
    @State private var selectedApp: AppInfo?

    var body: some View {
        ArchifyPage {
            header

            if viewModel.isLoading {
                ArchifyProgressCard(
                    title: "Loading installed apps…",
                    detail: "Reading app metadata and architecture information.",
                    progress: nil
                )
            } else {
                overviewCard
                appListCard
            }
        }
        .sheet(item: $selectedApp) { app in
            InstalledAppDetailView(app: app)
        }
        .onAppear {
            viewModel.loadApps()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ArchifyPageHeader(
                title: "Installed Apps",
                subtitle: "Browse installed apps by architecture.",
                systemImage: "square.grid.2x2.fill"
            )

            Button {
                viewModel.reloadApps()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading)
        }
    }

    private var overviewCard: some View {
        ArchifyCard {
            HStack(spacing: 10) {
                ArchifySearchField(
                    placeholder: "Search apps",
                    text: $viewModel.searchText
                )
                .frame(maxWidth: 380)

                Picker("Type", selection: $viewModel.selectedType) {
                    ForEach(
                        UniversalAppsViewModel.AppType.allCases,
                        id: \.self
                    ) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .frame(width: 155)

                Picker("Sort", selection: $viewModel.sortOrder) {
                    Text("Name A–Z")
                        .tag(UniversalAppsViewModel.SortOrder.nameAscending)
                    Text("Name Z–A")
                        .tag(UniversalAppsViewModel.SortOrder.nameDescending)
                    Text("App Type")
                        .tag(UniversalAppsViewModel.SortOrder.type)
                }
                .frame(width: 140)

                Spacer()

                Text("\(filteredAndSortedApps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appListCard: some View {
        ArchifyCard(
            title: "Applications",
            subtitle: "Open an app for details.",
            systemImage: "app"
        ) {
            if filteredAndSortedApps.isEmpty {
                ArchifyEmptyState(
                    title: "No matching apps",
                    message: "Try a different search or app type filter.",
                    systemImage: "magnifyingglass"
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredAndSortedApps) { app in
                        Button {
                            selectedApp = app
                        } label: {
                            InstalledAppRow(app: app)
                        }
                        .buttonStyle(.plain)

                        if app.id != filteredAndSortedApps.last?.id {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    private var filteredAndSortedApps: [AppInfo] {
        viewModel.apps
            .filter { app in
                let searchMatches =
                    viewModel.searchText.isEmpty
                    || app.name.localizedCaseInsensitiveContains(
                        viewModel.searchText
                    )

                let typeMatches =
                    viewModel.selectedType == .all
                    || normalizedType(app.type)
                        == viewModel.selectedType.rawValue

                return searchMatches && typeMatches
            }
            .sorted { lhs, rhs in
                switch viewModel.sortOrder {
                case .nameAscending:
                    return lhs.name.localizedCaseInsensitiveCompare(
                        rhs.name
                    ) == .orderedAscending
                case .nameDescending:
                    return lhs.name.localizedCaseInsensitiveCompare(
                        rhs.name
                    ) == .orderedDescending
                case .type:
                    if lhs.type == rhs.type {
                        return lhs.name.localizedCaseInsensitiveCompare(
                            rhs.name
                        ) == .orderedAscending
                    }
                    return lhs.type.localizedCaseInsensitiveCompare(
                        rhs.type
                    ) == .orderedAscending
                }
            }
    }

    private func normalizedType(_ type: String) -> String {
        type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct InstalledAppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 12) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    ArchifyStatusPill(
                        text: displayType,
                        systemImage: typeSymbol,
                        color: typeColor
                    )

                    Text(architectureSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(app.name), \(displayType), \(architectureSummary)"
        )
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 42, height: 42)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 9,
                        style: .continuous
                    )
                )
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
        }
    }

    private var architectureSummary: String {
        let value = app.architectures.lowercased()
        if value.contains("apple silicon") && value.contains("intel") {
            return "Apple Silicon + Intel"
        }
        if value.contains("apple silicon") {
            return "Apple Silicon"
        }
        if value.contains("intel") {
            return "Intel"
        }
        return app.architectures.isEmpty ? "Unknown architecture" : app.architectures
    }

    private var displayType: String {
        app.type.lowercased() == "native" ? "This Mac" : app.type
    }

    private var typeColor: Color {
        switch app.type.lowercased() {
        case "universal": return .green
        case "native", "apple silicon": return .blue
        case "intel": return .orange
        default: return .secondary
        }
    }

    private var typeSymbol: String {
        switch app.type.lowercased() {
        case "universal": return "arrow.triangle.branch"
        case "native", "apple silicon": return "cpu"
        case "intel": return "desktopcomputer"
        default: return "questionmark.circle"
        }
    }
}

private struct InstalledAppDetailView: View {
    let app: AppInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                appIcon

                VStack(alignment: .leading, spacing: 6) {
                    Text(app.name)
                        .font(.title2.weight(.semibold))

                    ArchifyStatusPill(
                        text: app.type.lowercased() == "native" ? "This Mac" : app.type,
                        systemImage: "cpu",
                        color: .accentColor
                    )
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                ArchifyLabeledValue(
                    title: "Architectures",
                    value: app.architectures
                )
                ArchifyLabeledValue(
                    title: "Location",
                    value: app.path
                )
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 310)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 15,
                        style: .continuous
                    )
                )
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
        }
    }
}

final class UniversalAppsViewModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isLoading = true
    @Published var searchText = ""
    @Published var sortOrder: SortOrder = .nameAscending
    @Published var selectedType: AppType = .all

    private var hasLoaded = false

    func loadApps() {
        guard !hasLoaded else { return }
        isLoading = true
        UniversalApps.shared.findApps { loadedApps in
            DispatchQueue.main.async {
                self.apps = loadedApps.map {
                    AppInfo(
                        name: $0.name,
                        path: $0.path,
                        type: $0.type,
                        architectures: $0.architectures,
                        icon: $0.icon
                    )
                }
                self.isLoading = false
                self.hasLoaded = true
            }
        }
    }

    func reloadApps() {
        isLoading = true
        UniversalApps.shared.findApps { loadedApps in
            DispatchQueue.main.async {
                self.apps = loadedApps.map {
                    AppInfo(
                        name: $0.name,
                        path: $0.path,
                        type: $0.type,
                        architectures: $0.architectures,
                        icon: $0.icon
                    )
                }
                self.isLoading = false
            }
        }
    }

    enum SortOrder: Hashable {
        case nameAscending
        case nameDescending
        case type
    }

    enum AppType: String, CaseIterable {
        case all
        case universal
        case native
        case intel
        case appleSilicon = "apple silicon"
        case unknown
        case other

        var displayName: String {
            switch self {
            case .all: return "All Types"
            case .universal: return "Universal"
            case .native: return "This Mac"
            case .intel: return "Intel"
            case .appleSilicon: return "Apple Silicon"
            case .unknown: return "Unknown"
            case .other: return "Other"
            }
        }
    }
}
