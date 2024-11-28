//
//  LanguageCleaner.swift
//  archify
//
//  Created by oct4pie on 6/24/24.
//

import Foundation
import Combine

struct AppLanguage: Identifiable {
    let id = UUID()
    let appName: String
    var languages: [String]
    var languagePaths: [String: [String]] // Maps language names to a list of their full paths
    var selectedLanguages: Set<String> = []
}

class LanguageCleaner: ObservableObject {
    @Published var apps: [AppLanguage] = []
    @Published var uniqueLanguages: [String] = []
    @Published var selectedApps: Set<UUID> = []
    @Published var selectedLanguages: Set<String> = []
    @Published var expandedApps: [UUID: Bool] = [:]
    @Published var isScanning: Bool = false
    @Published var isRemoving: Bool = false
    @Published var progress: Double = 0.0
    @Published var searchText: String = ""
    @Published var removedFilesLog: String = ""
    @Published var currentlyScanningApp: String = ""
    @Published var currentlyRemovingFile: String = ""
    
    var filteredApps: [AppLanguage] {
        if searchText.isEmpty {
            return apps
        } else {
            return apps.filter { $0.appName.lowercased().contains(searchText.lowercased()) }
        }
    }
    
    var isAllLanguagesSelected: Bool {
        let selectableLanguages = uniqueLanguages.filter { !shouldGrayOutLanguage($0) }
        return selectedLanguages.count == selectableLanguages.count
    }
    
    var isRemoveButtonEnabled: Bool {
        return !selectedLanguages.isEmpty || apps.contains(where: { !$0.selectedLanguages.isEmpty })
    }
    
    func isAllLanguagesSelected(in app: AppLanguage) -> Bool {
        let selectableLanguages = app.languages.filter { !shouldGrayOutLanguage($0) }
        return app.selectedLanguages.count == selectableLanguages.count
    }
    
    func isLanguageSelectedInApp(_ language: String, app: AppLanguage) -> Bool {
        return app.selectedLanguages.contains(language) || selectedLanguages.contains(language)
    }
    
    func shouldGrayOutLanguage(_ language: String) -> Bool {
        return language == "Base"
    }
    
    func getApplicationFolderCount() -> Int {
        let fileManager = FileManager.default
        let applicationPath = "/Applications"
        
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: applicationPath)
            let folderCount = contents.filter { item in
                var isDir: ObjCBool = false
                let fullPath = (applicationPath as NSString).appendingPathComponent(item)
                return fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
            }.count
            return folderCount
        } catch {
            print("Failed to get contents of /Applications: \(error.localizedDescription)")
            return 0
        }
    }
    
    func scanForAppsAndLanguages() {
        isScanning = true
        progress = 0.0
        let applicationPath = "/Applications"
        let defaultMacOSApps = defaultMacOSApps()
        var tempApps: [AppLanguage] = []
        var allLanguages: Set<String> = []
        var appLanguages: [String: [String: [String]]] = [:]
        let totalCount = getApplicationFolderCount()
        var processedCount = 0
        
        DispatchQueue.global(qos: .background).async {
            do {
                let localFileManager = FileManager.default
                let contents = try localFileManager.contentsOfDirectory(atPath: applicationPath)
                for item in contents {
                    let fullPath = (applicationPath as NSString).appendingPathComponent(item)
                    var isDir: ObjCBool = false
                    if localFileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        processedCount += 1
                        let appName = item
                        // Skip the app if it's in the default MacOS apps set
                        if defaultMacOSApps.contains(appName) {
                            continue
                        }
                        DispatchQueue.main.async {
                            self.currentlyScanningApp = "Scanning \(appName)"
                        }
                        if appLanguages[appName] == nil {
                            appLanguages[appName] = [:]
                        }
                        if let enumerator = localFileManager.enumerator(atPath: fullPath) {
                            for case let path as String in enumerator {
                                if path.hasSuffix(".lproj") {
                                    let language = (path as NSString).lastPathComponent.replacingOccurrences(of: ".lproj", with: "")
                                    if appLanguages[appName]?[language] == nil {
                                        appLanguages[appName]?[language] = []
                                    }
                                    appLanguages[appName]?[language]?.append((fullPath as NSString).appendingPathComponent(path))
                                    allLanguages.insert(language)
                                }
                            }
                        }
                        DispatchQueue.main.async {
                            self.progress = Double(processedCount) / Double(totalCount)
                        }
                    }
                }
            } catch {
                print("Failed to scan /Applications: \(error.localizedDescription)")
            }
            
            for (appName, languages) in appLanguages {
                tempApps.append(AppLanguage(appName: appName, languages: Array(languages.keys).sorted(), languagePaths: languages.mapValues { $0 }))
            }
            
            DispatchQueue.main.async {
                self.apps = tempApps
                self.uniqueLanguages = Array(allLanguages).sorted()
                self.expandedApps = Dictionary(uniqueKeysWithValues: tempApps.map { ($0.id, false) })
                self.isScanning = false
                self.progress = 1.0
                self.currentlyScanningApp = ""
            }
        }
    }
    
    func removeSelected() {
        var pathsToRemove: [(appIndex: Int, language: String, path: String)] = []
        var removedFiles: [String] = []
        
        for (appIndex, app) in apps.enumerated() {
            for language in app.languages {
                if app.selectedLanguages.contains(language) || selectedLanguages.contains(language) {
                    if let paths = app.languagePaths[language] {
                        pathsToRemove.append(contentsOf: paths.map { (appIndex, language, $0) })
                    }
                }
            }
        }
        
        guard HelperToolManager.shared.isHelperToolInstalled() || HelperToolManager.shared.blessHelperTool() else {
            print("Failed to install helper tool.")
            return
        }
        
        let totalCount = pathsToRemove.count
        var removedCount = 0
        
        isRemoving = true
        progress = 0.0
        
        DispatchQueue.global(qos: .background).async {
            let group = DispatchGroup()
            
            for (appIndex, language, path) in pathsToRemove {
                group.enter()
                DispatchQueue.main.async {
                    self.currentlyRemovingFile = "Removing \(path)"
                }
                HelperToolManager.shared.interactWithHelperTool(command: .removeFile(path: path)) { success, errorString in
                    if success {
                        DispatchQueue.main.async {
                            self.apps[appIndex].languagePaths[language]?.removeAll(where: { $0 == path })
                            if self.apps[appIndex].languagePaths[language]?.isEmpty == true {
                                self.apps[appIndex].languagePaths.removeValue(forKey: language)
                                self.apps[appIndex].languages.removeAll(where: { $0 == language })
                                self.uniqueLanguages.removeAll(where: { $0 == language })
                            }
                            removedFiles.append(path)
                            removedCount += 1
                            self.progress = Double(removedCount) / Double(totalCount)
                        }
                    } else {
                        print("Failed to remove: \(path)")
                        print("Helper tool error: \(errorString ?? "unknown error")")
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                self.isRemoving = false
                self.progress = 1.0
                self.removedFilesLog = removedFiles.joined(separator: "\n")
                self.currentlyRemovingFile = ""
            }
        }
    }
    
    func toggleApp(_ appId: UUID) {
        if selectedApps.contains(appId) {
            selectedApps.remove(appId)
        } else {
            selectedApps.insert(appId)
        }
    }
    
    func toggleLanguageInApp(_ language: String, app: AppLanguage) {
        if let appIndex = apps.firstIndex(where: { $0.id == app.id }) {
            if apps[appIndex].selectedLanguages.contains(language) {
                apps[appIndex].selectedLanguages.remove(language)
            } else {
                apps[appIndex].selectedLanguages.insert(language)
            }
            objectWillChange.send() // Notify the view about the change
        }
    }
    
    func toggleGlobalLanguage(_ language: String) {
        if shouldGrayOutLanguage(language) {
            return
        }
        if selectedLanguages.contains(language) {
            selectedLanguages.remove(language)
        } else {
            selectedLanguages.insert(language)
        }
        // Update app-specific selections
        for index in apps.indices {
            if selectedLanguages.contains(language) {
                apps[index].selectedLanguages.insert(language)
            } else {
                apps[index].selectedLanguages.remove(language)
            }
        }
    }
    
    func toggleSelectAllLanguages() {
        if isAllLanguagesSelected {
            selectedLanguages.removeAll()
        } else {
            selectedLanguages = Set(uniqueLanguages.filter { !shouldGrayOutLanguage($0) })
        }
        // Update app-specific selections
        for index in apps.indices {
            if isAllLanguagesSelected {
                apps[index].selectedLanguages = Set(apps[index].languages.filter { !shouldGrayOutLanguage($0) })
            } else {
                apps[index].selectedLanguages.removeAll()
            }
        }
    }
    
    func toggleSelectAllLanguages(in app: AppLanguage) {
        if let appIndex = apps.firstIndex(where: { $0.id == app.id }) {
            if isAllLanguagesSelected(in: apps[appIndex]) {
                apps[appIndex].selectedLanguages.removeAll()
            } else {
                apps[appIndex].selectedLanguages = Set(apps[appIndex].languages.filter { !shouldGrayOutLanguage($0) })
            }
            objectWillChange.send() // Notify the view about the change
        }
    }
}
