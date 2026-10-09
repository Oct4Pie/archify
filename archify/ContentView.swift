import AppKit
import SwiftUI

enum UtilityType: String, CaseIterable {
    case appProcessor = "Optimize App"
    case sizeCalculation = "Space Savings"
    case langCleaner = "Languages"
    case batchProcessor = "Optimize Apps"
    case universalApps = "Installed Apps"

    var icon: String {
        switch self {
        case .appProcessor: return "wand.and.stars"
        case .sizeCalculation: return "externaldrive.badge.timemachine"
        case .langCleaner: return "globe"
        case .batchProcessor: return "square.stack.3d.up"
        case .universalApps: return "square.grid.2x2"
        }
    }

    var summary: String {
        switch self {
        case .appProcessor:
            return "Create a smaller copy of one app"
        case .sizeCalculation:
            return "Preview removable architecture data"
        case .langCleaner:
            return "Remove unused localization files"
        case .batchProcessor:
            return "Trim selected installed apps in place"
        case .universalApps:
            return "Inspect app architecture compatibility"
        }
    }

    static let optimizeTools: [UtilityType] = [
        .appProcessor,
        .batchProcessor
    ]

    static let utilityTools: [UtilityType] = [
        .sizeCalculation,
        .langCleaner,
        .universalApps
    ]
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var helperAccess = HelperAccess.shared
    @State private var selectedUtility: UtilityType? = .appProcessor

    var body: some View {
        NavigationView {
            sidebar
            mainContent
        }
        .navigationViewStyle(DoubleColumnNavigationViewStyle())
        .frame(minWidth: 900, minHeight: 640)
        .onAppear(perform: configureWindow)
        .sheet(item: helperAccessIssue) { issue in
            HelperAccessSheet(issue: issue, access: helperAccess)
        }
    }

    private var helperAccessIssue: Binding<HelperAccessIssue?> {
        Binding(
            get: { helperAccess.issue },
            set: { if $0 == nil { helperAccess.dismiss() } }
        )
    }

    private func configureWindow() {
        guard let window = NSApplication.shared.windows.first else { return }

        let autosaveName = NSWindow.FrameAutosaveName("ArchifyMainWindow")
        if !window.setFrameUsingName(autosaveName) {
            window.setContentSize(NSSize(width: 1080, height: 760))
            window.center()
        }
        window.minSize = NSSize(width: 900, height: 640)
        _ = window.setFrameAutosaveName(autosaveName)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("Archify")
                        .font(.headline)
                    Text("macOS app optimizer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            List {
                Section("OPTIMIZE") {
                    ForEach(UtilityType.optimizeTools, id: \.self) { utility in
                        sidebarButton(for: utility)
                    }
                }

                Section("TOOLS") {
                    ForEach(UtilityType.utilityTools, id: \.self) { utility in
                        sidebarButton(for: utility)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 205, idealWidth: 220, maxWidth: 250)
    }

    private func sidebarButton(for utility: UtilityType) -> some View {
        Button {
            selectedUtility = utility
        } label: {
            sidebarRow(for: utility)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedUtility == utility
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .help(utility.summary)
    }

    private func sidebarRow(for utility: UtilityType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: utility.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(
                    selectedUtility == utility
                        ? Color.accentColor
                        : Color.secondary
                )
                .frame(width: 20)

            Text(utility.rawValue)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var mainContent: some View {
        Group {
            if let selectedUtility {
                destinationView(for: selectedUtility)
                    .id(selectedUtility)
            } else {
                welcomeView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeView: some View {
        ArchifyPage {
            ArchifyPageHeader(
                title: "Welcome to Archify",
                subtitle: "Choose a tool from the sidebar to inspect or optimize your macOS applications.",
                systemImage: "shippingbox"
            )

            ArchifyNotice(
                title: "Built around safe defaults",
                message: "Archify previews what it can save, preserves signatures when possible, and uses Archify Helper only for protected changes inside /Applications.",
                kind: .info
            )
        }
    }

    @ViewBuilder
    private func destinationView(for utility: UtilityType) -> some View {
        switch utility {
        case .appProcessor:
            AppProcessingView()
        case .sizeCalculation:
            SizeCalculationView()
        case .langCleaner:
            LanguageCleanerView()
        case .batchProcessor:
            BatchProcessingView()
        case .universalApps:
            UniversalAppsView()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
            .environmentObject(LanguageCleaner())
            .environmentObject(BatchProcessing())
            .environmentObject(SizeCalculation())
            .environmentObject(UniversalAppsViewModel())
    }
}
