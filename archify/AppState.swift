//
//  AppState.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import AppKit
import Combine
import Foundation

class AppState: ObservableObject {
    @Published var inputDir: String = ""
    @Published var outputDir: String = ""
    /// Name for the copy when the app's own name is taken at the
    /// destination ("Keep Both"); nil uses the app's name.
    @Published var outputName: String?
    /// The copy the latest run created, so the screen can show it as the
    /// result rather than as a name conflict.
    @Published var lastCopyPath: String?
    @Published var selectedArch: String = ""
    @Published var useCodesign: Bool = false
    @Published var useLDID: Bool = false
    @Published var ldidPath: String = ""
    @Published var entitlements: Bool = false
    @Published var launchSign: Bool = false
    @Published var logMessages: String = ""
    @Published var initialAppSize: UInt64 = 0
    @Published var finalAppSize: UInt64 = 0
    @Published var isProcessing: Bool = false
    
    let architectures = ["arm64", "arm64e", "x86_64"]
    
    private var logBuffer: [String] = []
    private let logQueue = DispatchQueue(label: "com.oct4pie.archify.logs")
    private var logFlushScheduled = false
    
    func appendLog(_ message: String) {
        logQueue.async {
            self.logBuffer.append(message)
            guard !self.logFlushScheduled else { return }
            self.logFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.flushLogMessages()
            }
        }
    }
    
    private func flushLogMessages() {
        let messages: [String] = logQueue.sync {
            let messages = self.logBuffer
            self.logBuffer.removeAll()
            self.logFlushScheduled = false
            return messages
        }
        if !messages.isEmpty {
            logMessages += messages.joined(separator: "\n") + "\n"
        }
    }
    
    func findLdid() -> String? {
        if !ldidPath.isEmpty {
            return isCompatibleLdidExecutable(atPath: ldidPath) ? ldidPath : nil
        }

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var paths = pathEnv.split(separator: ":").map(String.init)
        for commonPath in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(commonPath) {
            paths.append(commonPath)
        }

        for path in paths {
            let ldidFullPath = (path as NSString).appendingPathComponent("ldid")
            if isCompatibleLdidExecutable(atPath: ldidFullPath) {
                return ldidFullPath
            }
        }
        return nil
    }

    func isCompatibleLdidExecutable(atPath path: String) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path),
              fileManager.isExecutableFile(atPath: path)
        else {
            return false
        }

        guard let architectures = MachOInspector.architectures(
            atPath: path
        ) else {
            return false
        }

        return ArchitectureUtilities.executableSupportsHost(
            architectures: architectures,
            hostArchitecture: ProcessInfo.processInfo.machineArchitecture
        )
    }
    
    func processApp() {
        // Read the user's choices on the main thread, where SwiftUI writes
        // them, before handing the work to a background queue.
        let inputDir = self.inputDir
        let outputDir = self.outputDir
        let selectedArch = self.selectedArch
        let entitlements = self.entitlements
        let launchSign = self.launchSign
        let outputName = self.outputName

        DispatchQueue.global().async {
            guard !inputDir.isEmpty, !outputDir.isEmpty else {
                DispatchQueue.main.async {
                    self.appendLog("Please select both input and output directories.")
                    self.isProcessing = false
                }
                return
            }
            self.appendLog("Starting...")
            
            let fileOps = FileOperations(appState: self)
            do {
                let duplicatedDir = try fileOps.duplicateApp(
                    appDir: inputDir,
                    outputDir: outputDir,
                    named: outputName
                )

                self.appendLog("Created copy at \(duplicatedDir)")
                DispatchQueue.main.async {
                    self.lastCopyPath = duplicatedDir
                }
                let initialSize = UniversalApps().calculateDirectorySize(path: inputDir)
                DispatchQueue.main.async {
                    self.initialAppSize = initialSize
                }
                self.appendLog("Initial App Size: \(initialSize) bytes")
                self.appendLog("Processing...")

                let processDuplicatedApp = {
                    fileOps.extractAndSignBinaries(
                        in: duplicatedDir,
                        targetArch: selectedArch,
                        noSign: false,
                        noEntitlements: !entitlements
                    )
                }

                if launchSign {
                    self.openApp(at: duplicatedDir) { success in
                        if success {
                            self.appendLog("App launched and closed successfully.")
                            DispatchQueue.global().async(execute: processDuplicatedApp)
                        } else {
                            self.appendLog("Failed to launch or close the copied app.")
                            self.isProcessing = false
                        }
                    }
                } else {
                    processDuplicatedApp()
                }
            } catch {
                self.appendLog("Failed to duplicate app: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.lastCopyPath = nil
                    self.isProcessing = false
                }
            }
        }
    }
    
    private func openApp(at path: String, completion: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        let appURL = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()

        workspace.openApplication(at: appURL, configuration: configuration) { app, error in
            if let error {
                self.appendLog("Failed to launch app: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            guard let app else {
                self.appendLog("Failed to obtain app reference.")
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Preserve the existing cache-warmup delay, but retain the actual
            // NSRunningApplication object. Killing a remembered PID later can
            // target an unrelated process if the launched app exits and macOS
            // reuses that PID.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                if app.isTerminated {
                    DispatchQueue.main.async { completion(true) }
                    return
                }

                _ = app.terminate()
                if self.waitForTermination(of: app, timeout: 5) {
                    DispatchQueue.main.async { completion(true) }
                    return
                }

                _ = app.forceTerminate()
                let terminated = self.waitForTermination(of: app, timeout: 5)
                DispatchQueue.main.async { completion(terminated) }
            }
        }
    }

    private func waitForTermination(
        of app: NSRunningApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return app.isTerminated
    }
}
