//
//  HelperTool.swift
//  archifyhelper
//
//  Created by oct4pie on 6/19/24.
//

import Foundation
import Security
import Cocoa

enum FullDiskAccessError: Error {
    case pathAccessDenied(String)
    case unexpectedError(String)
    case userHomeNotFound
}


class HelperTool: NSObject, NSXPCListenerDelegate, HelperToolProtocol {
    static let version = Version.current
    private let listener: NSXPCListener
    private let fileManager = FileManager.default
    
    private let protectedPaths: [String] = [
        // TCC Database paths
        "/Library/Application Support/com.apple.TCC/TCC.db",
        "$HOME/Library/Application Support/com.apple.TCC/TCC.db",
        
        // System and Settings
        "/Library/Preferences/com.apple.TimeMachine.plist",
        "/Library/Preferences/com.apple.security.plist",
        
        // Require FDA
        "$HOME/Library/Mail",
        "$HOME/Library/Messages",
        "$HOME/Library/Calendars",
        "$HOME/Library/Reminders",
        "$HOME/Library/Safari/History.db",
        
        // More system paths
        "/Library/Application Support/com.apple.TCC",
        "/private/var/db/tcc"
    ]
    
    // Define allowed directories (whitelist approach)
    private let allowedDirectories: [String] = [
        "/Applications",
        // "/Users"
    ]
    
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
        guard validateClient(connection: newConnection) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }
    
    
    
    func validateClient(connection: NSXPCConnection) -> Bool {
        var codeRef: SecCode?
        var staticCodeRef: SecStaticCode?
        let pid = connection.processIdentifier
        var clientIdentifier: String?
        var clientTeamIdentifier: String?
        
        
        let auditToken = connection.auditToken
        
        guard auditToken.count == MemoryLayout<audit_token_t>.size else {
#if DEBUG
            NSLog("Invalid audit token size")
#endif
            return false
        }
        
        let auditTokenCFData = auditToken as CFData
        let attributes: [CFString: CFTypeRef] = [
            kSecGuestAttributeAudit: auditTokenCFData
        ]
        
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &codeRef)
        if status != errSecSuccess {
            if let errorMessage = SecCopyErrorMessageString(status, nil) {
#if DEBUG
                NSLog("SecCodeCopyGuestWithAttributes failed: \(errorMessage)")
#endif
            } else {
#if DEBUG
                NSLog("SecCodeCopyGuestWithAttributes failed with unknown error: \(status)")
#endif
            }
            return false
        }
        
        guard let validCodeRef = codeRef else {
#if DEBUG
            NSLog("SecCodeRef is nil after retrieval.")
#endif
            return false
        }
        
        
        let staticStatus = SecCodeCopyStaticCode(validCodeRef, SecCSFlags(), &staticCodeRef)
        if staticStatus != errSecSuccess || staticCodeRef == nil {
#if DEBUG
            NSLog("Failed to get SecStaticCode for client. Status: \(staticStatus)")
#endif
            return false
        }
        
        guard let validStaticCodeRef = staticCodeRef else {
#if DEBUG
            NSLog("SecStaticCode is nil after conversion.")
#endif
            return false
        }
        
        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(validStaticCodeRef,
                                                       SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
                                                       &signingInfo)
        
        if infoStatus == errSecSuccess,
           let info = signingInfo as? [String: Any],
           let identifier = info[kSecCodeInfoIdentifier as String] as? String {
            clientIdentifier = identifier
#if DEBUG
            NSLog("Client identifier retrieved: \(identifier)")
#endif
            
            if let teamIdentifiers = info[kSecCodeInfoTeamIdentifier as String] as? [String] {
                clientTeamIdentifier = teamIdentifiers.first
#if DEBUG
                NSLog("Team identifier: \(clientTeamIdentifier ?? "unknown")")
#endif
            }
            if let signingFlags = info[kSecCodeInfoFlags as String] as? UInt32 {
#if DEBUG
                NSLog("Signing flags: \(signingFlags)")
#endif
            }
            if let requirements = info[kSecCodeInfoRequirements as String] as? [String] {
#if DEBUG
                NSLog("Requirements: \(requirements)")
#endif
            }
        } else {
            let errorMessage = SecCopyErrorMessageString(infoStatus, nil) as String? ?? "Unknown error"
#if DEBUG
            NSLog("Failed to retrieve signing information. Status: \(infoStatus) - \(errorMessage)")
#endif
            return false
        }
        
        let requirementString = """
        anchor apple generic and \
        identifier "com.oct4pie.archify" and \
        certificate leaf[subject.OU] = "9827C97648" and \
        certificate leaf[subject.CN] = "Apple Distribution: Mehdi Hajmollaahmad Naraghi (9827C97648)"
        """
        
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
        if reqStatus != errSecSuccess || requirement == nil {
#if DEBUG
            NSLog("Failed to create SecRequirement. Status: \(reqStatus)")
#endif
            return false
        }
        
        guard let validRequirement = requirement else {
#if DEBUG
            NSLog("SecRequirement is nil after creation.")
#endif
            return false
        }
        
        let validityStatus = SecStaticCodeCheckValidity(validStaticCodeRef,
                                                        SecCSFlags(rawValue: kSecCSBasicValidateOnly),
                                                        validRequirement)
        
        if validityStatus != errSecSuccess {
            let errorMessage = SecCopyErrorMessageString(validityStatus, nil) as String? ?? "Unknown error"
#if DEBUG
            NSLog("SecStaticCodeCheckValidity failed. Status: \(validityStatus) - \(errorMessage)")
#endif
            if let identifier = clientIdentifier {
#if DEBUG
                NSLog("Validation failed for client identifier: \(identifier)")
#endif
            }
            return false
        }
        
        if let signingInfo = signingInfo as? [String: Any],
           let version = signingInfo["CFBundleShortVersionString"] as? String {
            if version.compare(Version.current, options: .numeric) == .orderedAscending {
#if DEBUG
                NSLog("Client version \(version) is outdated.")
#endif
                return false
            }
        }
        
#if DEBUG
        NSLog("Client validation succeeded for PID: \(pid), Identifier: \(clientIdentifier ?? "none")")
#endif
        return true
    }
    
    
    private func isPathAllowed(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        
        for allowedDir in allowedDirectories {
            let normalizedAllowedDir = URL(fileURLWithPath: allowedDir).standardized.path
            if normalizedPath.hasPrefix(normalizedAllowedDir) {
                return true
            }
        }
        return false
    }
    
    
    private func getCurrentUserHome() -> String? {
        if let homeDir = NSHomeDirectoryForUser(NSUserName()) {
            return homeDir
        }
        
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return home
        }
        
        NSLog("Failed to determine user home directory using native APIs.")
        return nil
    }
    
    private func pathExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    }
    
    
    private func verifyAccess(to path: String) -> Bool {
        let fileURL = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return true  // Path doesn't exist, so ignore it
        }
        
        do {
            if isDirectory.boolValue {
                _ = try fileManager.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil)
            } else {
                let attrs = try fileManager.attributesOfItem(atPath: path)
                _ = attrs[.size]
                
                if path.hasSuffix("TCC.db") || path.hasSuffix(".plist") {
                    _ = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                }
            }
            return true
        } catch {
            NSLog("Access verification failed for \(path): \(error.localizedDescription)")
            return false
        }
    }
    
    private func attemptToTriggerPrompt(userHome: String) {
        NSLog("Attempting to trigger FDA system prompt...")
        
        let triggerPaths = [
            "\(userHome)/Library/Mail",
            "\(userHome)/Library/Messages",
            "\(userHome)/Library/Safari/History.db"
        ]
        
        for path in triggerPaths {
            let url = URL(fileURLWithPath: path)
            
            do {
                _ = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                NSLog("Triggered FDA prompt using path: \(path)")
                break
            } catch {
                continue
            }
        }
    }
    
    
    func duplicateApp(appDir: String, outputDir: String, withReply reply: @escaping (String?, String?) -> Void) {
        reply(nil, "Not implemented.")
        NSLog("DuplicateApp method called but not implemented.")
    }
    
    func removeFile(atPath path: String, withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to remove file at path: \(path)")
        
        guard isPathAllowed(path) else {
            reply(false, "Operation not permitted on the specified path.")
            NSLog("Attempt to remove a protected or disallowed path: \(path)")
            return
        }
        
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        
        do {
            try FileManager.default.removeItem(atPath: normalizedPath)
            reply(true, nil)
            NSLog("File removed successfully at path: \(normalizedPath)")
        } catch {
            reply(false, "Failed to remove the specified file.")
            NSLog("Failed to remove file at path \(normalizedPath): \(error.localizedDescription)")
        }
    }
    
    func extractAndSignBinaries(in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, appStateDict: [String: Any], withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to extract and sign binaries in directory \(dir)")
        
        guard isPathAllowed(dir) else {
            reply(false, "Operation not permitted on the specified directory.")
            NSLog("Attempt to extract and sign binaries in a protected or disallowed directory: \(dir)")
            return
        }
        
        let normalizedDir = URL(fileURLWithPath: dir).standardized.path
        
        let appState = AppState.fromDictionary(appStateDict)
        let fileOperations = FileOperations(appState: appState)
        fileOperations.extractAndSignBinaries(in: normalizedDir, targetArch: targetArch, noSign: noSign, noEntitlements: noEntitlements) { success, error in
            if success {
                reply(true, nil)
                NSLog("Successfully extracted and signed binaries in directory \(normalizedDir)")
            } else {
                reply(false, "Failed to extract and sign binaries.")
                NSLog("Failed to extract and sign binaries in directory \(normalizedDir): \(error ?? "Unknown error")")
            }
        }
    }
    
    func setFilePermissions(atPath path: String, permissions: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        NSLog("Received request to set file permissions at path: \(path)")
        
        guard isPathAllowed(path) else {
            reply(false, "Operation not permitted on the specified path.")
            NSLog("Attempt to set permissions on a protected or disallowed path: \(path)")
            return
        }
        
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: normalizedPath)
            reply(true, nil)
            NSLog("File permissions set successfully at path: \(normalizedPath)")
        } catch {
            reply(false, "Failed to set file permissions.")
            NSLog("Failed to set file permissions at path \(normalizedPath): \(error.localizedDescription)")
        }
    }
    
    func checkFullDiskAccess(withReply reply: @escaping (Bool) -> Void) {
        NSLog("Initiating comprehensive Full Disk Access check...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                NSLog("HelperTool instance deallocated during FDA check")
                DispatchQueue.main.async {
                    reply(false)
                }
                return
            }
            
            guard let userHome = self.getCurrentUserHome() else {
                NSLog("Failed to determine user home directory")
                DispatchQueue.main.async {
                    reply(false)
                }
                return
            }
            
            var existingPaths: [String] = []
            var existingPathResults: [String: Bool] = [:]
            
            for path in self.protectedPaths {
                let resolvedPath = path.replacingOccurrences(of: "$HOME", with: userHome)
                if self.pathExists(resolvedPath) {
                    existingPaths.append(resolvedPath)
                    NSLog("Found existing path: \(resolvedPath)")
                } else {
                    NSLog("Path does not exist: \(resolvedPath)")
                }
            }
            
            if existingPaths.isEmpty {
                NSLog("No protected paths exist")
                DispatchQueue.main.async {
                    reply(false)
                }
                return
            }
            
            for path in existingPaths {
                let hasAccess = self.verifyAccess(to: path)
                existingPathResults[path] = hasAccess
                
                if hasAccess {
                    NSLog("Access verified for: \(path)")
                } else {
                    NSLog("Access denied for: \(path)")
                }
            }
            
            let hasFullAccess = !existingPathResults.values.contains(false)
            
            if hasFullAccess {
                NSLog("Full Disk Access is granted")
            } else {
                NSLog("Full Disk Access is not granted")
                for (path, hasAccess) in existingPathResults where !hasAccess {
                    NSLog("No access to: \(path)")
                }
                self.attemptToTriggerPrompt(userHome: userHome)
            }
            
            DispatchQueue.main.async {
                reply(hasFullAccess)
            }
        }
    }
}
