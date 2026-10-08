import Darwin
import Foundation

struct ApplicationCopier {
    private let fileManager: FileManager
    private let dittoURL: URL

    init(
        fileManager: FileManager = .default,
        dittoURL: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) {
        self.fileManager = fileManager
        self.dittoURL = dittoURL
    }

    /// Copies the app into `outputDirectory`, as `name` when given (for
    /// example "Example 2.app" to keep an existing copy), otherwise under
    /// its own name. Never overwrites anything.
    func copyApplication(
        from appPath: String,
        toDirectory outputDirectory: String,
        named name: String? = nil
    ) throws -> String {
        let inputURL = URL(fileURLWithPath: appPath, isDirectory: true)
            .standardized
            .resolvingSymlinksInPath()
        let outputRootURL = URL(
            fileURLWithPath: outputDirectory,
            isDirectory: true
        )
        .standardized
        .resolvingSymlinksInPath()
        let outputName = name ?? inputURL.lastPathComponent
        guard outputName.lowercased().hasSuffix(".app"),
              !outputName.contains("/"),
              outputName != ".app"
        else {
            throw copyError(6, "The copy needs a valid app name.")
        }
        let outputURL = outputRootURL.appendingPathComponent(
            outputName,
            isDirectory: true
        )

        var isDirectory: ObjCBool = false
        guard inputURL.pathExtension.lowercased() == "app",
              fileManager.fileExists(
                atPath: inputURL.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue else {
            throw copyError(1, "Input is not an application bundle.")
        }

        isDirectory = false
        guard fileManager.fileExists(
            atPath: outputRootURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw copyError(2, "Output directory does not exist.")
        }

        guard !outputRootURL.path.hasPrefix(inputURL.path + "/") else {
            throw copyError(
                7,
                "Choose a destination outside the app you're copying."
            )
        }

        guard inputURL.path != outputURL.path else {
            throw copyError(
                3,
                "Input and output application paths are identical."
            )
        }

        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw copyError(
                4,
                "An application with the same name already exists at the destination."
            )
        }

        let process = Process()
        process.executableURL = dittoURL
        process.arguments = [
            "--rsrc",
            "--extattr",
            "--acl",
            inputURL.path,
            outputURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DITTOABORT"] = "1"
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let errorOutput: Data
        do {
            try process.run()
            // Drain stderr before waiting so a full pipe cannot stall ditto.
            errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            try? fileManager.removeItem(at: outputURL)
            if let detail, !detail.isEmpty {
                throw copyError(
                    Int(process.terminationStatus),
                    "Failed to copy app: \(detail)"
                )
            }
            throw copyError(
                Int(process.terminationStatus),
                "Failed to copy the application bundle."
            )
        }

        isDirectory = false
        guard fileManager.fileExists(
            atPath: outputURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw copyError(
                5,
                "Copy completed without a valid destination app bundle."
            )
        }

        return outputURL.path
    }

    private func copyError(_ code: Int, _ description: String) -> NSError {
        NSError(
            domain: "Archify.Copy",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

struct ApplicationDiscovery {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func defaultRoots(fileManager: FileManager = .default) -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        return roots.filter {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    func discoverApplicationPaths(in roots: [URL]) -> [String] {
        var discovered = Set<String>()

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if isApplicationDirectory(entry), isWithinRoot(entry.path, rootPath: root.path) {
                    discovered.insert(entry.standardized.resolvingSymlinksInPath().path)
                    continue
                }

                guard isPlainDirectory(entry),
                      let children = try? fileManager.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                      )
                else {
                    continue
                }

                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where isApplicationDirectory(child) && isWithinRoot(child.path, rootPath: root.path) {
                    discovered.insert(child.standardized.resolvingSymlinksInPath().path)
                }
            }
        }

        return discovered.sorted()
    }

    func isWithinRoot(_ path: String, rootPath: String) -> Bool {
        let candidate = URL(fileURLWithPath: path)
            .standardized
            .resolvingSymlinksInPath()
            .path
        let root = URL(fileURLWithPath: rootPath)
            .standardized
            .resolvingSymlinksInPath()
            .path
        return candidate.hasPrefix(root + "/")
    }

    private func isApplicationDirectory(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app" && isPlainDirectory(url)
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

struct LanguageResourceDiscovery {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func languageResources(inApplication appPath: String) -> [String: [String]] {
        let appRoot = URL(fileURLWithPath: appPath, isDirectory: true)
            .standardized
            .resolvingSymlinksInPath()
            .path
        guard URL(fileURLWithPath: appRoot).pathExtension.lowercased() == "app",
              let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: appRoot, isDirectory: true),
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
              )
        else {
            return [:]
        }

        var result: [String: [String]] = [:]
        // Only offer folders the code signature lets go; removing a folder
        // the seal requires would make the app fail signature checks.
        let sealedResources = SealedResourceIndex(applicationPath: appRoot)

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "lproj" else { continue }

            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let validatedPath = validatedLanguageResourcePath(
                    url.path,
                    inApplication: appRoot
                  )
            else {
                enumerator.skipDescendants()
                continue
            }

            if sealedResources.containsRequiredResources(
                inDirectory: validatedPath
            ) {
                enumerator.skipDescendants()
                continue
            }

            let language = url.deletingPathExtension().lastPathComponent
            result[language, default: []].append(validatedPath)
            enumerator.skipDescendants()
        }

        return result.mapValues { $0.sorted() }
    }

    func validatedLanguageResourcePath(
        _ path: String,
        inApplication appPath: String
    ) -> String? {
        let appRoot = URL(fileURLWithPath: appPath, isDirectory: true)
            .standardized
            .resolvingSymlinksInPath()
            .path
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardized
            .resolvingSymlinksInPath()
            .path

        guard URL(fileURLWithPath: appRoot).pathExtension.lowercased() == "app",
              candidate.hasPrefix(appRoot + "/"),
              URL(fileURLWithPath: candidate).pathExtension.lowercased() == "lproj"
        else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: candidate,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }

        return candidate
    }
}

enum LanguageProtection {
    /// Legacy `.lproj` names used before ISO language codes.
    private static let legacyNames: [String: String] = [
        "english": "en",
        "french": "fr",
        "german": "de",
        "italian": "it",
        "japanese": "ja",
        "spanish": "es",
        "dutch": "nl"
    ]

    /// One key per language as people think of it: "English" and "en"
    /// share a key, as do "pt_BR" and "pt-BR".
    static func languageKey(_ folderName: String) -> String {
        if let code = legacyNames[folderName.lowercased()] {
            return code
        }
        return folderName.replacingOccurrences(of: "_", with: "-")
    }

    /// A readable name such as "French" or "Portuguese (Brazil)".
    static func displayName(
        forKey key: String,
        locale: Locale = .current
    ) -> String {
        if key.caseInsensitiveCompare("Base") == .orderedSame {
            return "Base"
        }
        let name = locale.localizedString(forIdentifier: key)
            ?? locale.localizedString(forLanguageCode: key)
            ?? key
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The base language code of an `.lproj` name or locale identifier,
    /// e.g. "en" for "en_GB", "en-US", or "English".
    static func languageCode(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        if let code = legacyNames[lowercased] {
            return code
        }
        return lowercased
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? lowercased
    }

    /// Language codes of the languages the user reads, from their system
    /// language preferences.
    static func preferredLanguageCodes(
        _ preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Set<String> {
        Set(preferredLanguages.map(languageCode))
    }

    /// The app's development region, which macOS falls back to when no other
    /// localization matches. Bundles that omit it default to English.
    static func developmentLanguageCode(
        inApplication appPath: String
    ) -> String {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        for plistURL in [
            appURL.appendingPathComponent("Contents/Info.plist"),
            appURL.appendingPathComponent("Info.plist")
        ] {
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any]
            else {
                continue
            }
            if let region = plist["CFBundleDevelopmentRegion"] as? String,
               !region.isEmpty {
                return languageCode(region)
            }
            return "en"
        }
        return "en"
    }

    static func protectedLanguages(
        _ languages: [String],
        developmentLanguageCode: String,
        preferredLanguageCodes: Set<String>
    ) -> Set<String> {
        Set(languages.filter {
            let code = languageCode($0)
            return code == developmentLanguageCode
                || preferredLanguageCodes.contains(code)
        })
    }
}

enum ApplicationBundleInspector {
    static func executablePaths(
        in appPath: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        let resolvedAppPath = appURL.standardized.resolvingSymlinksInPath().path
        var paths: [String] = []

        let plistCandidates: [(URL, URL)] = [
            (
                appURL.appendingPathComponent("Contents/Info.plist"),
                appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            ),
            (
                appURL.appendingPathComponent("Info.plist"),
                appURL
            )
        ]

        for (plistURL, executableDirectory) in plistCandidates {
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let executable = plist["CFBundleExecutable"] as? String,
                  !executable.isEmpty
            else {
                continue
            }

            let executableURL = executableDirectory.appendingPathComponent(executable)
            if let executablePath = canonicalRegularFilePath(
                executableURL,
                withinResolvedAppPath: resolvedAppPath,
                fileManager: fileManager
            ), !paths.contains(executablePath) {
                paths.append(executablePath)
            }
        }

        let macOSDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if let executables = try? fileManager.contentsOfDirectory(at: macOSDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for executable in executables.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let path = canonicalRegularFilePath(
                    executable,
                    withinResolvedAppPath: resolvedAppPath,
                    fileManager: fileManager
                ) else {
                    continue
                }
                if !paths.contains(path) {
                    paths.append(path)
                }
            }
        }

        return paths
    }

    private static func canonicalRegularFilePath(
        _ url: URL,
        withinResolvedAppPath appPath: String,
        fileManager: FileManager
    ) -> String? {
        let resolved = url.standardized.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(appPath + "/"),
              let attributes = try? fileManager.attributesOfItem(atPath: resolved),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            return nil
        }
        return resolved
    }
}

/// Identifies files that a bundle's code signature seals as plain resources.
///
/// A signed bundle records nested code (frameworks, helpers, plug-ins) by
/// cdhash, which survives removing an unused slice. Any other file, including
/// Mach-O files under Resources such as Electron `.node` modules, is sealed by
/// a hash of its full contents, so thinning it invalidates the enclosing
/// bundle's signature.
///
/// Not thread-safe; use from one thread at a time.
final class SealedResourceIndex {
    private struct Seal {
        /// Files sealed by content hash (resources, not nested code).
        var resources = Set<String>()
        /// Resources the signature requires to be present. Localization
        /// folders are normally sealed as optional and may be removed.
        var requiredResources = Set<String>()
    }

    private let rootPath: String
    private var sealingDirectories: [String: String?] = [:]
    private var seals: [String: Seal] = [:]

    init(applicationPath: String) {
        rootPath = applicationPath
    }

    func isSealedResource(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        guard let sealingDirectory = sealingDirectory(for: directory),
              path.hasPrefix(sealingDirectory + "/")
        else {
            return false
        }
        let relativePath = String(path.dropFirst(sealingDirectory.count + 1))
        return seal(of: sealingDirectory).resources.contains(relativePath)
    }

    /// Whether removing `directory` would break the enclosing bundle's
    /// signature because the seal requires a file inside it.
    func containsRequiredResources(inDirectory directory: String) -> Bool {
        let parent = (directory as NSString).deletingLastPathComponent
        guard let sealingDirectory = sealingDirectory(for: parent),
              directory.hasPrefix(sealingDirectory + "/")
        else {
            return false
        }
        let prefix = String(directory.dropFirst(sealingDirectory.count + 1)) + "/"
        return seal(of: sealingDirectory).requiredResources.contains {
            $0.hasPrefix(prefix)
        }
    }

    /// The innermost directory at or above `directory` whose
    /// `_CodeSignature/CodeResources` seals it, without leaving the app.
    private func sealingDirectory(for directory: String) -> String? {
        if let cached = sealingDirectories[directory] {
            return cached
        }

        let result: String?
        if directory != rootPath, !directory.hasPrefix(rootPath + "/") {
            result = nil
        } else if FileSystemUtilities.identity(
            atPath: codeResourcesPath(in: directory),
            requireRegularFile: true
        ) != nil {
            result = directory
        } else if directory == rootPath {
            result = nil
        } else {
            result = sealingDirectory(
                for: (directory as NSString).deletingLastPathComponent
            )
        }

        sealingDirectories[directory] = result
        return result
    }

    private func seal(of directory: String) -> Seal {
        if let cached = seals[directory] {
            return cached
        }

        var seal = Seal()
        if let data = FileManager.default.contents(
            atPath: codeResourcesPath(in: directory)
        ),
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let files = (plist["files2"] ?? plist["files"]) as? [String: Any] {
            for (relativePath, entry) in files {
                let attributes = entry as? [String: Any]
                if attributes?["cdhash"] != nil || attributes?["symlink"] != nil {
                    continue
                }
                seal.resources.insert(relativePath)
                if attributes?["optional"] as? Bool != true {
                    seal.requiredResources.insert(relativePath)
                }
            }
        }

        seals[directory] = seal
        return seal
    }

    private func codeResourcesPath(in directory: String) -> String {
        (directory as NSString)
            .appendingPathComponent("_CodeSignature/CodeResources")
    }
}

final class ApplicationThinner {
    /// macOS protects notarized apps that have been opened from changes by
    /// other developers' software; Full Disk Access lifts that protection.
    static let changeNotPermittedMessage =
        "macOS protected this app from changes. No files were changed."

    enum SignaturePolicy {
        /// Keep a valid existing signature valid: skip binaries sealed as
        /// resources and roll back if the result no longer verifies.
        case preserve
        /// The caller re-signs the whole app afterwards, so every universal
        /// binary may be thinned and the old signature is not checked.
        case willResign
    }

    private struct PreparedReplacement {
        let originalPath: String
        let relativePath: String
        let preparedPath: String
        let preparedName: String
        let originalIdentity: FileSystemIdentity
        let preparedIdentity: FileSystemIdentity
    }

    private struct CommittedReplacement {
        let originalPath: String
        let relativePath: String
        let backupName: String
        let replacementIdentity: FileSystemIdentity
    }

    private let fileManager: FileManager
    private let lipoURL: URL
    private let thinningQueue = DispatchQueue(
        label: "com.oct4pie.archify.thinning",
        qos: .userInitiated
    )

    init(
        fileManager: FileManager = .default,
        lipoURL: URL = URL(fileURLWithPath: "/usr/bin/lipo")
    ) {
        self.fileManager = fileManager
        self.lipoURL = lipoURL
    }

    func thinApplication(
        atPath appPath: String,
        targetArchitecture: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        thinApplicationReportingChanges(
            atPath: appPath,
            targetArchitecture: targetArchitecture
        ) { changedPaths, error in
            completion(changedPaths != nil, error)
        }
    }

    func thinApplicationReportingChanges(
        atPath appPath: String,
        targetArchitecture: String,
        signaturePolicy: SignaturePolicy = .preserve,
        completion: @escaping ([String]?, String?) -> Void
    ) {
        thinningQueue.async {
            self.performThinning(
                in: appPath,
                targetArchitecture: targetArchitecture,
                signaturePolicy: signaturePolicy,
                completion: completion
            )
        }
    }

    private func performThinning(
        in appPath: String,
        targetArchitecture: String,
        signaturePolicy: SignaturePolicy,
        completion: @escaping ([String]?, String?) -> Void
    ) {
        let appDirectoryFD = openDirectoryNoFollow(atPath: appPath)
        guard appDirectoryFD >= 0,
              let appIdentity = FileSystemUtilities.identity(
                ofFileDescriptor: appDirectoryFD,
                requireDirectory: true
              )
        else {
            if appDirectoryFD >= 0 {
                close(appDirectoryFD)
            }
            completion(nil, "The application path is not a stable directory.")
            return
        }
        defer { close(appDirectoryFD) }

        guard let transactionDirectory = createTransactionDirectory(
            forApplicationPath: appPath
        ) else {
            completion(nil, "Failed to create a thinning transaction directory.")
            return
        }

        let transactionFD = openDirectoryNoFollow(
            atPath: transactionDirectory.path
        )
        guard transactionFD >= 0 else {
            cleanupTransactionDirectory(transactionDirectory)
            completion(nil, "Failed to secure the thinning transaction directory.")
            return
        }
        defer { close(transactionFD) }

        guard pathIdentityMatches(
            appPath,
            expected: appIdentity,
            requireDirectory: true
        ) else {
            cleanupTransactionDirectory(transactionDirectory)
            completion(nil, "The application changed before thinning began.")
            return
        }

        let requireDeepSignatureValidation: Bool
        let requireSignatureValidation: Bool
        switch signaturePolicy {
        case .preserve:
            requireDeepSignatureValidation = hasValidCodeSignature(
                atPath: appPath,
                deep: true
            )
            requireSignatureValidation =
                requireDeepSignatureValidation
                || hasValidCodeSignature(atPath: appPath)
        case .willResign:
            requireDeepSignatureValidation = false
            requireSignatureValidation = false
        }

        guard let enumerator = fileManager.enumerator(atPath: appPath) else {
            cleanupTransactionDirectory(transactionDirectory)
            completion(nil, "Failed to enumerate the application bundle.")
            return
        }

        // Snapshot the tree before creating any temporary files so the directory
        // enumerator can never discover Archify's own staging files.
        var relativePaths: [String] = []
        for case let relativePath as String in enumerator {
            relativePaths.append(relativePath)
        }

        if requireSignatureValidation {
            let sealedResources = SealedResourceIndex(applicationPath: appPath)
            relativePaths.removeAll {
                sealedResources.isSealedResource(
                    (appPath as NSString).appendingPathComponent($0)
                )
            }
        }

        let workerQueue = DispatchQueue(
            label: "com.oct4pie.archify.thinning.files",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let maxConcurrentOperations = max(
            2,
            min(8, ProcessInfo.processInfo.activeProcessorCount)
        )
        let semaphore = DispatchSemaphore(value: maxConcurrentOperations)
        let stateLock = NSLock()
        var firstFailure: String?
        var preparedReplacements: [PreparedReplacement] = []

        for relativePath in relativePaths {
            semaphore.wait()
            group.enter()
            workerQueue.async {
                defer {
                    semaphore.signal()
                    group.leave()
                }

                let fullPath = (appPath as NSString).appendingPathComponent(relativePath)
                guard let architecture = self.thinnableArchitecture(
                    atPath: fullPath,
                    targetArchitecture: targetArchitecture
                ) else {
                    return
                }

                let result = self.prepareBinary(
                    atPath: fullPath,
                    relativePath: relativePath,
                    architecture: architecture,
                    transactionDirectory: transactionDirectory
                )

                stateLock.lock()
                if let replacement = result.replacement {
                    preparedReplacements.append(replacement)
                }
                if let error = result.error {
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
                stateLock.unlock()
            }
        }

        group.wait()
        stateLock.lock()
        let failure = firstFailure
        let prepared = preparedReplacements.sorted {
            $0.originalPath < $1.originalPath
        }
        stateLock.unlock()

        if let failure {
            cleanupTransactionDirectory(transactionDirectory)
            completion(nil, failure)
            return
        }

        guard pathIdentityMatches(
            appPath,
            expected: appIdentity,
            requireDirectory: true
        ) else {
            cleanupTransactionDirectory(transactionDirectory)
            completion(nil, "The application changed while binaries were being prepared.")
            return
        }

        let commitResult = commitPreparedReplacements(
            prepared,
            appDirectoryFD: appDirectoryFD,
            transactionFD: transactionFD,
            transactionDirectory: transactionDirectory
        )
        guard let committed = commitResult.committed else {
            completion(nil, commitResult.error)
            return
        }

        guard pathIdentityMatches(
            appPath,
            expected: appIdentity,
            requireDirectory: true
        ) else {
            let rollbackError = rollback(
                committed,
                appDirectoryFD: appDirectoryFD,
                transactionFD: transactionFD
            )
            if rollbackError == nil {
                cleanupTransactionDirectory(transactionDirectory)
            }
            completion(
                nil,
                transactionFailure(
                    "The application path changed during thinning.",
                    rollbackError: rollbackError
                )
            )
            return
        }

        if requireSignatureValidation,
           !hasValidCodeSignature(
                atPath: appPath,
                deep: requireDeepSignatureValidation
           ) {
            let rollbackError = rollback(
                committed,
                appDirectoryFD: appDirectoryFD,
                transactionFD: transactionFD
            )
            if rollbackError == nil {
                cleanupTransactionDirectory(transactionDirectory)
            }
            completion(
                nil,
                transactionFailure(
                    "Thinning would invalidate the application's existing code signature.",
                    rollbackError: rollbackError
                )
            )
            return
        }

        guard pathIdentityMatches(
            appPath,
            expected: appIdentity,
            requireDirectory: true
        ) else {
            let rollbackError = rollback(
                committed,
                appDirectoryFD: appDirectoryFD,
                transactionFD: transactionFD
            )
            if rollbackError == nil {
                cleanupTransactionDirectory(transactionDirectory)
            }
            completion(
                nil,
                transactionFailure(
                    "The application path changed while its signature was being verified.",
                    rollbackError: rollbackError
                )
            )
            return
        }

        finalizeCommittedReplacements(
            committed,
            transactionFD: transactionFD
        )
        cleanupTransactionDirectory(transactionDirectory)
        completion(prepared.map(\.originalPath), nil)
    }

    private func prepareBinary(
        atPath path: String,
        relativePath: String,
        architecture: String,
        transactionDirectory: URL
    ) -> (replacement: PreparedReplacement?, error: String?) {
        guard let originalIdentity = FileSystemUtilities.identity(
            atPath: path,
            requireRegularFile: true
        ) else {
            return (nil, "A binary changed before it could be prepared.")
        }

        let preparedURL = transactionDirectory
            .appendingPathComponent("prepared-\(UUID().uuidString)")
        let preparedPath = preparedURL.path
        let process = Process()
        process.executableURL = lipoURL
        process.arguments = [path, "-thin", architecture, "-output", preparedPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let errorOutput: Data
        do {
            try process.run()
            // Drain stderr before waiting so a full pipe cannot stall lipo.
            errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "Failed to launch the system architecture tool.")
        }

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                NSLog("lipo failed for %@: %@", path, detail)
            }
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "Failed to thin one or more binaries in the application.")
        }

        guard architectures(atPath: preparedPath) == [architecture] else {
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "The thinned binary failed architecture validation.")
        }

        guard copyMetadata(from: path, to: preparedPath) else {
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "Failed to preserve binary metadata while thinning.")
        }

        guard FileSystemUtilities.identity(
            atPath: path,
            requireRegularFile: true
        ) == originalIdentity else {
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "A binary changed while it was being prepared.")
        }

        guard let preparedIdentity = FileSystemUtilities.identity(
            atPath: preparedPath,
            requireRegularFile: true
        ) else {
            try? fileManager.removeItem(atPath: preparedPath)
            return (nil, "The prepared binary is not a stable regular file.")
        }

        return (
            PreparedReplacement(
                originalPath: path,
                relativePath: relativePath,
                preparedPath: preparedPath,
                preparedName: preparedURL.lastPathComponent,
                originalIdentity: originalIdentity,
                preparedIdentity: preparedIdentity
            ),
            nil
        )
    }

    private func copyMetadata(from source: String, to destination: String) -> Bool {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                copyfile(
                    sourcePointer,
                    destinationPointer,
                    nil,
                    copyfile_flags_t(COPYFILE_METADATA)
                )
            }
        }

        if result != 0 {
            NSLog(
                "copyfile metadata failed for %@: %s",
                source,
                strerror(errno)
            )
        }
        return result == 0
    }

    private func hasValidCodeSignature(
        atPath path: String,
        deep: Bool = false
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        var arguments = [
            "--verify",
            "--strict",
            "--all-architectures",
            "--verbose=0"
        ]
        if deep {
            arguments.append("--deep")
        }
        arguments.append(path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func commitPreparedReplacements(
        _ replacements: [PreparedReplacement],
        appDirectoryFD: Int32,
        transactionFD: Int32,
        transactionDirectory: URL
    ) -> (committed: [CommittedReplacement]?, error: String?) {
        var committed: [CommittedReplacement] = []

        func fail(
            _ message: String,
            alsoRollingBack extra: [CommittedReplacement] = []
        ) -> (committed: [CommittedReplacement]?, error: String?) {
            let rollbackError = rollback(
                committed + extra,
                appDirectoryFD: appDirectoryFD,
                transactionFD: transactionFD
            )
            if rollbackError == nil {
                cleanupTransactionDirectory(transactionDirectory)
            }
            let recovery = rollbackError == nil
                ? ""
                : " Recovery data remains at \(transactionDirectory.path)."
            return (
                nil,
                transactionFailure(
                    "\(message)\(recovery)",
                    rollbackError: rollbackError
                )
            )
        }

        for replacement in replacements {
            guard let parent = openParentDirectory(
                rootFD: appDirectoryFD,
                relativePath: replacement.relativePath
            ) else {
                return fail("A binary path became unsafe before replacement.")
            }
            defer { close(parent.fd) }

            guard FileSystemUtilities.identity(
                atDirectoryFD: parent.fd,
                name: parent.leaf,
                requireRegularFile: true
            ) == replacement.originalIdentity else {
                return fail("A binary changed before replacement.")
            }

            // Exchange the prepared binary and the original in one atomic
            // step. If macOS refuses the change (for example app protection),
            // nothing moves; a separate move-out/move-in could be allowed to
            // remove the original but refused when putting anything back.
            let swapError = swapEntries(
                transactionFD,
                replacement.preparedName,
                parent.fd,
                parent.leaf
            )
            guard swapError == 0 else {
                if swapError == EPERM || swapError == EACCES {
                    return fail(Self.changeNotPermittedMessage)
                }
                return fail(
                    "Failed to commit a prepared binary: "
                        + String(cString: strerror(swapError))
                )
            }

            // The original now sits in the transaction directory under the
            // prepared name and serves as the rollback copy.
            let swapped = CommittedReplacement(
                originalPath: replacement.originalPath,
                relativePath: replacement.relativePath,
                backupName: replacement.preparedName,
                replacementIdentity: replacement.preparedIdentity
            )

            guard FileSystemUtilities.identity(
                atDirectoryFD: parent.fd,
                name: parent.leaf,
                requireRegularFile: true
            ) == replacement.preparedIdentity,
            FileSystemUtilities.identity(
                atDirectoryFD: transactionFD,
                name: replacement.preparedName,
                requireRegularFile: true
            ) == replacement.originalIdentity
            else {
                return fail(
                    "A binary changed during replacement.",
                    alsoRollingBack: [swapped]
                )
            }

            committed.append(swapped)
        }

        return (committed, nil)
    }

    private func createTransactionDirectory(
        forApplicationPath appPath: String
    ) -> URL? {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        let directory = appURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".archify-transaction-\(UUID().uuidString)",
                isDirectory: true
            )

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            return directory
        } catch {
            NSLog(
                "Failed to create Archify transaction directory %@: %@",
                directory.path,
                error.localizedDescription
            )
            return nil
        }
    }

    private func cleanupTransactionDirectory(_ directory: URL) {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            NSLog(
                "Failed to remove Archify transaction directory %@: %@",
                directory.path,
                error.localizedDescription
            )
        }
    }

    private func finalizeCommittedReplacements(
        _ committed: [CommittedReplacement],
        transactionFD: Int32
    ) {
        for item in committed {
            if !unlinkEntry(
                directoryFD: transactionFD,
                name: item.backupName,
                removeDirectory: false
            ) {
                // The new app is already committed and valid. A leftover backup
                // is preferable to undoing a successful transaction at this point.
                NSLog(
                    "Failed to remove Archify backup %@: %s",
                    item.backupName,
                    strerror(errno)
                )
            }
        }
    }

    private func rollback(
        _ committed: [CommittedReplacement],
        appDirectoryFD: Int32,
        transactionFD: Int32
    ) -> String? {
        var failures: [String] = []

        for item in committed.reversed() {
            guard let parent = openParentDirectory(
                rootFD: appDirectoryFD,
                relativePath: item.relativePath
            ) else {
                failures.append("Unable to reopen a binary parent directory.")
                continue
            }
            defer { close(parent.fd) }

            guard FileSystemUtilities.identity(
                atDirectoryFD: parent.fd,
                name: parent.leaf,
                requireRegularFile: true
            ) == item.replacementIdentity else {
                failures.append("A replacement binary changed before rollback.")
                continue
            }

            // Swap the original back in atomically; the replacement moves
            // into the transaction directory and is removed with it.
            let swapError = swapEntries(
                transactionFD,
                item.backupName,
                parent.fd,
                parent.leaf
            )
            if swapError != 0 {
                failures.append(
                    "Failed to restore a backup during rollback: "
                        + String(cString: strerror(swapError))
                )
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    private func openDirectoryNoFollow(atPath path: String) -> Int32 {
        path.withCString { pointer in
            Darwin.open(
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }

    private func openParentDirectory(
        rootFD: Int32,
        relativePath: String
    ) -> (fd: Int32, leaf: String)? {
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let leaf = components.last,
              leaf != ".",
              leaf != ".."
        else {
            return nil
        }

        var currentFD = dup(rootFD)
        guard currentFD >= 0 else { return nil }

        for component in components.dropLast() {
            guard component != ".", component != ".." else {
                close(currentFD)
                return nil
            }

            let nextFD = component.withCString { pointer in
                openat(
                    currentFD,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            close(currentFD)
            guard nextFD >= 0 else {
                return nil
            }
            currentFD = nextFD
        }

        return (currentFD, leaf)
    }

    private func unlinkEntry(
        directoryFD: Int32,
        name: String,
        removeDirectory: Bool
    ) -> Bool {
        name.withCString { pointer in
            unlinkat(
                directoryFD,
                pointer,
                removeDirectory ? AT_REMOVEDIR : 0
            ) == 0
        }
    }

    /// Atomically exchanges two directory entries on the same volume.
    /// Returns 0 on success, otherwise the `errno` value.
    private func swapEntries(
        _ firstDirectoryFD: Int32,
        _ firstName: String,
        _ secondDirectoryFD: Int32,
        _ secondName: String
    ) -> Int32 {
        let status = firstName.withCString { firstPointer in
            secondName.withCString { secondPointer in
                renameatx_np(
                    firstDirectoryFD,
                    firstPointer,
                    secondDirectoryFD,
                    secondPointer,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        return status == 0 ? 0 : errno
    }

    private func pathIdentityMatches(
        _ path: String,
        expected: FileSystemIdentity,
        requireDirectory: Bool
    ) -> Bool {
        FileSystemUtilities.identity(
            atPath: path,
            requireDirectory: requireDirectory
        ) == expected
    }

    private func transactionFailure(
        _ message: String,
        rollbackError: String?
    ) -> String {
        guard let rollbackError, !rollbackError.isEmpty else {
            return message
        }
        return "\(message) Rollback also reported: \(rollbackError)"
    }

    private func architectures(atPath path: String) -> [String]? {
        MachOInspector.architectures(atPath: path)
    }

    private func thinnableArchitecture(
        atPath path: String,
        targetArchitecture: String
    ) -> String? {
        guard let architectures = architectures(atPath: path) else { return nil }
        return ArchitectureUtilities.preferredSlice(
            from: architectures,
            targetArchitecture: targetArchitecture
        )
    }
}
