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
    @Published var selectedArch: String = ""
    @Published var useCodesign: Bool = false
    @Published var useLDID: Bool = false
    @Published var ldidPath: String = ""
    @Published var entitlements: Bool = false
    @Published var launchSign: Bool = true
    @Published var logMessages: String = ""
    @Published var initialAppSize: UInt64 = 0
    @Published var finalAppSize: UInt64 = 0
    @Published var isProcessing: Bool = false
    
    let architectures = ["arm64", "arm64e", "x86_64", "i386"]
    let LIPO = "/usr/bin/lipo"
    let FILE = "/usr/bin/file"
    
    private var logBuffer: [String] = []
    private var logQueue = DispatchQueue(label: "logQueue", attributes: .concurrent)
    private var logTimer: Timer?
    
    init() {
        startLogTimer()
    }
    
    deinit {
        logTimer?.invalidate()
    }
    
    func appendLog(_ message: String) {
        logQueue.async(flags: .barrier) {
            self.logBuffer.append(message)
        }
    }
    
    private func startLogTimer() {
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.updateLogMessages()
        }
    }
    
    private func updateLogMessages() {
        var messages: [String] = []
        logQueue.sync {
            messages = self.logBuffer
            self.logBuffer.removeAll()
        }
        DispatchQueue.main.async {
            if !messages.isEmpty {
                self.logMessages += messages.joined(separator: "\n") + "\n"
            }
        }
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "inputDir": inputDir,
            "outputDir": outputDir,
            "selectedArch": selectedArch,
            "useLDID": useLDID,
            "ldidPath": ldidPath,
            "entitlements": entitlements,
            "useCodesign": useCodesign,
            "launchSign": launchSign,
            "isProcessing": isProcessing,
            "initialAppSize": initialAppSize,
            "finalAppSize": finalAppSize,
            "logMessages": logMessages,
        ]
    }
    
    static func fromDictionary(_ dict: [String: Any]) -> AppState {
        let appState = AppState()
        appState.inputDir = dict["inputDir"] as? String ?? ""
        appState.outputDir = dict["outputDir"] as? String ?? ""
        appState.selectedArch = dict["selectedArch"] as? String ?? ""
        appState.useLDID = dict["useLDID"] as? Bool ?? false
        appState.ldidPath = dict["ldidPath"] as? String ?? ""
        appState.entitlements = dict["entitlements"] as? Bool ?? false
        appState.useCodesign = dict["useCodesign"] as? Bool ?? false
        appState.launchSign = dict["launchSign"] as? Bool ?? false
        appState.isProcessing = dict["isProcessing"] as? Bool ?? false
        appState.initialAppSize = dict["initialAppSize"] as? UInt64 ?? 0
        appState.finalAppSize = dict["finalAppSize"] as? UInt64 ?? 0
        appState.logMessages = dict["logMessages"] as? String ?? ""
        return appState
    }
    
    func findLdid() -> String? {
        if !ldidPath.isEmpty {
            return ldidPath
        }
        
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = pathEnv.split(separator: ":").map(String.init)
        
        for path in paths {
            let ldidFullPath = (path as NSString).appendingPathComponent("ldid")
            if FileManager.default.fileExists(atPath: ldidFullPath) {
                return ldidFullPath
            }
        }
        return Bundle.main.path(forResource: "ldid", ofType: nil)
    }
    
    func processApp() {
        DispatchQueue.global().async {
            guard !self.inputDir.isEmpty, !self.outputDir.isEmpty else {
                DispatchQueue.main.async {
                    self.appendLog("Please select both input and output directories.")
                    self.isProcessing = false
                }
                return
            }
            self.appendLog("Starting...")
            
            let fileOps = FileOperations(appState: self)
            do {
                if let duplicatedDir = try fileOps.duplicateApp(
                    appDir: self.inputDir, outputDir: self.outputDir) {
                    self.appendLog("Created copy at \(duplicatedDir)")
                    let universalApps = UniversalApps()
                    self.initialAppSize = universalApps.calculateDirectorySize(path: self.inputDir)
                    self.appendLog("Initial App Size: \(self.initialAppSize) bytes")
                    self.appendLog("Processing...")
                    
                    if self.launchSign {
                        self.openApp(at: duplicatedDir) { success in
                            if success {
                                self.appendLog("App loaded successfully, now closing it.")
                                
                                self.requestDirectoryAccess(directory: duplicatedDir) {
                                    fileOps.extractAndSignBinaries(
                                        in: duplicatedDir, targetArch: self.selectedArch, noSign: false,
                                        noEntitlements: !self.entitlements)
                                }
                            } else {
                                self.appendLog("Failed to open the app.")
                                self.isProcessing = false
                            }
                        }
                    } else {
                        self.requestDirectoryAccess(directory: duplicatedDir) {
                            fileOps.extractAndSignBinaries(
                                in: duplicatedDir, targetArch: self.selectedArch, noSign: false,
                                noEntitlements: !self.entitlements)
                        }
                    }
                } else {
                    self.appendLog("Failed to duplicate app.")
                }
            } catch {
                self.appendLog("Failed to duplicate app: \(error.localizedDescription)")
            }
        }
    }
    
    private func requestDirectoryAccess(directory: String, completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.message = "Please select the duplicated .app directory."
            openPanel.prompt = "Select"
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = false
            openPanel.directoryURL = URL(fileURLWithPath: directory)
            
            openPanel.begin { response in
                if response == .OK {
                    if let selectedURL = openPanel.url {
                        self.outputDir = selectedURL.path
                        completion()
                    } else {
                        self.appendLog("Directory access not granted.")
                    }
                } else {
                    self.appendLog("Directory access not granted.")
                }
            }
        }
    }
    
    private func openApp(at path: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let workspace = NSWorkspace.shared
            let appURL = URL(fileURLWithPath: path)
            let configuration = NSWorkspace.OpenConfiguration()
            
            workspace.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error = error {
                    self.appendLog("Failed to launch app: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                
                guard let app = app else {
                    self.appendLog("Failed to obtain app reference.")
                    completion(false)
                    return
                }
                
                let pid = app.processIdentifier
                sleep(10)
                if self.isProcessRunning(pid: pid) {
                    // Wait for the app to terminate
                    var attempts = 0
                    while self.isProcessRunning(pid: pid) && attempts < 10 {
                        self.terminateProcess(pid: pid, sigk: false)
                        sleep(1)
                        attempts += 1
                    }
                    
                    attempts = 0
                    while self.isProcessRunning(pid: pid) && attempts < 10 {
                        self.terminateProcess(pid: pid, sigk: true)
                        sleep(1)
                        attempts += 1
                    }
                    
                    sleep(2)
                    completion(!self.isProcessRunning(pid: pid))
                } else {
                    completion(false)
                }
            }
        }
    }
    
    private func isProcessRunning(pid: pid_t) -> Bool {
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-p", "\(pid)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.launch()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.contains("\(pid)")
    }
    
    private func terminateProcess(pid: pid_t, sigk: Bool) {
        kill(pid, sigk ? SIGKILL : SIGTERM)
    }
}
