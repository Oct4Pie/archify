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
    @Published var failedApps: [(path: String, reason: String)] = []
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
    /// Selected apps a canceled run did not start; left unchanged.
    @Published private(set) var notStartedApps: [String] = []
    /// The latest scan was canceled, so results cover only part of the apps.
    @Published private(set) var scanWasStopped = false
    @Published private(set) var isQuittingApps = false
    /// Pause/Resume and Cancel for the scan and for optimization runs.
    let control = RunControl()
    
    private let universalApps = UniversalApps()
    private let applicationDiscovery = ApplicationDiscovery()
    private let localApplicationThinner = ApplicationThinner()
    private var scanStartTime: Date?
    private var processStartTime: Date?
    
    func startCalculatingSizes() {
        guard !isScanning, !isProcessing else { return }
        isScanning = true
        scanWasStopped = false
        control.begin()
        appSizes = []
        scanningProgress = 0.0
        currentApp = ""
        scanStartTime = Date()
        
        DispatchQueue.global(qos: .userInitiated).async {
            let systemArch = self.systemArchitecture()
            self.universalApps.produceSortedAppSizes(
                systemArch: systemArch,
                control: self.control,
                progressHandler: { app, processed, total in
                    DispatchQueue.main.async {
                        self.currentApp = URL(fileURLWithPath: app).lastPathComponent
                        self.scanningProgress = total == 0
                            ? 1
                            : Double(processed) / Double(total)
                    }
                }
            ) { sortedAppSizes in
                DispatchQueue.main.async {
                    self.appSizes = sortedAppSizes.map {
                        ($0.path, $0.totalSize, $0.savableSize)
                    }
                    self.scanWasStopped = self.control.isCanceled
                    self.control.finish()
                    self.isScanning = false
                    self.scanningProgress = 1
                    self.currentApp = ""
                    self.scanStartTime = nil
                }
            }
        }
    }
    
    func startProcessingSelectedApps(completion: (() -> Void)? = nil) {
        guard !selectedApps.isEmpty, !isProcessing else { return }
        let appsToProcess = appSizes.map(\.0).filter { selectedApps.contains($0) }
        guard !appsToProcess.isEmpty else { return }
        let targetArchitecture = systemArchitecture()

        // Apps under /Applications go through Archify Helper. If it still
        // needs setting up, show how and resume this run afterwards.
        if appsToProcess.contains(where: { isSystemApplication($0) }),
           !HelperAccess.shared.ensureReady(retry: { [weak self] in
               self?.startProcessingSelectedApps(completion: completion)
           }) {
            completion?()
            return
        }
        
        isProcessing = true
        processingProgress = 0.0
        logMessages = ""
        processedAppSizes = []
        failedApps = []
        notStartedApps = []
        totalSavedSpace = 0
        initialTotalSize = 0
        finalTotalSize = 0
        savedSpaces = [:]
        processStartTime = Date()
        control.begin()

        // Calculate initial total size and savable size
        for app in appsToProcess {
            if let appInfo = appSizes.first(where: { $0.0 == app }) {
                initialTotalSize += appInfo.1  // Total size
                finalTotalSize += appInfo.1    // Initialize final size as total size
            }
        }
        
        // System apps under /Applications go through the privileged helper.
        // User-owned apps under ~/Applications use the same thinning engine
        // directly and do not require root privileges.
        processApps(
            appsToProcess,
            targetArchitecture: targetArchitecture,
            index: 0,
            completion: completion
        )
    }
    
    private func processApps(
        _ apps: [String],
        targetArchitecture: String,
        index: Int,
        completion: (() -> Void)?
    ) {
        guard index < apps.count else {
            finishRun(completion: completion)
            return
        }

        // Pause holds the run here; Cancel ends it before this app. The app
        // in progress always finishes, so none is left half-changed.
        control.proceed({
            self.processApp(
                at: index,
                of: apps,
                targetArchitecture: targetArchitecture,
                completion: completion
            )
        }, orStop: {
            self.notStartedApps = Array(apps[index...])
            self.logMessages += "Canceled. \(apps.count - index) selected apps were not started and are unchanged.\n"
            self.finishRun(completion: completion)
        })
    }

    private func processApp(
        at index: Int,
        of apps: [String],
        targetArchitecture: String,
        completion: (() -> Void)?
    ) {
        let app = apps[index]
        currentApp = URL(fileURLWithPath: app).lastPathComponent

        let next = {
            self.processingProgress = Double(index + 1) / Double(apps.count)
            self.processApps(
                apps,
                targetArchitecture: targetArchitecture,
                index: index + 1,
                completion: completion
            )
        }

        guard let appInfo = appSizes.first(where: { $0.0 == app }) else {
            next()
            return
        }

        // An app may have been opened since the run started; never change
        // an app while it runs.
        guard !RunningApplications.isRunning(app) else {
            recordResult(
                app: app,
                success: false,
                errorString: RunningApplications.skippedWhileRunningMessage,
                originalSize: appInfo.1,
                newSize: 0,
                expectedSavableSize: appInfo.2
            )
            next()
            return
        }

        let originalSize = appInfo.1
        let expectedSavableSize = appInfo.2

        processApplication(app, targetArchitecture: targetArchitecture) { success, errorString in
            // Measure off the main thread; large bundles take a while to walk.
            DispatchQueue.global(qos: .userInitiated).async {
                let newSize = success
                    ? self.universalApps.calculateDirectorySize(path: app)
                    : 0
                DispatchQueue.main.async {
                    self.recordResult(
                        app: app,
                        success: success,
                        errorString: errorString,
                        originalSize: originalSize,
                        newSize: newSize,
                        expectedSavableSize: expectedSavableSize
                    )
                    // Canceling the administrator prompt cancels the run
                    // rather than asking again for every remaining app.
                    if errorString == HelperToolManager.authorizationCanceledMessage {
                        self.control.cancel()
                    }
                    next()
                }
            }
        }
    }

    private func finishRun(completion: (() -> Void)?) {
        isProcessing = false
        processStartTime = nil
        currentApp = ""
        control.finish()
        offerFullDiskAccessRetryIfNeeded()
        completion?()
    }

    // MARK: - Open apps

    /// Selected apps that are open right now.
    func runningSelectedApps() -> [NSRunningApplication] {
        RunningApplications.running(in: Array(selectedApps))
    }

    /// Asks the open apps to quit, then optimizes the selection. Apps that
    /// stay open (for example with unsaved work) are skipped, not changed.
    func quitAppsThenProcess(_ runningApps: [NSRunningApplication]) {
        isQuittingApps = true
        RunningApplications.quit(runningApps) { [weak self] in
            self?.isQuittingApps = false
            self?.startProcessingSelectedApps()
        }
    }

    func processSkippingOpenApps() {
        selectedApps.subtract(
            RunningApplications.runningAppPaths(in: Array(selectedApps))
        )
        startProcessingSelectedApps()
    }

    private func recordResult(
        app: String,
        success: Bool,
        errorString: String?,
        originalSize: UInt64,
        newSize: UInt64,
        expectedSavableSize: UInt64
    ) {
        if success {
            let actualSavedSpace = StorageUtilities.savedSpace(
                originalSize: originalSize,
                newSize: newSize
            )

            processedAppSizes.append((app, originalSize, actualSavedSpace))
            savedSpaces[app] = actualSavedSpace
            totalSavedSpace += actualSavedSpace
            finalTotalSize -= actualSavedSpace
            logMessages += "Processed \(app) successfully. Saved \(actualSavedSpace.humanReadableSize()) (Expected: \(expectedSavableSize.humanReadableSize()))\n"

            if let appIndex = appSizes.firstIndex(where: { $0.0 == app }) {
                appSizes.remove(at: appIndex)
            }
            selectedApps.remove(app)
        } else {
            let reason = errorString ?? "Unknown error"
            failedApps.append((app, reason))
            logMessages += "Failed to process \(app): \(reason)\n"
        }
    }

    /// If macOS app protection refused any app, explain how to allow it and
    /// offer to retry just those apps.
    private func offerFullDiskAccessRetryIfNeeded() {
        let refusedApps = failedApps
            .filter { HelperToolManager.isProtectedAppRefusal($0.reason) }
            .map(\.path)
        guard !refusedApps.isEmpty else { return }

        HelperAccess.shared.present(.fullDiskAccessNeeded) { [weak self] in
            guard let self else { return }
            self.selectedApps = Set(refusedApps).intersection(
                self.appSizes.map(\.0)
            )
            self.startProcessingSelectedApps()
        }
    }

    private func processApplication(
        _ app: String,
        targetArchitecture: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        if isSystemApplication(app) {
            HelperToolManager.shared.interactWithHelperTool(
                command: .thinApplication(
                    path: app,
                    targetArchitecture: targetArchitecture
                ),
                completion: completion
            )
            return
        }

        let userApplicationsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        guard applicationDiscovery.isWithinRoot(app, rootPath: userApplicationsRoot) else {
            completion(false, "Application is outside Archify's supported application folders.")
            return
        }

        localApplicationThinner.thinApplication(
            atPath: app,
            targetArchitecture: targetArchitecture,
            completion: completion
        )
    }

    private func isSystemApplication(_ path: String) -> Bool {
        applicationDiscovery.isWithinRoot(path, rootPath: "/Applications")
    }
    
    func selectAllApps() {
        selectedApps = Set(appSizes.map { $0.0 })
    }
    
    func deselectAllApps() {
        selectedApps.removeAll()
    }
    
    private func systemArchitecture() -> String {
        ProcessInfo.processInfo.machineArchitecture
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

/// Finds apps that are open. Changing an app while it runs can make it
/// misbehave until it is reopened, so Archify offers to quit it first and
/// never changes an app that is still running.
enum RunningApplications {
    /// Running apps whose bundle is, or is inside, one of `appPaths`.
    static func running(in appPaths: [String]) -> [NSRunningApplication] {
        let roots = appPaths.map(canonicalPath)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, app.processIdentifier != ownPID else {
                return false
            }
            let paths = [app.bundleURL, app.executableURL]
                .compactMap { $0 }
                .map { canonicalPath($0.path) }
            return paths.contains { path in
                roots.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
        }
    }

    /// The paths in `appPaths` that have something running from them.
    static func runningAppPaths(in appPaths: [String]) -> Set<String> {
        Set(appPaths.filter { !running(in: [$0]).isEmpty })
    }

    static func isRunning(_ appPath: String) -> Bool {
        !running(in: [appPath]).isEmpty
    }

    /// Names as they appear in /Applications, so two copies of one app
    /// (both called "Keka" in the Dock, say) can be told apart.
    static func names(of apps: [NSRunningApplication]) -> [String] {
        var seen = Set<String>()
        return apps
            .compactMap { $0.bundleURL?.deletingPathExtension().lastPathComponent ?? $0.localizedName }
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Asks each app to quit, as the Quit menu item would; never forces it,
    /// so apps with unsaved work can still ask the user. Calls `completion`
    /// on the main thread once they have quit or `timeout` has passed.
    static func quit(
        _ apps: [NSRunningApplication],
        timeout: TimeInterval = 20,
        completion: @escaping () -> Void
    ) {
        apps.forEach { $0.terminate() }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    static let skippedWhileRunningMessage =
        "Skipped because the app is open. Quit it and try again."

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
    }
}
