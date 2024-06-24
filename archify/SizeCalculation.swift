//
//  SizeCalculation.swift
//  archify
//
//  Created by oct4pie on 6/24/24.
//

import Combine
import Foundation
import AppKit

class SizeCalculation: ObservableObject {
    @Published var selectedAppPaths: [String] = []
    @Published var unneededArchSizes: [(String, UInt64)] = []
    @Published var showCalculationResult = false
    @Published var progress: Double = 0.0
    @Published var isCalculating = false
    @Published var currentApp: String = ""
    @Published var maxConcurrentProcesses: Int = 4
    
    public let systemArch: String

    init() {
        systemArch = ProcessInfo.processInfo.machineArchitecture
    }

    func openPanel(canChooseFiles: Bool, canChooseDirectories: Bool, allowsMultipleSelection: Bool) -> [URL]? {
        let dialog = NSOpenPanel()
        dialog.title = "Choose directories"
        dialog.canChooseDirectories = canChooseDirectories
        dialog.canChooseFiles = canChooseFiles
        dialog.allowsMultipleSelection = allowsMultipleSelection

        if dialog.runModal() == .OK {
            return dialog.urls
        }
        return nil
    }

    func calculateUnneededArchSizes() {
        isCalculating = true
        progress = 0.0
        unneededArchSizes = []
        let totalFiles = selectedAppPaths.count
        var processedFiles = 0
        let processedFilesQueue = DispatchQueue(label: "com.universalApps.processedFilesQueue")
        let resultsQueue = DispatchQueue(label: "com.universalApps.resultsQueue", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: maxConcurrentProcesses)

        let dispatchGroup = DispatchGroup()
        let dispatchQueue = DispatchQueue.global(qos: .userInitiated)
        let finder = UniversalApps()

        for appPath in selectedAppPaths {
            dispatchGroup.enter()
            semaphore.wait()
            dispatchQueue.async {
                defer {
                    semaphore.signal()
                    dispatchGroup.leave()
                }

                let totalFilesInApp = finder.countFilesInApp(appPath: appPath)
                var processedFilesInApp = 0

                let size = finder.calculateUnneededArchSize(appPath: appPath, systemArch: self.systemArch, progressHandler: { _ in
                    processedFilesQueue.sync {
                        processedFilesInApp += 1
                        let progressValue = (Double(processedFiles) + (Double(processedFilesInApp) / Double(totalFilesInApp))) / Double(totalFiles)
                        DispatchQueue.main.async {
                            if processedFilesInApp % 100 == 0 {
                                self.progress = min(progressValue, 1.0)
                                self.currentApp = (appPath as NSString).lastPathComponent
                            }
                        }
                    }
                }, maxConcurrentProcesses: self.maxConcurrentProcesses)

                resultsQueue.sync(flags: .barrier) {
                    self.unneededArchSizes.append((appPath, size))
                }

                processedFilesQueue.sync(flags: .barrier) {
                    processedFiles += 1
                    let progressValue = Double(processedFiles) / Double(totalFiles)
                    DispatchQueue.main.async {
                        self.progress = min(progressValue, 1.0)
                    }
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            self.isCalculating = false
            self.showCalculationResult = true
            self.unneededArchSizes.sort { $0.1 > $1.1 }
        }
    }

    func humanReadableSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

