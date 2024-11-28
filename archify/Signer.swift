//
//  Signer.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import Foundation

class Signer {
    let appState: AppState
    let ldidPath: String
    
    init(appState: AppState, ldidPath: String) {
        self.appState = appState
        self.ldidPath = ldidPath
    }
    
    func signBin(bin: String, noEnt: Bool) {
        var entitlementsPath: String?
        
        if !noEnt {
            entitlementsPath = extractEntitlementsWithLdid(bin: bin)
            if entitlementsPath == nil {
                appState.appendLog("Failed to extract entitlements for \(bin)")
                return
            }
        }
        
        var arguments = ["-S", bin]
        if let entitlementsPath = entitlementsPath {
            arguments = ["-S\(entitlementsPath)", bin]
        }
        
        let process = Process()
        process.launchPath = ldidPath
        process.arguments = arguments
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                appState.appendLog("Successfully signed \(bin) with ldid")
            } else {
                appState.appendLog("Failed to sign \(bin) with ldid")
            }
        } catch {
            appState.appendLog("Error signing binary \(bin): \(error)")
        }
        
        if let entitlementsPath = entitlementsPath {
            try? FileManager.default.removeItem(atPath: entitlementsPath)
        }
    }
    
    private func extractEntitlementsWithLdid(bin: String) -> String? {
        let process = Process()
        process.launchPath = ldidPath
        process.arguments = ["-e", bin]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
        } catch {
            appState.appendLog("Error running ldid to extract entitlements: \(error)")
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            appState.appendLog("ldid failed to extract entitlements")
            return nil
        }
        
        guard
            let entitlements = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines), !entitlements.isEmpty
        else {
            appState.appendLog("No entitlements found in \(bin)")
            return nil
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let entitlementsPath = tempDir.appendingPathComponent(UUID().uuidString).path + ".xml"
        
        do {
            try entitlements.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)
            return entitlementsPath
        } catch {
            appState.appendLog("Error writing entitlements to file: \(error)")
            return nil
        }
    }
    
    func signApp(appPath: String, noEnt: Bool) {
        var entitlementsPath: String?
        
        if !noEnt {
            entitlementsPath = extractEntitlementsWithCodesign(at: appPath)
            if entitlementsPath == nil {
                appState.appendLog("Failed to extract entitlements for \(appPath)")
                return
            }
        }
        
        let process = Process()
        process.launchPath = "/usr/bin/codesign"
        var arguments = ["--force", "--deep", "-s", "-"]
        if let entitlementsPath = entitlementsPath {
            arguments.append("--entitlements")
            arguments.append(entitlementsPath)
        }
        arguments.append(appPath)
        process.arguments = arguments
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                appState.appendLog("Successfully ad-hoc signed \(appPath) with codesign")
            } else {
                appState.appendLog("Failed to ad-hoc sign \(appPath) with codesign")
            }
        } catch {
            appState.appendLog("Error signing app \(appPath): \(error)")
        }
        
        if let entitlementsPath = entitlementsPath {
            try? FileManager.default.removeItem(atPath: entitlementsPath)
        }
    }
    
    private func extractEntitlementsWithCodesign(at path: String) -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/codesign"
        process.arguments = ["-d", "--entitlements", "-", "--xml", path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                appState.appendLog("codesign failed to extract entitlements")
                return nil
            }
            
            guard
                let entitlements = String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !entitlements.isEmpty
            else {
                appState.appendLog("No entitlements found in \(path)")
                return nil
            }
            
            let tempDir = FileManager.default.temporaryDirectory
            let entitlementsPath = tempDir.appendingPathComponent(UUID().uuidString).path + ".xml"
            
            do {
                try entitlements.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)
                return entitlementsPath
            } catch {
                appState.appendLog("Error writing entitlements to file: \(error)")
                return nil
            }
        } catch {
            appState.appendLog("Error extracting entitlements with codesign: \(error)")
            return nil
        }
    }
}
