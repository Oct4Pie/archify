import Combine
import Foundation
import AppKit

class BatchProcessing: ObservableObject {
    @Published var appSizes: [(String, UInt64)] = []
    @Published var progress: Double = 0.0
    @Published var currentApp: String = ""
    @Published var selectedApps: Set<String> = []
    @Published var isProcessing: Bool = false
    @Published var totalSavedSpace: UInt64 = 0
    @Published var logMessages: String = ""

    private let appState = AppState()

    func startCalculatingSizes() {
        isProcessing = true
        appSizes = []
        progress = 0.0
        currentApp = ""

        DispatchQueue.global(qos: .background).async {
            let universalApps = UniversalApps()
            let systemArch = self.systemArchitecture()
            universalApps.produceSortedList(systemArch: systemArch, progressHandler: { app, processed, total in
                DispatchQueue.main.async {
                    self.currentApp = URL(fileURLWithPath: app).lastPathComponent
                    self.progress = Double(processed) / Double(total)
                }
            }) { sortedAppSizes in
                DispatchQueue.main.async {
                    self.appSizes = sortedAppSizes
                    self.isProcessing = false
                }
            }
        }
    }

    func startProcessingSelectedApps() {
        isProcessing = true
        appState.isProcessing = true
        appState.logMessages = ""
        totalSavedSpace = 0

        guard HelperToolManager.shared.blessHelperTool() else {
            print("Failed to install helper tool.")
            return
        }

        HelperToolManager.shared.interactWithHelperTool(command: .checkFullDiskAccess) { [weak self] hasAccess, error in
            guard let self = self else { return }
            if hasAccess {
                self.processSelectedApps()
            } else {
                self.promptForFullDiskAccess()
                self.isProcessing = false
                self.appState.isProcessing = false
            }
        }
    }

    private func processSelectedApps() {
        DispatchQueue.global(qos: .background).async {
            let appStateDict = self.appState.toDictionary()
            let group = DispatchGroup()

            for app in self.selectedApps {
                group.enter()
                HelperToolManager.shared.interactWithHelperTool(command: .extractAndSignBinaries(dir: app, targetArch: self.systemArchitecture(), noSign: true, noEntitlements: true, appStateDict: appStateDict)) { success, errorString in
                    if success {
                        DispatchQueue.main.async {
                            if let index = self.appSizes.firstIndex(where: { $0.0 == app }) {
                                self.totalSavedSpace += self.appSizes[index].1
                                self.appSizes.remove(at: index)
                                self.selectedApps.remove(app)
                            }
                        }
                        print("Processed \(app) successfully")
                    } else {
                        print("Failed to process \(app): \(errorString ?? "Unknown error")")
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.isProcessing = false
                self.appState.isProcessing = false
            }
        }
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
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = """
            This application requires Full Disk Access to function properly.
            Please go to System Preferences > Security & Privacy > Privacy > Full Disk Access
            and check "com.oct4pie" in the list.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
