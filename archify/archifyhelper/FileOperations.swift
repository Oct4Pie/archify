//
//  FileOperations.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import AppKit
import Foundation

class FileOperations {
    let appState: AppState
    let fileManager = FileManager.default
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func bundledRsyncPath() -> String {
        return Bundle.main.path(forResource: "rsync", ofType: nil) ?? "/usr/bin/rsync"
    }
    
    func bundledLipoPath() -> String {
        return Bundle.main.path(forResource: "lipo", ofType: nil) ?? "/usr/bin/lipo"
    }
    
    func duplicateApp(appDir: String, outputDir: String) throws -> String? {
        let outputAppDir = (outputDir as NSString).appendingPathComponent((appDir as NSString).lastPathComponent)
        guard fileManager.fileExists(atPath: outputDir) else {
            throw NSError(domain: "Output directory does not exist", code: 1, userInfo: nil)
        }
        
        try fileManager.createDirectory(atPath: outputAppDir, withIntermediateDirectories: true, attributes: nil)
        
        let process = Process()
        process.launchPath = bundledRsyncPath()
        process.arguments = ["-r", "-v", "-aHz", appDir, outputDir]
        
        appState.appendLog("Running \(process.launchPath ?? "rsync") \(process.arguments?.joined(separator: " ") ?? "on input app")")
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            output.split(separator: "\n").forEach { line in
                if line.hasSuffix("/") {
                    let relativePath = String(line)
                    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
                    if components.count <= 5 {
                        let directory = components.prefix(5).joined(separator: "/")
                        DispatchQueue.main.async {
                            self.appState.appendLog(directory + "/*")
                        }
                    }
                }
            }
        }
        
        try process.run()
        process.waitUntilExit()
        fileHandle.readabilityHandler = nil
        
        return outputAppDir
    }
    
    func extractAndSignBinaries(in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool, completion: @escaping (Bool, String?) -> Void) {
        guard let enumerator = fileManager.enumerator(atPath: dir) else {
            let errorMessage = "Failed to create enumerator for directory \(dir)"
            appState.appendLog(errorMessage)
            completion(false, errorMessage)
            return
        }
        
        let universalApps = UniversalApps()
        let queue = DispatchQueue(label: "fileOperations.extractAndSignBinaries", attributes: .concurrent)
        let group = DispatchGroup()
        
        for element in enumerator {
            if let filePath = element as? String {
                group.enter()
                queue.async {
                    let fullPath = (dir as NSString).appendingPathComponent(filePath)
                    if self.isMach(path: fullPath), let arch = self.isUniversal(path: fullPath, targetArch: targetArch) {
                        self.processBinary(at: fullPath, arch: arch, noSign: noSign, noEntitlements: noEntitlements)
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            self.appState.appendLog("All binaries processed.")
            if self.appState.useCodesign {
                self.codesignApp(at: dir, noEntitlements: noEntitlements)
            }
            self.appState.finalAppSize = universalApps.calculateDirectorySize(path: self.appState.outputDir)
            self.appState.appendLog("Final App Size: \(self.appState.finalAppSize) bytes")
            self.appState.isProcessing = false
            self.appState.outputDir = (self.appState.outputDir as NSString).deletingLastPathComponent
            completion(true, nil)
        }
    }
    
    private func processBinary(at path: String, arch: String, noSign: Bool, noEntitlements: Bool) {
        cleanBin(bin: path, arch: arch)
        if !noSign {
            if appState.useLDID, let ldidPath = appState.findLdid() {
                let signer = Signer(appState: appState, ldidPath: ldidPath)
                signer.signBin(bin: path, noEnt: noEntitlements)
            }
        }
    }
    
    func cleanBin(bin: String, arch: String) {
        let process = Process()
        process.launchPath = bundledLipoPath()
        process.arguments = [bin, "-thin", arch, "-output", bin]
        NSLog("Cleaning binary: \(bin) for architecture: \(arch) with arguments: \(String(describing: process.arguments))")
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let errorMessage = "Error cleaning binary \(bin) for architecture \(arch): \(error)"
            appState.appendLog(errorMessage)
            NSLog(errorMessage)
        }
    }
    
    func isMach(path: String) -> Bool {
        guard fileManager.isReadableFile(atPath: path) else { return false }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            if let fileType = attributes[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
                return false
            }
            
            if let typeIdentifier = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (path as NSString).pathExtension as CFString, nil)?.takeRetainedValue() {
                if UTTypeConformsTo(typeIdentifier, kUTTypeAliasFile) {
                    return false
                }
            }
        } catch {
            let errorMessage = "Error getting file attributes for \(path): \(error)"
            appState.appendLog(errorMessage)
            NSLog(errorMessage)
            return false
        }
        
        let process = Process()
        process.launchPath = "/usr/bin/file"
        process.arguments = ["--mime-type", path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.contains("application/x-mach-binary") ?? false
        } catch {
            let errorMessage = "Error determining file type for \(path): \(error)"
            appState.appendLog(errorMessage)
            NSLog(errorMessage)
            return false
        }
    }
    
    func isUniversal(path: String, targetArch: String) -> String? {
        let process = Process()
        process.launchPath = bundledLipoPath()
        process.arguments = ["-info", path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let archs = output.split(separator: " ")
            
            if archs.count == 1 {
                return nil
            }
            
            if archs.contains(Substring(targetArch)) {
                return targetArch
            }
            
            if targetArch == "arm64" && archs.contains("arm64e") {
                return "arm64e"
            }
            
            if targetArch == "arm64e" && archs.contains("arm64") {
                return "arm64"
            }
            
            if targetArch != "i386" && archs.contains("i386") {
                if targetArch == "x86_64" && archs.contains("x86_64") {
                    return "x86_64"
                }
                if ["arm64e", "arm64"].contains(targetArch), archs.contains("x86_64") {
                    return "x86_64"
                }
            }
            
            return nil
        } catch {
            let errorMessage = "Error determining universal binary info for \(path): \(error)"
            appState.appendLog(errorMessage)
            NSLog(errorMessage)
            return nil
        }
    }
    
    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
    func codesignApp(at path: String, noEntitlements: Bool) {
        let signer = Signer(appState: appState, ldidPath: "")
        signer.signApp(appPath: path, noEnt: noEntitlements)
    }
}
