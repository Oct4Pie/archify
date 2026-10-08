//
//  UniversalApps.swift
//  archify
//
//  Created by oct4pie on 6/20/24.
//

import Foundation
import AppKit

struct ApplicationArchitectureScanResult {
    let totalSize: UInt64
    let removableSize: UInt64
    let fileCount: Int
}

class UniversalApps {
    static let shared = UniversalApps()
    private static let minimumUniversalBinarySize: UInt64 = 4096
    let fileManager = FileManager.default
    private let applicationDiscovery = ApplicationDiscovery()
    
    
    func findApps(completion: @escaping ([(name: String, path: String, type: String, architectures: String, icon: NSImage?)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var apps: [(name: String, path: String, type: String, architectures: String, icon: NSImage?)] = []
            let appPaths = self.applicationDiscovery.discoverApplicationPaths(
                in: ApplicationDiscovery.defaultRoots()
            )
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = max(
                1,
                min(4, ProcessInfo.processInfo.activeProcessorCount)
            )
            let lock = NSLock()

            for appPath in appPaths {
                queue.addOperation {
                    let (type, architectures) =
                        self.getAppTypeAndArchitectures(appPath: appPath)
                    let icon = self.getAppIcon(appPath: appPath)
                    let result = (
                        name: URL(fileURLWithPath: appPath).lastPathComponent,
                        path: appPath,
                        type: type,
                        architectures: architectures,
                        icon: icon
                    )
                    lock.lock()
                    apps.append(result)
                    lock.unlock()
                }
            }

            queue.waitUntilAllOperationsAreFinished()
            apps.sort { $0.path < $1.path }

            DispatchQueue.main.async {
                completion(apps)
            }
        }
    }

    private func getAppTypeAndArchitectures(appPath: String) -> (String, String) {
        let architectures = executablePaths(in: appPath)
            .flatMap { MachOInspector.architectures(atPath: $0) ?? [] }
        let uniqueArchitectures = Array(Set(architectures)).sorted()
        let type = appType(for: uniqueArchitectures)
        let architectureNames = uniqueArchitectures.map { architectureName($0) }
        return (type, architectureNames.isEmpty ? "Unknown" : architectureNames.joined(separator: ", "))
    }

    private func executablePaths(in appPath: String) -> [String] {
        ApplicationBundleInspector.executablePaths(
            in: appPath,
            fileManager: fileManager
        )
    }

    private func appType(for architectures: [String]) -> String {
        ArchitectureUtilities.appType(
            for: architectures,
            hostArchitecture: ProcessInfo.processInfo.machineArchitecture
        )
    }

    private func getAppIcon(appPath: String) -> NSImage? {
        NSWorkspace.shared.icon(forFile: appPath)
    }

    private func architectureName(_ architecture: String) -> String {
        switch architecture {
        case "x86_64":
            return "Intel 64-bit"
        case "x86_64h":
            return "Intel 64-bit"
        case "i386":
            return "Intel 32-bit"
        case "arm64":
            return "Apple Silicon (arm64)"
        case "arm64e":
            return "Apple Silicon (arm64e)"
        case "arm64e.x1":
            return "Apple Silicon (arm64e.x1)"
        default:
            return architecture
        }
    }

    func calculateUnneededArchSize(
        appPath: String, systemArch: String, progressHandler: @escaping (Int) -> Void, maxConcurrentProcesses: Int
    ) -> UInt64 {
        analyzeApplication(
            appPath: appPath,
            systemArch: systemArch,
            progressHandler: { processed, _ in
                progressHandler(processed)
            },
            maxConcurrentProcesses: maxConcurrentProcesses
        ).removableSize
    }

    func produceSortedList(systemArch: String, progressHandler: @escaping (String, Int, Int) -> Void, completion: @escaping ([(String, UInt64)]) -> Void) {
        produceSortedAppSizes(
            systemArch: systemArch,
            progressHandler: progressHandler
        ) { appSizes in
            completion(appSizes.map { ($0.path, $0.savableSize) })
        }
    }

    func produceSortedAppSizes(
        systemArch: String,
        control: RunControl? = nil,
        progressHandler: @escaping (String, Int, Int) -> Void,
        completion: @escaping ([(path: String, totalSize: UInt64, savableSize: UInt64)]) -> Void
    ) {
        let excludedNames = Set(defaultMacOSApps())
        let appPaths = applicationDiscovery.discoverApplicationPaths(
            in: ApplicationDiscovery.defaultRoots()
        ).filter {
            !excludedNames.contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
        var detailedAppSizes: [
            (path: String, totalSize: UInt64, savableSize: UInt64)
        ] = []

        let totalApps = appPaths.count
        var processedApps = 0

        for app in appPaths {
            // Pausing waits here; canceling keeps the apps scanned so far.
            if let control, !control.checkpoint() {
                break
            }
            progressHandler(app, processedApps, totalApps)
            let analysis = analyzeApplication(
                appPath: app,
                systemArch: systemArch,
                progressHandler: nil,
                maxConcurrentProcesses: 8
            )
            if analysis.removableSize > 0 {
                detailedAppSizes.append(
                    (
                        path: app,
                        totalSize: analysis.totalSize,
                        savableSize: analysis.removableSize
                    )
                )
            }
            processedApps += 1
            progressHandler(app, processedApps, totalApps)
        }

        let sorted = detailedAppSizes.sorted {
            $0.savableSize > $1.savableSize
        }
        completion(sorted)
    }

    public func calculateDirectorySize(path: String) -> UInt64 {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return 0
        }

        var totalSize: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: Set(keys)
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true
            else {
                continue
            }
            totalSize += UInt64(values.fileSize ?? 0)
        }
        return totalSize
    }

    func analyzeApplication(
        appPath: String,
        systemArch: String,
        progressHandler: ((Int, Int) -> Void)?,
        maxConcurrentProcesses: Int
    ) -> ApplicationArchitectureScanResult {
        let root = URL(fileURLWithPath: appPath, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return ApplicationArchitectureScanResult(
                totalSize: 0,
                removableSize: 0,
                fileCount: 0
            )
        }

        var files: [(path: String, size: UInt64)] = []
        var totalSize: UInt64 = 0
        // Match ApplicationThinner: binaries sealed as resources are left
        // alone in signed apps, so they are not removable savings.
        let sealedResources = SealedResourceIndex(applicationPath: root.path)

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: Set(keys)
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true
            else {
                continue
            }

            let size = UInt64(values.fileSize ?? 0)
            totalSize += size
            // Slices in a universal binary are page aligned, so anything
            // smaller than a page cannot have a removable slice.
            if size >= Self.minimumUniversalBinarySize,
               !sealedResources.isSealedResource(url.path) {
                files.append((url.path, size))
            }
        }

        let totalFiles = files.count
        guard totalFiles > 0 else {
            if let progressHandler {
                DispatchQueue.main.async {
                    progressHandler(0, 0)
                }
            }
            return ApplicationArchitectureScanResult(
                totalSize: totalSize,
                removableSize: 0,
                fileCount: 0
            )
        }

        let workerCount = max(
            1,
            min(
                maxConcurrentProcesses,
                min(8, ProcessInfo.processInfo.activeProcessorCount)
            )
        )
        let reportEvery = max(1, min(32, totalFiles / 20))
        let queue = DispatchQueue(
            label: "com.oct4pie.archify.architecture-scan",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: workerCount)
        let lock = NSLock()
        var removableSize: UInt64 = 0
        var processedFiles = 0

        if let progressHandler {
            DispatchQueue.main.async {
                progressHandler(0, totalFiles)
            }
        }

        for file in files {
            semaphore.wait()
            group.enter()
            queue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                var removable: UInt64 = 0
                if let architectureSizes = MachOInspector.architectureSizes(
                    atPath: file.path,
                    fileSize: file.size
                ),
                architectureSizes.count > 1 {
                    removable = ArchitectureUtilities.removableSize(
                        architectureSizes: architectureSizes,
                        targetArchitecture: systemArch
                    )
                }

                lock.lock()
                removableSize += removable
                processedFiles += 1
                let processed = processedFiles
                let shouldReport = processed == totalFiles
                    || processed % reportEvery == 0
                lock.unlock()

                if shouldReport, let progressHandler {
                    DispatchQueue.main.async {
                        progressHandler(processed, totalFiles)
                    }
                }
            }
        }

        group.wait()
        return ApplicationArchitectureScanResult(
            totalSize: totalSize,
            removableSize: removableSize,
            fileCount: totalFiles
        )
    }
}
