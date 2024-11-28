//
//  BatchProcessing.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import Combine
import Foundation
import AppKit

class BatchProcessing: ObservableObject {
    @Published var appSizes: [(String, UInt64, UInt64)] = []  // (app path, total size, savable size)
    @Published var processedAppSizes: [(String, UInt64, UInt64)] = []  // (app path, total size, savable size)
    @Published var scanningProgress: Double = 0.0
    @Published var processingProgress: Double = 0.0
    @Published var currentApp: String = ""
    @Published var selectedApps: Set<String> = []
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var totalSavedSpace: UInt64 = 0
    @Published var logMessages: String = ""
    @Published var initialTotalSize: UInt64 = 0
    @Published var finalTotalSize: UInt64 = 0
    @Published var savedSpaces: [String: UInt64] = [:]
    @Published var fdaManager = FullDiskAccessManager.shared
    
    private let appState = AppState()
    private let universalApps = UniversalApps()
    private var scanStartTime: Date?
    private var processStartTime: Date?
    private let fileManager = FileManager.default
    
    func startCalculatingSizes() {
        isScanning = true
        appSizes = []
        scanningProgress = 0.0
        currentApp = ""
        scanStartTime = Date()
        
        DispatchQueue.global(qos: .background).async {
            let systemArch = self.systemArchitecture()
            self.universalApps.produceSortedList(systemArch: systemArch, progressHandler: { app, processed, total in
                DispatchQueue.main.async {
                    self.currentApp = URL(fileURLWithPath: app).lastPathComponent
                    self.scanningProgress = Double(processed) / Double(total)
                }
            }) { sortedAppSizes in
                DispatchQueue.main.async {
                    self.appSizes = sortedAppSizes.map { (app, savableSize) in
                        let totalSize = self.calculateDirectorySize(app)
                        print("App: \(app), Total Size: \(totalSize), Savable Size: \(savableSize)")
                        return (app, totalSize, savableSize)
                    }
                    self.isScanning = false
                    self.scanStartTime = nil
                }
            }
        }
    }
    
    func startProcessingSelectedApps(completion: (() -> Void)? = nil) {
        guard !selectedApps.isEmpty else { return }
        
        isProcessing = true
        processingProgress = 0.0
        logMessages = ""
        totalSavedSpace = 0
        initialTotalSize = 0
        finalTotalSize = 0
        savedSpaces = [:]
        processStartTime = Date()
        
        guard HelperToolManager.shared.blessHelperTool() else {
            logMessages += "Failed to install helper tool.\n"
            isProcessing = false
            completion?()
            return
        }
        
        // Calculate initial total size and savable size
        for app in selectedApps {
            if let appInfo = appSizes.first(where: { $0.0 == app }) {
                initialTotalSize += appInfo.1  // Total size
                finalTotalSize += appInfo.1    // Initialize final size as total size
            }
        }
        
        HelperToolManager.shared.interactWithHelperTool(command: .checkFullDiskAccess) { [weak self] hasAccess, error in
            guard let self = self else { return }
            if hasAccess {
                self.processApps(completion: completion)
            } else {
                DispatchQueue.main.async {
                    self.promptForFullDiskAccess()
                    self.isProcessing = false
                }
                completion?()
            }
        }
    }
    
    private func processApps(completion: (() -> Void)? = nil) {
        let totalApps = selectedApps.count
        var processedApps = 0
        
        for app in selectedApps {
            DispatchQueue.main.async {
                self.currentApp = URL(fileURLWithPath: app).lastPathComponent
            }
            
            guard let appInfo = appSizes.first(where: { $0.0 == app }) else {
                processedApps += 1
                self.processingProgress = Double(processedApps) / Double(totalApps)
                continue
            }
            let originalSize = appInfo.1
            let expectedSavableSize = appInfo.2
            
            let appStateDict = self.appState.toDictionary()
            HelperToolManager.shared.interactWithHelperTool(command: .extractAndSignBinaries(dir: app, targetArch: self.systemArchitecture(), noSign: true, noEntitlements: true, appStateDict: appStateDict)) { success, errorString in
                DispatchQueue.main.async {
                    if success {
                        let newSize = self.calculateDirectorySize(app)
                        let actualSavedSpace = originalSize - newSize
                        
                        // Append to processedAppSizes
                        self.processedAppSizes.append((app, originalSize, actualSavedSpace))
                        
                        self.savedSpaces[app] = actualSavedSpace
                        self.totalSavedSpace += actualSavedSpace
                        self.finalTotalSize -= actualSavedSpace
                        
                        self.logMessages += "Processed \(app) successfully. Saved \(actualSavedSpace.humanReadableSize()) (Expected: \(expectedSavableSize.humanReadableSize()))\n"
                        
                        // Remove the app from the appSizes list
                        if let appIndex = self.appSizes.firstIndex(where: { $0.0 == app }) {
                            self.appSizes.remove(at: appIndex)
                        }
                        
                        // Also remove from selectedApps
                        self.selectedApps.remove(app)
                    } else {
                        self.logMessages += "Failed to process \(app): \(errorString ?? "Unknown error")\n"
                    }
                    
                    processedApps += 1
                    self.processingProgress = Double(processedApps) / Double(totalApps)
                    
                    if processedApps == totalApps {
                        self.isProcessing = false
                        self.processStartTime = nil
                        completion?()
                    }
                }
            }
        }
    }
    
    private func calculateDirectorySize(_ path: String) -> UInt64 {
        guard let enumerator = fileManager.enumerator(atPath: path) else { return 0 }
        var size: UInt64 = 0
        
        while let filePath = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(filePath)
            do {
                let attributes = try fileManager.attributesOfItem(atPath: fullPath)
                size += attributes[.size] as? UInt64 ?? 0
            } catch {
                print("Error calculating size for \(fullPath): \(error)")
            }
        }
        
        return size
    }
    
    func selectAllApps() {
        selectedApps = Set(appSizes.map { $0.0 })
    }
    
    func deselectAllApps() {
        selectedApps.removeAll()
    }
    
    private func systemArchitecture() -> String {
        let process = Process()
        process.launchPath = "/usr/bin/uname"
        process.arguments = ["-m"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return output
            }
        } catch {
            return "Unknown"
        }
        
        return "Unknown"
    }
    
    private func promptForFullDiskAccess() {
        fdaManager.requestFullDiskAccess()
    }
}

extension UInt64 {
    func humanReadableSize() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}
