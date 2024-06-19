//
//  SizeCalculationView.swift
//  archify
//
//  Created by oct4pie on 6/12/24.
//

import Foundation

class UniversalApps {
    let fileManager = FileManager.default
    let fileOperations = FileOperations(appState: AppState())

    func findUniversalBinaryApps() -> [String] {
        let applicationsPath = "/Applications"
        var universalBinaryApps: [String] = []

        if let enumerator = fileManager.enumerator(atPath: applicationsPath) {
            for case let path as String in enumerator {
                let fullPath = (applicationsPath as NSString).appendingPathComponent(path)
                if fullPath.hasSuffix(".app"), isAppUniversal(appPath: fullPath) {
                    universalBinaryApps.append(fullPath)
                }
            }
        }

        return universalBinaryApps
    }

    func isAppUniversal(appPath: String) -> Bool {
        if let enumerator = fileManager.enumerator(atPath: appPath) {
            for case let path as String in enumerator {
                let fullPath = (appPath as NSString).appendingPathComponent(path)
                if fileOperations.isMach(path: fullPath),
                   fileOperations.isUniversal(path: fullPath, targetArch: "") != nil
                {
                    return true
                }
            }
        }
        return false
    }

    func countFilesInApp(appPath: String) -> Int {
        var count = 0
        if let enumerator = fileManager.enumerator(atPath: appPath) {
            for _ in enumerator {
                count += 1
            }
        }
        return count
    }

    func calculateUnneededArchSize(
        appPath: String, systemArch: String, progressHandler: @escaping (Int) -> Void, maxConcurrentProcesses: Int
    ) -> UInt64 {
        var totalSize: UInt64 = 0
        var processedFiles = 0
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        let totalSizeQueue = DispatchQueue(label: "com.universalApps.totalSizeQueue", attributes: .concurrent)
        let processedFilesQueue = DispatchQueue(label: "com.universalApps.processedFilesQueue", attributes: .concurrent)
        let semaphore = DispatchSemaphore(value: maxConcurrentProcesses)

        if let enumerator = FileManager.default.enumerator(atPath: appPath) {
            for case let path as String in enumerator {
                group.enter()
                semaphore.wait()
                queue.async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }

                    let fullPath = (appPath as NSString).appendingPathComponent(path)
                    var unneededArchSize: UInt64? = nil

                    if self.fileOperations.isMach(path: fullPath) {
                        if self.fileOperations.isUniversal(path: fullPath, targetArch: systemArch) != nil {
                            unneededArchSize = self.calculateUnneededArchSizeForBinary(binaryPath: fullPath, systemArch: systemArch)
                        }
                    }
                    if let size = unneededArchSize {
                        totalSizeQueue.sync(flags: .barrier) {
                            totalSize += size
                        }
                    }

                    processedFilesQueue.sync(flags: .barrier) {
                        processedFiles += 1
                    }

                    DispatchQueue.main.async {
                        progressHandler(processedFiles)
                    }
                }
            }
        }

        group.wait()
        return totalSize
    }

    private func calculateUnneededArchSizeForBinary(binaryPath: String, systemArch: String) -> UInt64? {
        let process = Process()
        process.launchPath = fileOperations.bundledLipoPath()
        process.arguments = ["-detailed_info", binaryPath]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            var architectureSizes: [String: UInt64] = [:]
            var currentArch: String?

            let lines = output.split(separator: "\n")
            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine.hasPrefix("architecture") {
                    let components = trimmedLine.split(separator: " ")
                    if components.count >= 2 {
                        currentArch = String(components[1])
                    }
                } else if trimmedLine.contains("size") && currentArch != nil {
                    let components = trimmedLine.split(separator: " ")
                    if let sizeIndex = components.firstIndex(of: "size"), sizeIndex + 1 < components.count {
                        let sizeString = components[sizeIndex + 1]
                        if let size = UInt64(sizeString) {
                            architectureSizes[currentArch!] = size
                        }
                    }
                }
            }

            let unneededSizes = architectureSizes.filter { $0.key != systemArch }.map { $0.value }
            let totalUnneededSize = unneededSizes.reduce(0, +)

            return totalUnneededSize
        } catch {
            print("Failed with error: \(error)")
            return nil
        }
    }

    func produceSortedList(systemArch: String, maxConcurrentProcesses: Int) -> [(String, UInt64)] {
        let universalBinaryApps = findUniversalBinaryApps()
        var appSizes: [(String, UInt64)] = []

        for app in universalBinaryApps {
            let size = calculateUnneededArchSize(appPath: app, systemArch: systemArch, progressHandler: { _ in }, maxConcurrentProcesses: maxConcurrentProcesses)
            if size > 0 {
                appSizes.append((app, size))
            }
        }

        return appSizes.sorted { $0.1 > $1.1 }
    }

    public func calculateDirectorySize(path: String) -> UInt64 {
        var totalSize: UInt64 = 0

        if let enumerator = fileManager.enumerator(atPath: path) {
            for case let file as String in enumerator {
                let fullPath = (path as NSString).appendingPathComponent(file)
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: fullPath)
                    if let fileSize = attributes[.size] as? UInt64 {
                        totalSize += fileSize
                    }
                } catch {
                    print("Error calculating size for \(fullPath): \(error)")
                }
            }
        }

        return totalSize
    }
}

