//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
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
    private var cancellables = Set<AnyCancellable>()
    
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
        guard !isCalculating else { return }
        guard !selectedAppPaths.isEmpty else { return }
        
        isCalculating = true
        resetCalculationState()
        
        let totalFiles = selectedAppPaths.count
        let finder = UniversalApps()
        
        let dispatchGroup = DispatchGroup()
        let dispatchQueue = DispatchQueue.global(qos: .userInitiated)
        let semaphore = DispatchSemaphore(value: maxConcurrentProcesses)
        
        for appPath in selectedAppPaths {
            dispatchGroup.enter()
            semaphore.wait()
            dispatchQueue.async {
                defer {
                    semaphore.signal()
                    dispatchGroup.leave()
                }
                self.processAppPath(appPath, finder: finder, totalFiles: totalFiles)
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            self.finalizeCalculation()
        }
    }
    
    private func resetCalculationState() {
        progress = 0.0
        unneededArchSizes.removeAll()
    }
    
    private func processAppPath(_ appPath: String, finder: UniversalApps, totalFiles: Int) {
        let totalFilesInApp = finder.countFilesInApp(appPath: appPath)
        var processedFilesInApp = 0
        
        let size = finder.calculateUnneededArchSize(appPath: appPath, systemArch: self.systemArch, progressHandler: { _ in
            processedFilesInApp += 1
            let progressValue = self.calculateProgress(processedFilesInApp, totalFilesInApp, totalFiles)
            self.updateProgress(progressValue, appPath: appPath, processedFilesInApp: processedFilesInApp)
        }, maxConcurrentProcesses: self.maxConcurrentProcesses)
        
        DispatchQueue.main.async {
            self.unneededArchSizes.append((appPath, size))
        }
    }
    
    private func calculateProgress(_ processedFilesInApp: Int, _ totalFilesInApp: Int, _ totalFiles: Int) -> Double {
        return (Double(processedFilesInApp) / Double(totalFilesInApp)) / Double(totalFiles)
    }
    
    private func updateProgress(_ progressValue: Double, appPath: String, processedFilesInApp: Int) {
        DispatchQueue.main.async {
            self.progress = min(progressValue, 1.0)
            if processedFilesInApp % 100 == 0 {
                self.currentApp = (appPath as NSString).lastPathComponent
            }
        }
    }
    
    private func finalizeCalculation() {
        isCalculating = false
        showCalculationResult = true
        unneededArchSizes.sort { $0.1 > $1.1 }
    }
    
    func humanReadableSize(_ size: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
