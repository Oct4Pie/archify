//
//  SizeCalculation.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class SizeCalculation: ObservableObject {
    @Published var selectedAppPaths: [String] = []
    @Published var unneededArchSizes: [(String, UInt64)] = []
    @Published var showCalculationResult = false
    @Published var progress: Double = 0.0
    @Published var isCalculating = false
    @Published var currentApp: String = ""
    @Published var maxConcurrentProcesses: Int = 4
    /// The latest calculation was canceled, so results cover only part.
    @Published private(set) var wasStopped = false
    /// Pause/Resume and Cancel for the calculation.
    let control = RunControl()

    let systemArch: String

    init() {
        systemArch = ProcessInfo.processInfo.machineArchitecture
    }

    func openPanel(
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        allowsMultipleSelection: Bool
    ) -> [URL]? {
        let dialog = NSOpenPanel()
        dialog.title = "Choose applications"
        dialog.canChooseDirectories = canChooseDirectories
        dialog.canChooseFiles = canChooseFiles
        dialog.allowsMultipleSelection = allowsMultipleSelection
        if canChooseFiles && !canChooseDirectories {
            dialog.allowedContentTypes = [.application]
        }

        if dialog.runModal() == .OK {
            return dialog.urls
        }
        return nil
    }

    func calculateUnneededArchSizes() {
        guard !isCalculating, !selectedAppPaths.isEmpty else {
            return
        }

        let appPaths = selectedAppPaths
        let concurrency = max(1, maxConcurrentProcesses)
        isCalculating = true
        wasStopped = false
        control.begin()
        showCalculationResult = false
        progress = 0
        unneededArchSizes.removeAll()
        currentApp = ""

        // Process apps sequentially. UniversalApps already bounds parallel work
        // inside each app, so running several app-level worker pools at once
        // multiplies the requested concurrency and can cause process/resource
        // spikes on large installations.
        DispatchQueue.global(qos: .userInitiated).async {
            let finder = UniversalApps()
            var results: [(String, UInt64)] = []
            let appCount = appPaths.count

            for (appIndex, appPath) in appPaths.enumerated() {
                // Pausing waits here; canceling keeps the apps measured so far.
                guard self.control.checkpoint() else { break }
                let appName = URL(fileURLWithPath: appPath).lastPathComponent
                DispatchQueue.main.async {
                    self.currentApp = appName
                    self.progress = Double(appIndex) / Double(appCount)
                }

                let analysis = finder.analyzeApplication(
                    appPath: appPath,
                    systemArch: self.systemArch,
                    progressHandler: { processedFiles, totalFiles in
                        let appFraction: Double
                        if totalFiles > 0 {
                            appFraction = min(
                                Double(processedFiles)
                                    / Double(totalFiles),
                                1
                            )
                        } else {
                            appFraction = 1
                        }

                        self.progress = min(
                            (Double(appIndex) + appFraction)
                                / Double(appCount),
                            1
                        )
                        self.currentApp = appName
                    },
                    maxConcurrentProcesses: concurrency
                )
                results.append((appPath, analysis.removableSize))
            }

            results.sort { $0.1 > $1.1 }
            DispatchQueue.main.async {
                self.unneededArchSizes = results
                self.wasStopped = self.control.isCanceled
                self.control.finish()
                self.progress = 1
                self.currentApp = ""
                self.isCalculating = false
                self.showCalculationResult = true
            }
        }
    }

    func humanReadableSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
