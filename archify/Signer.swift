//
//  Signer.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import Foundation

class Signer {
    private enum EntitlementsExtraction {
        case extracted(path: String)
        case none
        case failed
    }

    let appState: AppState
    let ldidPath: String

    init(appState: AppState, ldidPath: String) {
        self.appState = appState
        self.ldidPath = ldidPath
    }

    @discardableResult
    func signBin(bin: String, noEnt: Bool) -> Bool {
        var entitlementsPath: String?

        if !noEnt {
            switch extractEntitlementsWithLdid(bin: bin) {
            case .extracted(let path):
                entitlementsPath = path
            case .none:
                break
            case .failed:
                appState.appendLog("Failed to extract entitlements for \(bin)")
                return false
            }
        }
        defer {
            if let entitlementsPath {
                try? FileManager.default.removeItem(atPath: entitlementsPath)
            }
        }

        var arguments = ["-S", bin]
        if let entitlementsPath = entitlementsPath {
            arguments = ["-S\(entitlementsPath)", bin]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ldidPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                appState.appendLog("Successfully signed \(bin) with ldid")
                return true
            } else {
                appState.appendLog("Failed to sign \(bin) with ldid")
                return false
            }
        } catch {
            appState.appendLog("Error signing binary \(bin): \(error)")
            return false
        }
    }

    private func extractEntitlementsWithLdid(bin: String) -> EntitlementsExtraction {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ldidPath)
        process.arguments = ["-e", bin]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            appState.appendLog("Error running ldid to extract entitlements: \(error)")
            return .failed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            appState.appendLog("ldid failed to extract entitlements")
            return .failed
        }

        return writeEntitlements(data, for: bin)
    }

    @discardableResult
    func signApp(appPath: String, noEnt: Bool) -> Bool {
        var entitlementsPath: String?

        if !noEnt {
            switch extractEntitlementsWithCodesign(at: appPath) {
            case .extracted(let path):
                entitlementsPath = path
            case .none:
                break
            case .failed:
                appState.appendLog("Failed to extract entitlements for \(appPath)")
                return false
            }
        }
        defer {
            if let entitlementsPath {
                try? FileManager.default.removeItem(atPath: entitlementsPath)
            }
        }

        // Sign nested code without entitlements first, then re-sign only the
        // outer app with the main executable's entitlements. Combining
        // --deep with --entitlements would copy them onto every helper,
        // framework, and plug-in.
        guard runCodesign(["--force", "--deep", "-s", "-", appPath]) else {
            appState.appendLog("Failed to ad-hoc sign \(appPath) with codesign")
            return false
        }

        if let entitlementsPath {
            guard runCodesign([
                "--force",
                "-s",
                "-",
                "--entitlements",
                entitlementsPath,
                appPath
            ]) else {
                appState.appendLog(
                    "Failed to apply entitlements to \(appPath) with codesign"
                )
                return false
            }
        }

        appState.appendLog("Successfully ad-hoc signed \(appPath) with codesign")
        return true
    }

    private func runCodesign(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            appState.appendLog("Error running codesign: \(error)")
            return false
        }
    }

    private func extractEntitlementsWithCodesign(at path: String) -> EntitlementsExtraction {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            appState.appendLog("Error extracting entitlements with codesign: \(error)")
            return .failed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            appState.appendLog("codesign failed to extract entitlements")
            return .failed
        }

        return writeEntitlements(data, for: path)
    }

    private func writeEntitlements(_ data: Data, for path: String) -> EntitlementsExtraction {
        guard let entitlements = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !entitlements.isEmpty
        else {
            appState.appendLog("No entitlements found in \(path); signing without entitlements")
            return .none
        }

        let entitlementsPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path + ".xml"

        do {
            try entitlements.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)
            return .extracted(path: entitlementsPath)
        } catch {
            appState.appendLog("Error writing entitlements to file: \(error)")
            return .failed
        }
    }
}
