//
//  LanguageCleaner.swift
//  archify
//
//  Created by oct4pie on 6/24/24.
//

import AppKit
import Combine
import Foundation

/// The localizations found in one app, grouped by language.
struct AppLanguage: Identifiable {
    let id = UUID()
    let appName: String
    let appPath: String
    /// Language key → the app's folders for that language.
    var languagePaths: [String: [String]]
    /// Folder path → bytes it occupies on disk.
    var folderSizes: [String: UInt64]
    /// Language keys the app or the user needs; never removed.
    var protectedLanguages: Set<String>

    var languages: [String] { languagePaths.keys.sorted() }

    func size(of language: String) -> UInt64 {
        (languagePaths[language] ?? []).reduce(0) { $0 + (folderSizes[$1] ?? 0) }
    }
}

/// One language across every scanned app, as shown in the list.
struct LanguageSummary: Identifiable {
    let key: String
    let displayName: String
    /// Apps that would lose this language if it were selected.
    let removableAppCount: Int
    let removableSize: UInt64
    var id: String { key }
}

final class LanguageCleaner: ObservableObject {
    private struct RemovalItem {
        let appID: UUID
        let appPath: String
        let language: String
        let path: String
        let size: UInt64
    }

    @Published private(set) var apps: [AppLanguage] = []
    /// Languages the user chose to remove.
    @Published var selectedLanguages: Set<String> = []
    /// Apps the user chose to leave unchanged.
    @Published var excludedApps: Set<UUID> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var progress = 0.0
    @Published private(set) var removedFilesLog = ""
    @Published private(set) var currentlyScanningApp = ""
    @Published private(set) var currentlyRemovingFile = ""
    @Published private(set) var removalFailures: [(path: String, reason: String)] = []
    /// Result of the latest removal, shown until the next one starts.
    @Published private(set) var lastRemoval: (folders: Int, bytes: UInt64)?
    /// Folders a canceled removal did not start; still selected.
    @Published private(set) var notStartedCount = 0
    /// The latest scan was canceled, so results cover only part of the apps.
    @Published private(set) var scanWasStopped = false
    @Published private(set) var isQuittingApps = false
    /// Pause/Resume and Cancel for scanning and removal.
    let control = RunControl()

    private let fileManager = FileManager.default
    private let applicationDiscovery = ApplicationDiscovery()
    private let languageDiscovery = LanguageResourceDiscovery()
    private let preferredLanguageCodes = LanguageProtection.preferredLanguageCodes()

    // MARK: - What the screen shows

    /// Removable languages, largest savings first.
    var languageSummaries: [LanguageSummary] {
        var appCounts: [String: Int] = [:]
        var sizes: [String: UInt64] = [:]
        for app in apps {
            for language in app.languages where !isProtected(language, in: app) {
                appCounts[language, default: 0] += 1
                sizes[language, default: 0] += app.size(of: language)
            }
        }
        return appCounts.keys
            .map {
                LanguageSummary(
                    key: $0,
                    displayName: LanguageProtection.displayName(forKey: $0),
                    removableAppCount: appCounts[$0] ?? 0,
                    removableSize: sizes[$0] ?? 0
                )
            }
            .sorted {
                $0.removableSize == $1.removableSize
                    ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    : $0.removableSize > $1.removableSize
            }
    }

    /// The user's own languages, which are kept in every app.
    var keptLanguageNames: [String] {
        let keys = Set(apps.flatMap(\.languages)).filter(isUserLanguage)
        var seen = Set<String>()
        return keys
            .map { LanguageProtection.displayName(forKey: LanguageProtection.languageCode($0)) }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    var totalRemovableSize: UInt64 {
        languageSummaries.reduce(0) { $0 + $1.removableSize }
    }

    /// Apps that would change with the current language selection.
    var affectedApps: [AppLanguage] {
        apps.filter { removableSize(in: $0, ignoringExclusion: true) > 0 }
    }

    func removableSize(in app: AppLanguage, ignoringExclusion: Bool = false) -> UInt64 {
        guard ignoringExclusion || !excludedApps.contains(app.id) else { return 0 }
        return app.languages
            .filter { selectedLanguages.contains($0) && !isProtected($0, in: app) }
            .reduce(0) { $0 + app.size(of: $1) }
    }

    var selectedSize: UInt64 {
        apps.reduce(0) { $0 + removableSize(in: $1) }
    }

    var selectedAppCount: Int {
        apps.filter { removableSize(in: $0) > 0 }.count
    }

    var selectedFolderCount: Int { selectedRemovalItems().count }

    func isProtected(_ language: String, in app: AppLanguage) -> Bool {
        isUserLanguage(language) || app.protectedLanguages.contains(language)
    }

    /// Base and the user's preferred languages are kept in every app.
    private func isUserLanguage(_ language: String) -> Bool {
        language.caseInsensitiveCompare("Base") == .orderedSame
            || preferredLanguageCodes.contains(LanguageProtection.languageCode(language))
    }

    // MARK: - Selection

    func toggleLanguage(_ key: String) {
        if selectedLanguages.contains(key) {
            selectedLanguages.remove(key)
        } else {
            selectedLanguages.insert(key)
        }
    }

    func selectAllLanguages() {
        selectedLanguages = Set(languageSummaries.map(\.key))
    }

    func clearLanguages() {
        selectedLanguages.removeAll()
    }

    func includeAllApps() {
        excludedApps.removeAll()
    }

    func excludeAllApps() {
        excludedApps = Set(affectedApps.map(\.id))
    }

    func toggleApp(_ id: UUID) {
        if excludedApps.contains(id) {
            excludedApps.remove(id)
        } else {
            excludedApps.insert(id)
        }
    }

    // MARK: - Open apps

    /// Apps with selected languages that are open right now.
    func runningAffectedApps() -> [NSRunningApplication] {
        RunningApplications.running(in: selectedAppPaths)
    }

    /// Asks the open apps to quit, then removes. Apps that stay open (for
    /// example with unsaved work) are skipped, not changed.
    func quitAppsThenRemove(_ runningApps: [NSRunningApplication]) {
        isQuittingApps = true
        RunningApplications.quit(runningApps) { [weak self] in
            self?.isQuittingApps = false
            self?.removeSelected()
        }
    }

    func removeSkippingOpenApps() {
        let open = RunningApplications.runningAppPaths(in: selectedAppPaths)
        excludedApps.formUnion(apps.filter { open.contains($0.appPath) }.map(\.id))
        removeSelected()
    }

    /// How many affected apps are open, counting each app once.
    var openAffectedAppCount: Int {
        RunningApplications.runningAppPaths(in: selectedAppPaths).count
    }

    private var selectedAppPaths: [String] {
        apps.filter { removableSize(in: $0) > 0 }.map(\.appPath)
    }

    // MARK: - Scanning

    func scanForAppsAndLanguages() {
        guard !isScanning, !isRemoving else { return }
        isScanning = true
        scanWasStopped = false
        control.begin()
        progress = 0
        currentlyScanningApp = ""
        selectedLanguages.removeAll()
        excludedApps.removeAll()
        lastRemoval = nil
        removalFailures = []

        DispatchQueue.global(qos: .userInitiated).async {
            let excludedNames = defaultMacOSApps()
            let appPaths = self.applicationDiscovery
                .discoverApplicationPaths(in: ApplicationDiscovery.defaultRoots())
                .filter { !excludedNames.contains(URL(fileURLWithPath: $0).lastPathComponent) }
            let totalCount = appPaths.count
            var scannedApps: [AppLanguage] = []
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = max(
                1,
                min(4, ProcessInfo.processInfo.activeProcessorCount)
            )
            let lock = NSLock()
            var completedCount = 0

            for appPath in appPaths {
                queue.addOperation {
                    // Pausing waits here; canceling skips the apps not yet
                    // scanned and keeps the results so far.
                    guard self.control.checkpoint() else { return }
                    let appName = URL(fileURLWithPath: appPath).lastPathComponent
                    let app = self.scanApp(appPath)

                    lock.lock()
                    if let app {
                        scannedApps.append(app)
                    }
                    completedCount += 1
                    let completed = completedCount
                    lock.unlock()

                    DispatchQueue.main.async {
                        self.currentlyScanningApp = appName
                        self.progress = totalCount == 0
                            ? 1
                            : Double(completed) / Double(totalCount)
                    }
                }
            }

            queue.waitUntilAllOperationsAreFinished()
            scannedApps.sort {
                $0.appName == $1.appName
                    ? $0.appPath < $1.appPath
                    : $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.apps = scannedApps
                self.scanWasStopped = self.control.isCanceled
                self.control.finish()
                self.isScanning = false
                self.progress = 1
                self.currentlyScanningApp = ""
            }
        }
    }

    private func scanApp(_ appPath: String) -> AppLanguage? {
        let folders = languageDiscovery.languageResources(inApplication: appPath)
        guard !folders.isEmpty else { return nil }

        var languagePaths: [String: [String]] = [:]
        var folderSizes: [String: UInt64] = [:]
        for (folderName, paths) in folders {
            let key = LanguageProtection.languageKey(folderName)
            languagePaths[key, default: []].append(contentsOf: paths)
            for path in paths {
                folderSizes[path] = allocatedSize(ofDirectory: path)
            }
        }

        let languages = Array(languagePaths.keys)
        return AppLanguage(
            appName: URL(fileURLWithPath: appPath).lastPathComponent,
            appPath: appPath,
            languagePaths: languagePaths.mapValues { $0.sorted() },
            folderSizes: folderSizes,
            protectedLanguages: LanguageProtection.protectedLanguages(
                languages,
                developmentLanguageCode: LanguageProtection
                    .developmentLanguageCode(inApplication: appPath),
                preferredLanguageCodes: preferredLanguageCodes
            )
        )
    }

    /// Disk space a folder occupies, which is what removing it frees.
    private func allocatedSize(ofDirectory path: String) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else {
                continue
            }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Removal

    func removeSelected() {
        let removalItems = selectedRemovalItems()
        guard !removalItems.isEmpty, !isRemoving else { return }

        // Apps under /Applications go through Archify Helper. If it still
        // needs setting up, show how and resume this removal afterwards.
        let needsPrivilegedHelper = removalItems.contains {
            applicationDiscovery.isWithinRoot($0.path, rootPath: "/Applications")
        }
        if needsPrivilegedHelper,
           !HelperAccess.shared.ensureReady(retry: { [weak self] in
               self?.removeSelected()
           }) {
            return
        }

        isRemoving = true
        progress = 0
        removedFilesLog = ""
        removalFailures = []
        lastRemoval = nil
        notStartedCount = 0
        control.begin()
        removeNext(removalItems, index: 0, removedFiles: [], freedBytes: 0)
    }

    private func selectedRemovalItems() -> [RemovalItem] {
        var items: [RemovalItem] = []
        for app in apps where !excludedApps.contains(app.id) {
            for language in app.languages
            where selectedLanguages.contains(language) && !isProtected(language, in: app) {
                for path in app.languagePaths[language] ?? [] {
                    items.append(
                        RemovalItem(
                            appID: app.id,
                            appPath: app.appPath,
                            language: language,
                            path: path,
                            size: app.folderSizes[path] ?? 0
                        )
                    )
                }
            }
        }
        return items.sorted {
            $0.appPath == $1.appPath ? $0.path < $1.path : $0.appPath < $1.appPath
        }
    }

    private func removeNext(
        _ items: [RemovalItem],
        index: Int,
        removedFiles: [String],
        freedBytes: UInt64
    ) {
        guard index < items.count else {
            finishRemoval(removedFiles: removedFiles, freedBytes: freedBytes)
            return
        }

        // Pause holds the removal here; Cancel ends it before this folder.
        control.proceed({
            self.removeItem(
                at: index,
                of: items,
                removedFiles: removedFiles,
                freedBytes: freedBytes
            )
        }, orStop: {
            self.notStartedCount = items.count - index
            self.removedFilesLog += "Canceled. \(items.count - index) folders were not started and are unchanged.\n"
            self.finishRemoval(removedFiles: removedFiles, freedBytes: freedBytes)
        })
    }

    private func removeItem(
        at index: Int,
        of items: [RemovalItem],
        removedFiles: [String],
        freedBytes: UInt64
    ) {
        let item = items[index]
        currentlyRemovingFile = "\(LanguageProtection.displayName(forKey: item.language)) · "
            + URL(fileURLWithPath: item.appPath).deletingPathExtension().lastPathComponent

        // An app may have been opened since the removal started; never
        // change an app while it runs.
        let remove: (@escaping (Bool, String?) -> Void) -> Void = { completion in
            if RunningApplications.isRunning(item.appPath) {
                completion(false, RunningApplications.skippedWhileRunningMessage)
            } else {
                self.removeResource(item, completion: completion)
            }
        }

        remove { success, errorString in
            DispatchQueue.main.async {
                var removedFiles = removedFiles
                var freedBytes = freedBytes
                if success {
                    self.applySuccessfulRemoval(item)
                    removedFiles.append(item.path)
                    freedBytes += item.size
                } else {
                    let reason = errorString ?? "unknown error"
                    self.removalFailures.append((item.path, reason))
                    self.removedFilesLog += "Failed: \(item.path) — \(reason)\n"
                }

                // Canceling the administrator prompt cancels the removal
                // rather than asking again for every remaining folder.
                if errorString == HelperToolManager.authorizationCanceledMessage {
                    self.control.cancel()
                }
                self.progress = Double(index + 1) / Double(items.count)
                self.removeNext(
                    items,
                    index: index + 1,
                    removedFiles: removedFiles,
                    freedBytes: freedBytes
                )
            }
        }
    }

    private func removeResource(
        _ item: RemovalItem,
        completion: @escaping (Bool, String?) -> Void
    ) {
        if applicationDiscovery.isWithinRoot(item.path, rootPath: "/Applications") {
            HelperToolManager.shared.interactWithHelperTool(
                command: .removeLanguageResource(path: item.path),
                completion: completion
            )
            return
        }

        let userApplicationsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        guard applicationDiscovery.isWithinRoot(item.appPath, rootPath: userApplicationsRoot),
              let validatedPath = languageDiscovery.validatedLanguageResourcePath(
                item.path,
                inApplication: item.appPath
              )
        else {
            completion(false, "Language resource is outside a supported application bundle.")
            return
        }

        do {
            try fileManager.removeItem(atPath: validatedPath)
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }

    private func applySuccessfulRemoval(_ item: RemovalItem) {
        guard let appIndex = apps.firstIndex(where: { $0.id == item.appID }) else {
            return
        }
        apps[appIndex].languagePaths[item.language]?.removeAll { $0 == item.path }
        apps[appIndex].folderSizes.removeValue(forKey: item.path)
        if apps[appIndex].languagePaths[item.language]?.isEmpty == true {
            apps[appIndex].languagePaths.removeValue(forKey: item.language)
        }
        if apps[appIndex].languagePaths.isEmpty {
            apps.remove(at: appIndex)
        }
    }

    private func finishRemoval(removedFiles: [String], freedBytes: UInt64) {
        // Keep the selection only for languages that still have folders,
        // so retrying removes exactly what failed.
        selectedLanguages.formIntersection(Set(apps.flatMap(\.languages)))
        isRemoving = false
        control.finish()
        progress = 1
        currentlyRemovingFile = ""
        lastRemoval = (removedFiles.count, freedBytes)
        if !removedFiles.isEmpty {
            let successfulLog = removedFiles.joined(separator: "\n")
            removedFilesLog = removedFilesLog.isEmpty
                ? successfulLog
                : successfulLog + "\n" + removedFilesLog
        }

        if removalFailures.contains(where: {
            HelperToolManager.isProtectedAppRefusal($0.reason)
        }) {
            HelperAccess.shared.present(.fullDiskAccessNeeded) { [weak self] in
                self?.removeSelected()
            }
        }
    }
}
