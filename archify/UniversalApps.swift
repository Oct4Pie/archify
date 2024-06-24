import Foundation
import AppKit

class UniversalApps {
    static let shared = UniversalApps()
    let fileManager = FileManager.default
    let fileOperations = FileOperations(appState: AppState())

    func countFilesInApp(appPath: String) -> Int {
        var count = 0
        if let enumerator = fileManager.enumerator(atPath: appPath) {
            for _ in enumerator {
                count += 1
            }
        }
        return count
    }
    
    
    func findApps(completion: @escaping ([(name: String, path: String, type: String, architectures: String, icon: NSImage?)]) -> Void) {
        DispatchQueue.global(qos: .background).async {
            let applicationsPath = "/Applications"
            var apps: [(name: String, path: String, type: String, architectures: String, icon: NSImage?)] = []

            if let appDirs = try? self.fileManager.contentsOfDirectory(atPath: applicationsPath) {
                for appDir in appDirs {
                    let appPath = (applicationsPath as NSString).appendingPathComponent(appDir)
                    if appPath.hasSuffix(".app") {
                        let (type, architectures) = self.getAppTypeAndArchitectures(appPath: appPath)
                        let icon = self.getAppIcon(appPath: appPath)
                        apps.append((name: appDir, path: appPath, type: type, architectures: architectures, icon: icon))
                    } else {
                        if let subItems = try? self.fileManager.contentsOfDirectory(atPath: appPath), subItems.count > 1 {
                            for subItem in subItems {
                                let subItemPath = (appPath as NSString).appendingPathComponent(subItem)
                                if subItemPath.hasSuffix(".app") {
                                    let (type, architectures) = self.getAppTypeAndArchitectures(appPath: subItemPath)
                                    let icon = self.getAppIcon(appPath: subItemPath)
                                    apps.append((name: subItem, path: subItemPath, type: type, architectures: architectures, icon: icon))
                                }
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                completion(apps)
            }
        }
    }

    private func getAppTypeAndArchitectures(appPath: String) -> (String, String) {
        let macOSPath = (appPath as NSString).appendingPathComponent("Contents/MacOS")
        var architectures: [String] = []
        if let executables = try? fileManager.contentsOfDirectory(atPath: macOSPath) {
            for executable in executables {
                let executablePath = (macOSPath as NSString).appendingPathComponent(executable)
                if let archs = fileOperations.getArchitectures(path: executablePath) {
                    architectures.append(contentsOf: archs)
                }
            }
        }
        let uniqueArchitectures = Array(Set(architectures))
        let type = uniqueArchitectures.count > 1 ? "Universal" : (uniqueArchitectures.first == ProcessInfo.processInfo.machineArchitecture ? "Native" : "Other")
        let architectureNames = uniqueArchitectures.map { architectureName($0) }
        return (type, architectureNames.joined(separator: ", "))
    }

    private func getAppIcon(appPath: String) -> NSImage? {
        let infoPlistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        if let infoPlist = NSDictionary(contentsOfFile: infoPlistPath),
           let iconFile = infoPlist["CFBundleIconFile"] as? String ?? infoPlist["CFBundleIconName"] as? String {
            let iconFileName = (iconFile as NSString).deletingPathExtension
            let resourcesPath = (appPath as NSString).appendingPathComponent("Contents/Resources")
            do {
                if let iconPath = try fileManager.contentsOfDirectory(atPath: resourcesPath).first(where: { $0.hasPrefix(iconFileName) && $0.hasSuffix(".icns") }) {
                    return NSImage(contentsOfFile: (resourcesPath as NSString).appendingPathComponent(iconPath))
                }
            } catch {
                print("Error fetching contents of directory at path: \(resourcesPath), error: \(error)")
            }
        }
        return nil
    }

    private func architectureName(_ architecture: String) -> String {
        switch architecture {
        case "x86_64":
            return "Intel 64-bit"
        case "i386":
            return "Intel 32-bit"
        case "arm64":
            return "Apple Silicon (arm64)"
        default:
            return architecture
        }
    }

    func findUniversalBinaryApps() -> [String] {
        let applicationsPath = "/Applications"
        var universalBinaryApps: [String] = []

        let defaultMacOSApps = fetchDefaultMacOSApps()

        if let apps = try? fileManager.contentsOfDirectory(atPath: applicationsPath) {
            for app in apps {
                let appPath = (applicationsPath as NSString).appendingPathComponent(app)
                if appPath.hasSuffix(".app") && !defaultMacOSApps.contains(app) {
                    if isUniversalApp(appPath: appPath) {
                        universalBinaryApps.append(appPath)
                    }
                } else if !defaultMacOSApps.contains(app) {
                    // Check one level deeper if the directory contains more than one item
                    if let subItems = try? fileManager.contentsOfDirectory(atPath: appPath), subItems.count > 1 {
                        for subItem in subItems {
                            let subItemPath = (appPath as NSString).appendingPathComponent(subItem)
                            if subItemPath.hasSuffix(".app") {
                                if isUniversalApp(appPath: subItemPath) {
                                    universalBinaryApps.append(subItemPath)
                                }
                            }
                        }
                    }
                }
            }
        }

        return universalBinaryApps
    }

    private func isUniversalApp(appPath: String) -> Bool {
        let macOSPath = (appPath as NSString).appendingPathComponent("Contents/MacOS")
        if let executables = try? fileManager.contentsOfDirectory(atPath: macOSPath) {
            for executable in executables {
                let executablePath = (macOSPath as NSString).appendingPathComponent(executable)
                if fileOperations.isUniversal(path: executablePath, targetArch: ProcessInfo.processInfo.machineArchitecture) != nil {
                    return true
                }
            }
        }
        return false
    }

    public func fetchDefaultMacOSApps() -> Set<String> {
        var defaultApps = Set<String>()

        let systemAppsPaths = [
            "/System/Applications",
            "/System/Applications/Utilities"
        ]

        for path in systemAppsPaths {
            if let apps = try? fileManager.contentsOfDirectory(atPath: path) {
                defaultApps.formUnion(apps)
            }
        }
        
        defaultApps.insert("Xcode.app")
        defaultApps.insert("Safari.app")

        return defaultApps
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

    func produceSortedList(systemArch: String, progressHandler: @escaping (String, Int, Int) -> Void, completion: @escaping ([(String, UInt64)]) -> Void) {
        let universalBinaryApps = self.findUniversalBinaryApps()
        var appSizes: [(String, UInt64)] = []
        
        let totalApps = universalBinaryApps.count
        var processedApps = 0
        
        for app in universalBinaryApps {
            progressHandler(app, processedApps, totalApps)
            let size = self.calculateUnneededArchSize(appPath: app, systemArch: systemArch, progressHandler: { _ in }, maxConcurrentProcesses: 8)
            if size > 0 {
                appSizes.append((app, size))
            }
            processedApps += 1
            progressHandler(app, processedApps, totalApps)
        }

        let sortedAppSizes = appSizes.sorted { $0.1 > $1.1 }
        
        completion(sortedAppSizes)
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
