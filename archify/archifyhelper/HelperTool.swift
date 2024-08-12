//
//  HelperTool.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation

class HelperTool: NSObject, NSXPCListenerDelegate, HelperToolProtocol {
    static let version = Version.current

    func duplicateApp(appDir: String, outputDir: String, withReply reply: @escaping (String?, String?) -> Void) {
        // Implementation for duplicateApp if needed
    }
    
    private let listener: NSXPCListener

    override init() {
        self.listener = NSXPCListener(machServiceName: "com.oct4pie.archifyhelper")
        super.init()
        self.listener.delegate = self
    }

    func run() {
        NSLog("Helper tool started.")
        self.listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        NSLog("New connection accepted.")
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func removeFile(atPath path: String, withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to remove file at path: \(path)")
        do {
            try FileManager.default.removeItem(atPath: path)
            reply(true, nil)
            NSLog("File removed successfully at path: \(path)")
        } catch {
            reply(false, error.localizedDescription)
            NSLog("Failed to remove file at path \(path): \(error.localizedDescription)")
        }
    }

    func extractAndSignBinaries(in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, appStateDict: [String: Any], withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to extract and sign binaries in directory \(dir)")
        let appState = AppState.fromDictionary(appStateDict)
        let fileOperations = FileOperations(appState: appState)
        fileOperations.extractAndSignBinaries(in: dir, targetArch: targetArch, noSign: noSign, noEntitlements: noEntitlements) { success, error in
            if success {
                reply(true, nil)
                NSLog("Successfully extracted and signed binaries in directory \(dir)")
            } else {
                reply(false, error)
                NSLog("Failed to extract and sign binaries in directory \(dir): \(error ?? "Unknown error")")
            }
        }
    }

    func setFilePermissions(atPath path: String, permissions: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to set file permissions at path: \(path)")
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            reply(true, nil)
            NSLog("File permissions set successfully at path: \(path)")
        } catch {
            reply(false, error.localizedDescription)
            NSLog("Failed to set file permissions at path \(path): \(error.localizedDescription)")
        }
    }
    
    func checkFullDiskAccess(withReply reply: @escaping (Bool) -> Void) {
        NSLog("Checking for full disk access.")
        
        let paths = [
            "~/Library/Safari/Bookmarks.plist",
            "~/Library/Safari/CloudTabs.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist"
        ]
        
        var hasAccess = true
        
        for path in paths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expandedPath) {
                if !FileManager.default.isReadableFile(atPath: expandedPath) {
                    hasAccess = false
                    NSLog("Cannot read file at path: \(expandedPath)")
                    break
                }
            } else {
                NSLog("File does not exist at path: \(expandedPath)")
                hasAccess = false
                break
            }
        }
        
        reply(hasAccess)
        
        if hasAccess {
            NSLog("Full disk access granted.")
        } else {
            NSLog("Full disk access not granted.")
        }
    }
}
