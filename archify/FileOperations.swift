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
    private let applicationCopier = ApplicationCopier()
    private let applicationThinner = ApplicationThinner()
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func duplicateApp(
        appDir: String,
        outputDir: String,
        named name: String? = nil
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: appDir, isDirectory: true)
        let outputRootURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        appState.appendLog(
            "Copying \(inputURL.lastPathComponent) to \(outputRootURL.path)"
        )
        return try applicationCopier.copyApplication(
            from: appDir,
            toDirectory: outputDir,
            named: name
        )
    }
    
    func extractAndSignBinaries(
        in dir: String, targetArch: String, noSign: Bool, noEntitlements: Bool
    ) {
        let universalApps = UniversalApps()
        // Ad-hoc codesign reseals the whole copy afterwards, so thinning may
        // touch binaries sealed as resources. LDID only signs the changed
        // binaries and cannot repair a bundle seal.
        let signaturePolicy: ApplicationThinner.SignaturePolicy =
            !noSign && appState.useCodesign ? .willResign : .preserve

        applicationThinner.thinApplicationReportingChanges(
            atPath: dir,
            targetArchitecture: targetArch,
            signaturePolicy: signaturePolicy
        ) { changedPaths, thinningError in
            guard let changedPaths else {
                self.appState.appendLog(
                    "Failed to thin app: \(thinningError ?? "Unknown error")"
                )
                DispatchQueue.main.async {
                    self.appState.isProcessing = false
                }
                return
            }

            var signingSucceeded = true

            if !noSign, self.appState.useLDID {
                guard let ldidPath = self.appState.findLdid() else {
                    self.appState.appendLog("A compatible ldid executable was not found.")
                    signingSucceeded = false
                    self.finishProcessing(
                        directory: dir,
                        universalApps: universalApps,
                        success: signingSucceeded
                    )
                    return
                }

                let signer = Signer(appState: self.appState, ldidPath: ldidPath)
                for path in changedPaths {
                    if !signer.signBin(bin: path, noEnt: noEntitlements) {
                        signingSucceeded = false
                    }
                }
            }

            if !noSign, self.appState.useCodesign {
                let signer = Signer(appState: self.appState, ldidPath: "")
                if !signer.signApp(appPath: dir, noEnt: noEntitlements) {
                    signingSucceeded = false
                }
            }

            self.finishProcessing(
                directory: dir,
                universalApps: universalApps,
                success: signingSucceeded
            )
        }
    }

    private func finishProcessing(
        directory: String,
        universalApps: UniversalApps,
        success: Bool
    ) {
        let finalSize = universalApps.calculateDirectorySize(path: directory)
        DispatchQueue.main.async {
            self.appState.finalAppSize = finalSize
            self.appState.appendLog(
                success
                    ? "All binaries processed successfully."
                    : "Binary processing completed with signing errors."
            )
            self.appState.appendLog("Final App Size: \(finalSize) bytes")
            self.appState.isProcessing = false
        }
    }
    
    func getArchitectures(path: String) -> [String]? {
        MachOInspector.architectures(atPath: path)
    }

    func isUniversal(path: String, targetArch: String) -> String? {
        guard let archs = getArchitectures(path: path) else { return nil }
        return ArchitectureUtilities.preferredSlice(
            from: archs,
            targetArchitecture: targetArch
        )
    }
    
    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    
}
