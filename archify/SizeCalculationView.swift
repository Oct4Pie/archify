//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import SwiftUI

struct SizeCalculationView: View {
    @EnvironmentObject var sizeCalculation: SizeCalculation
    @State private var showPerformanceOptions = false

    var body: some View {
        ScrollViewReader { proxy in
            ArchifyPage {
                ArchifyPageHeader(
                    title: "Estimate Space Savings",
                    subtitle: "Preview removable architecture data. Nothing is changed.",
                    systemImage: "chart.bar.xaxis"
                )

                selectionCard
                actionCard

                if sizeCalculation.isCalculating {
                    ArchifyProgressCard(
                        title: "Analyzing apps…",
                        detail: sizeCalculation.currentApp,
                        progress: sizeCalculation.progress,
                        control: sizeCalculation.control
                    )
                } else if sizeCalculation.wasStopped {
                    ArchifyNotice(
                        title: "Calculation canceled",
                        message: "Results cover only the apps measured before you canceled.",
                        kind: .info
                    )
                }

                if sizeCalculation.showCalculationResult {
                    resultsCard
                        .id("resultsSection")
                }
            }
            .onChange(of: sizeCalculation.showCalculationResult) { show in
                guard show else { return }
                withAnimation {
                    proxy.scrollTo("resultsSection", anchor: .top)
                }
            }
        }
    }

    private var selectionCard: some View {
        ArchifyCard(
            title: "Choose applications",
            subtitle: "Select one or more apps to measure. Your Mac is \(architectureName(sizeCalculation.systemArch)).",
            systemImage: "app.badge.checkmark"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        selectApps()
                    } label: {
                        Label(
                            sizeCalculation.selectedAppPaths.isEmpty
                                ? "Choose Apps…"
                                : "Add Apps…",
                            systemImage: "plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    if !sizeCalculation.selectedAppPaths.isEmpty {
                        Text("\(sizeCalculation.selectedAppPaths.count) selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if sizeCalculation.selectedAppPaths.isEmpty {
                    ArchifyEmptyState(
                        title: "No apps selected",
                        message: "Choose applications to see how much architecture data could be removed.",
                        systemImage: "app.dashed"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(sizeCalculation.selectedAppPaths, id: \.self) { path in
                            HStack(spacing: 10) {
                                Image(systemName: "app")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    removeApp(path)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from this calculation")
                                .accessibilityLabel(
                                    "Remove \((path as NSString).lastPathComponent)"
                                )
                            }
                            .padding(.vertical, 9)

                            if path != sizeCalculation.selectedAppPaths.last {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionCard: some View {
        ArchifyCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Estimate savings")
                            .font(.headline)
                        if sizeCalculation.selectedAppPaths.isEmpty {
                            Text("Choose at least one app.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button {
                        sizeCalculation.calculateUnneededArchSizes()
                    } label: {
                        Label(
                            sizeCalculation.isCalculating
                                ? "Calculating…"
                                : "Calculate",
                            systemImage: "calculator"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        sizeCalculation.isCalculating
                            || sizeCalculation.selectedAppPaths.isEmpty
                    )
                }

                ArchifyDisclosure(
                    "Advanced",
                    isExpanded: $showPerformanceOptions
                ) {
                    HStack {
                        Text("Analysis threads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: {
                                    Double(sizeCalculation.maxConcurrentProcesses)
                                },
                                set: {
                                    sizeCalculation.maxConcurrentProcesses = Int($0)
                                }
                            ),
                            in: 1...16,
                            step: 1
                        )
                        Text("\(sizeCalculation.maxConcurrentProcesses)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
    }

    private var resultsCard: some View {
        ArchifyCard(
            title: "Potential savings",
            subtitle: "Estimated removable architecture data for this Mac.",
            systemImage: "chart.bar.fill"
        ) {
            if sizeCalculation.unneededArchSizes.isEmpty {
                ArchifyEmptyState(
                    title: "No extra architecture data found",
                    message: "The selected apps do not appear to contain removable architecture slices for this Mac.",
                    systemImage: "checkmark.circle"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(sizeCalculation.unneededArchSizes, id: \.0) { app in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((app.0 as NSString).lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(app.0)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(sizeCalculation.humanReadableSize(app.1))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 10)

                        if app.0 != sizeCalculation.unneededArchSizes.last?.0 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func architectureName(_ architecture: String) -> String {
        switch architecture {
        case "arm64", "arm64e": return "Apple Silicon"
        case "x86_64": return "Intel"
        default: return architecture
        }
    }

    private func selectApps() {
        if let urls = sizeCalculation.openPanel(
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: true
        ) {
            let newPaths = urls.map(\.path)
            sizeCalculation.selectedAppPaths = Array(
                Set(sizeCalculation.selectedAppPaths + newPaths)
            ).sorted()
        }
    }

    private func removeApp(_ app: String) {
        sizeCalculation.selectedAppPaths.removeAll { $0 == app }
    }
}

struct SizeCalculationView_Previews: PreviewProvider {
    static var previews: some View {
        SizeCalculationView()
            .environmentObject(SizeCalculation())
    }
}
