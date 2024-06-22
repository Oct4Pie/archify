import Foundation
import AppKit

class PermissionsManager {
    static let shared = PermissionsManager()

    private init() {}

    func hasFullDiskAccess() -> Bool {
        let testFilePath = "/Library/Application Support/test_file.txt"
        let fileManager = FileManager.default

        do {
            try "Test".write(toFile: testFilePath, atomically: true, encoding: .utf8)
            try fileManager.removeItem(atPath: testFilePath)
            return true
        } catch {
            return false
        }
    }

    func requestFullDiskAccess() {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = "This application needs Full Disk Access to modify files in the /Applications directory. Please grant Full Disk Access in System Preferences."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemPreferences()
        }
    }

    private func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
