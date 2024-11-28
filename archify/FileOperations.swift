//
//  FileOperations.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

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
        let outputAppDir = (outputDir as NSString).appendingPathComponent(
            (appDir as NSString).lastPathComponent)
        guard fileManager.fileExists(atPath: outputDir) else {
            throw NSError(domain: "Output directory does not exist", code: 1, userInfo: nil)
        }
        
        try fileManager.createDirectory(
            atPath: outputAppDir, withIntermediateDirectories: true, attributes: nil)
        
        let process = Process()
        process.launchPath = bundledRsyncPath()
        process.arguments = ["-r", "-v", "-aHz", appDir, outputDir]
        
        appState.appendLog(
            "Running \(process.launchPath ?? "rsync") \(process.arguments?.joined(separator: " ") ?? "on input app")"
        )
        
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
    
    func extractAndSignBinaries(
        in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool
    ) {
        guard let enumerator = fileManager.enumerator(atPath: dir) else {
            appState.appendLog("Failed to create enumerator for directory \(dir)")
            appState.isProcessing = false
            return
        }
        let universalApps = UniversalApps()
        
        let queue = DispatchQueue(
            label: "fileOperations.extractAndSignBinaries", attributes: .concurrent)
        let group = DispatchGroup()
        
        for element in enumerator {
            if let filePath = element as? String {
                group.enter()
                queue.async {
                    let fullPath = (dir as NSString).appendingPathComponent(filePath)
                    if self.isMach(path: fullPath),
                       let arch = self.isUniversal(path: fullPath, targetArch: targetArch)
                    {
                        self.processBinary(
                            at: fullPath, arch: arch, noSign: noSign, noEntitlements: noEntitlements)
                    }
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) { [self] in
            self.appState.appendLog("All binaries processed.")
            if self.appState.useCodesign {
                self.codesignApp(at: dir, noEntitlements: noEntitlements)
            }
            
            self.appState.finalAppSize = universalApps.calculateDirectorySize(
                path: self.appState.outputDir)
            self.appState.appendLog("Final App Size: \(self.appState.finalAppSize) bytes")
            self.appState.isProcessing = false
            self.appState.outputDir = (self.appState.outputDir as NSString).deletingLastPathComponent
        }
    }
    
    func getArchitectures(path: String) -> [String]? {
        let process = Process()
        process.launchPath = "/usr/bin/lipo"
        process.arguments = ["-info", path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            
            let components = output.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            return components?.map { String($0) }
        } catch {
            print("Failed to get architectures: \(error)")
            return nil
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
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            appState.appendLog("Error cleaning binary \(bin) for architecture \(arch): \(error)")
        }
    }
    
    func isMach(path: String) -> Bool {
        let fileManager = FileManager.default
        
        // Ensure the file is readable
        guard fileManager.isReadableFile(atPath: path) else { return false }

        do {
            // Retrieve file attributes once
            let attributes = try fileManager.attributesOfItem(atPath: path)
            
            // Check if the file is a symbolic link
            if let fileType = attributes[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
                return false
            }

            // Check if the file extension conforms to an alias file type
            let pathExtension = (path as NSString).pathExtension
            if !pathExtension.isEmpty {
                if let typeIdentifier = UTTypeCreatePreferredIdentifierForTag(
                    kUTTagClassFilenameExtension,
                    pathExtension as CFString,
                    nil
                )?.takeRetainedValue(),
                   UTTypeConformsTo(typeIdentifier, UTType.aliasFile.identifier as CFString) {
                    return false
                }
            }
        } catch {
            // Log the error and return false
            // Replace `print` with your preferred logging mechanism
            print("Error getting file attributes: \(error)")
            return false
        }

        // Define Mach-O magic numbers
        let machOMagicNumbers: Set<UInt32> = [
            0xFEEDFACE, // 32-bit
            0xFEEDFACF, // 64-bit
            0xCAFEBABE, // Fat binary
            0xBEBAFECA  // Fat binary, reverse endian
        ]

        // Open the file and read the first 4 bytes to check the magic number
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer {
            try? fileHandle.close()
        }

        let magicData = fileHandle.readData(ofLength: 4)
        guard magicData.count == 4 else { return false }

        // Convert the first 4 bytes to UInt32
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Convert to big endian to match the magic numbers
        let bigEndianMagic = UInt32(bigEndian: magic)

        // Check if the magic number matches any of the Mach-O types
        return machOMagicNumbers.contains(bigEndianMagic)
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
            let output =
            String(data: data, encoding: .utf8)?.split(separator: ":").last?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
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
            appState.appendLog("Error determining universal binary info: \(error)")
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
