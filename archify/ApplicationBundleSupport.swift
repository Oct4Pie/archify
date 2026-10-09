import Darwin
import Compression
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

        // Copy into a private folder Archify creates, then move the result
        // into place only if nothing exists there yet. A failed copy never
        // touches, or cleans up, anything Archify did not create. That folder
        // could be swapped out if other users can change the destination.
        guard let realOutputRoot = realpath(outputRootURL.path, nil) else {
            throw copyError(2, "Output directory does not exist.")
        }
        let trustedOutputRoot = String(cString: realOutputRoot)
        free(realOutputRoot)
        guard ApplicationThinner.isTrustedDirectory(trustedOutputRoot) else {
            throw copyError(
                10,
                "Choose a destination folder that other users can't change."
            )
        }
        // From here on use only the folder that was checked.
        let checkedRootURL = URL(fileURLWithPath: trustedOutputRoot, isDirectory: true)
        let checkedOutputURL = checkedRootURL.appendingPathComponent(
            outputName,
            isDirectory: true
        )
        let stagingURL = checkedRootURL.appendingPathComponent(
            ".archify-copy-" + UUID().uuidString,
            isDirectory: true
        )
        guard mkdir(stagingURL.path, 0o700) == 0 else {
            throw copyError(
                8,
                "Unable to prepare the destination folder for copying."
            )
        }
        defer { try? fileManager.removeItem(at: stagingURL) }
        let stagedURL = stagingURL.appendingPathComponent(
            outputName,
            isDirectory: true
        )

        let process = Process()
        process.executableURL = dittoURL
        process.arguments = [
            "--rsrc",
            "--extattr",
            "--acl",
            inputURL.path,
            stagedURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DITTOABORT"] = "1"
        process.environment = environment

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        // Drain stderr before waiting so a full pipe cannot stall ditto.
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            atPath: stagedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw copyError(
                5,
                "Copy completed without a valid destination app bundle."
            )
        }

        let renameStatus = stagedURL.path.withCString { from in
            checkedOutputURL.path.withCString { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard renameStatus == 0 else {
            if errno == EEXIST {
                throw copyError(
                    4,
                    "An application with the same name already exists at the destination."
                )
            }
            throw copyError(
                9,
                "Unable to move the copied app into place."
            )
        }

        return checkedOutputURL.path
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
    private let compressBinaries: Bool
    /// Where transactions are staged instead of beside the app. The
    /// privileged helper passes a directory only root can change, so no other
    /// process can redirect the files it writes; it then also requires the
    /// app path to be the app's real path.
    private let stagingDirectory: URL?
    private let thinningQueue = DispatchQueue(
        label: "com.oct4pie.archify.thinning",
        qos: .userInitiated
    )

    init(
        fileManager: FileManager = .default,
        lipoURL: URL = URL(fileURLWithPath: "/usr/bin/lipo"),
        compressBinaries: Bool = true,
        stagingDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.lipoURL = lipoURL
        self.compressBinaries = compressBinaries
        self.stagingDirectory = stagingDirectory
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

        // Opening follows links in the folders above the app. With trusted
        // staging, insist the app really lives at the path that was checked.
        if stagingDirectory != nil,
           Self.realPath(ofFileDescriptor: appDirectoryFD) != appPath {
            completion(nil, "The application path is not a stable directory.")
            return
        }

        guard let transactionDirectory = createTransactionDirectory(
            forApplicationPath: appPath
        ) else {
            completion(nil, "Failed to create a thinning transaction directory.")
            return
        }

        let transactionFD = openDirectoryNoFollow(
            atPath: transactionDirectory.path
        )
        guard transactionFD >= 0,
              // Binaries are swapped in place, which needs one volume.
              FileSystemUtilities.identity(
                ofFileDescriptor: transactionFD,
                requireDirectory: true
              )?.device == appIdentity.device
        else {
            if transactionFD >= 0 {
                close(transactionFD)
            }
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
                    appDirectoryFD: appDirectoryFD,
                    transactionDirectory: transactionDirectory,
                    transactionFD: transactionFD
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
        appDirectoryFD: Int32,
        transactionDirectory: URL,
        transactionFD: Int32
    ) -> (replacement: PreparedReplacement?, error: String?) {
        // Read the binary only through a descriptor opened without following
        // links inside the app, and run lipo on a private clone of it. If a
        // folder in the app is swapped mid-way, Archify still never reads,
        // or copies ownership from, a file outside the app.
        let originalFD = openEntry(
            relativePath: relativePath,
            under: appDirectoryFD
        )
        guard originalFD >= 0 else {
            return (nil, "A binary changed before it could be prepared.")
        }
        defer { close(originalFD) }
        guard let originalIdentity = FileSystemUtilities.identity(
            ofFileDescriptor: originalFD,
            requireRegularFile: true
        ) else {
            return (nil, "A binary changed before it could be prepared.")
        }

        let token = UUID().uuidString
        let sourceName = "source-\(token)"
        let preparedName = "prepared-\(token)"
        guard cloneFile(originalFD, into: transactionFD, name: sourceName) else {
            return (nil, "Failed to stage a binary for thinning.")
        }
        defer {
            _ = unlinkEntry(
                directoryFD: transactionFD,
                name: sourceName,
                removeDirectory: false
            )
        }

        func discard(_ message: String) -> (replacement: PreparedReplacement?, error: String?) {
            _ = unlinkEntry(
                directoryFD: transactionFD,
                name: preparedName,
                removeDirectory: false
            )
            return (nil, message)
        }

        let sourcePath = transactionDirectory
            .appendingPathComponent(sourceName).path
        let preparedPath = transactionDirectory
            .appendingPathComponent(preparedName).path
        let process = Process()
        process.executableURL = lipoURL
        process.arguments = [sourcePath, "-thin", architecture, "-output", preparedPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let errorOutput: Data
        do {
            try process.run()
            // Drain stderr before waiting so a full pipe cannot stall lipo.
            errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return discard("Failed to launch the system architecture tool.")
        }

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                NSLog("lipo failed for %@: %@", path, detail)
            }
            return discard("Failed to thin one or more binaries in the application.")
        }

        guard architectures(atPath: preparedPath) == [architecture] else {
            return discard("The thinned binary failed architecture validation.")
        }

        guard copyMetadata(
            from: originalFD,
            toEntry: preparedName,
            in: transactionFD
        ) else {
            NSLog("Failed to copy metadata for %@", path)
            return discard("Failed to preserve binary metadata while thinning.")
        }

        // Compress last: copying metadata from an uncompressed file onto a
        // compressed one clears its flag and leaves it reading as empty.
        if compressBinaries,
           TransparentCompression.compressFile(atPath: preparedPath) == .damaged {
            return discard("Failed to compress a thinned binary.")
        }

        guard entryIdentity(
            relativePath: relativePath,
            under: appDirectoryFD
        ) == originalIdentity else {
            return discard("A binary changed while it was being prepared.")
        }

        guard let preparedIdentity = FileSystemUtilities.identity(
            atDirectoryFD: transactionFD,
            name: preparedName,
            requireRegularFile: true
        ) else {
            return discard("The prepared binary is not a stable regular file.")
        }

        return (
            PreparedReplacement(
                originalPath: path,
                relativePath: relativePath,
                preparedPath: preparedPath,
                preparedName: preparedName,
                originalIdentity: originalIdentity,
                preparedIdentity: preparedIdentity
            ),
            nil
        )
    }

    /// Opens a file inside the app for reading without following any link.
    private func openEntry(relativePath: String, under rootFD: Int32) -> Int32 {
        guard let parent = openParentDirectory(
            rootFD: rootFD,
            relativePath: relativePath
        ) else {
            return -1
        }
        defer { close(parent.fd) }
        // O_NONBLOCK keeps a FIFO swapped in for the entry from stalling the
        // open; only regular files are returned.
        let fd = parent.leaf.withCString { pointer in
            openat(
                parent.fd,
                pointer,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
        }
        guard fd >= 0 else {
            return -1
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else {
            close(fd)
            return -1
        }
        return fd
    }

    private func entryIdentity(
        relativePath: String,
        under rootFD: Int32
    ) -> FileSystemIdentity? {
        guard let parent = openParentDirectory(
            rootFD: rootFD,
            relativePath: relativePath
        ) else {
            return nil
        }
        defer { close(parent.fd) }
        return FileSystemUtilities.identity(
            atDirectoryFD: parent.fd,
            name: parent.leaf,
            requireRegularFile: true
        )
    }

    /// Clones a file into the transaction directory, or copies it on volumes
    /// that cannot clone.
    private func cloneFile(
        _ sourceFD: Int32,
        into directoryFD: Int32,
        name: String
    ) -> Bool {
        if name.withCString({ fclonefileat(sourceFD, directoryFD, $0, 0) }) == 0 {
            return true
        }
        let destinationFD = name.withCString { pointer in
            openat(
                directoryFD,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard destinationFD >= 0 else {
            return false
        }
        defer { close(destinationFD) }
        if fcopyfile(sourceFD, destinationFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 {
            return true
        }
        _ = unlinkEntry(directoryFD: directoryFD, name: name, removeDirectory: false)
        return false
    }

    private func copyMetadata(
        from sourceFD: Int32,
        toEntry name: String,
        in directoryFD: Int32
    ) -> Bool {
        let destinationFD = name.withCString { pointer in
            openat(directoryFD, pointer, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard destinationFD >= 0 else {
            return false
        }
        defer { close(destinationFD) }
        return fcopyfile(
            sourceFD,
            destinationFD,
            nil,
            copyfile_flags_t(COPYFILE_METADATA)
        ) == 0
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
        let parent: URL
        if let stagingDirectory {
            guard Self.prepareTrustedDirectory(stagingDirectory) else {
                NSLog(
                    "Refusing untrusted staging directory %@",
                    stagingDirectory.path
                )
                return nil
            }
            parent = stagingDirectory
        } else {
            parent = URL(fileURLWithPath: appPath, isDirectory: true)
                .deletingLastPathComponent()
        }
        let directory = parent
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

    /// Creates `directory` if needed and confirms that only this user or root
    /// can change it or any directory above it, so no other process can swap
    /// it for a link while files are staged there.
    static func prepareTrustedDirectory(_ directory: URL) -> Bool {
        let path = directory.standardized.path
        guard path.hasPrefix("/") else {
            return false
        }
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            return false
        }
        return isTrustedDirectory(path, requirePrivate: true)
    }

    /// Whether no one but this user and administrators can add, remove or
    /// rename entries in `path` or any folder above it, so a name Archify
    /// creates there cannot be swapped out. Sticky folders such as /tmp qualify,
    /// since others cannot rename what they don't own. `requirePrivate`
    /// also requires the folder itself to be owned by this user and closed
    /// to everyone else. `path` must be absolute and free of links.
    static func isTrustedDirectory(_ path: String, requirePrivate: Bool = false) -> Bool {
        guard path.hasPrefix("/") else {
            return false
        }
        let user = geteuid()
        var current = ""
        let components = [""] + path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current = index == 0 ? "/" : (current as NSString)
                .appendingPathComponent(component)
            var info = stat()
            guard lstat(current, &info) == 0,
                  // Rejects symbolic links as well.
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == user
            else {
                return false
            }
            guard !Self.aclAllowsOthersToChange(current) else {
                return false
            }
            if requirePrivate, index == components.count - 1 {
                guard info.st_uid == user, info.st_mode & 0o077 == 0 else {
                    return false
                }
            } else if info.st_mode & S_ISVTX == 0,
                      info.st_mode & 0o002 != 0
                        || (info.st_mode & 0o020 != 0
                            && !Self.privilegedGroups.contains(info.st_gid)) {
                return false
            }
        }
        return true
    }

    /// wheel and admin: their members can already act as root, so a folder
    /// they can change, such as /Applications, is no less safe.
    private static let privilegedGroups: Set<gid_t> = [0, 80]

    /// Whether an access control list lets anyone add, remove or rename
    /// entries in the directory, or change its permissions or owner. Deny
    /// entries, such as the one macOS puts on "/", are harmless.
    private static func aclAllowsOthersToChange(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            // No ACL, or one that cannot be read.
            return errno != ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        let risky: [acl_perm_t] = [
            ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE,
            ACL_WRITE_SECURITY, ACL_CHANGE_OWNER
        ]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0 else {
                return true
            }
            guard tag == ACL_EXTENDED_ALLOW else {
                continue
            }
            guard acl_get_permset(current, &permissions) == 0,
                  let permissions
            else {
                return true
            }
            if risky.contains(where: { acl_get_perm_np(permissions, $0) == 1 }) {
                return true
            }
        }
        return false
    }

    static func realPath(ofFileDescriptor fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
            return nil
        }
        return String(cString: buffer)
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

/// macOS transparent file compression (decmpfs), the format Apple's installers
/// use for app bundles. The file keeps its exact contents when read, so code
/// signatures are unaffected; only its size on disk changes.
enum TransparentCompression {
    enum Outcome: Equatable {
        /// The file is compressed and reads back identically.
        case compressed
        /// The file was left as it was (unsupported, too small to gain, or
        /// compression failed cleanly).
        case unchanged
        /// Compression failed and the original contents could not be
        /// restored. The file must not be used.
        case damaged
    }

    private static let chunkSize = 64 * 1024
    /// LZFSE chunks stored in the resource fork.
    private static let lzfseResourceForkType: UInt32 = 12
    private static let resourceForkName = "com.apple.ResourceFork"
    private static let headerName = "com.apple.decmpfs"
    private static let compressedFlag = UInt32(UF_COMPRESSED)

    static func isCompressed(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & compressedFlag != 0
    }

    /// Compresses a regular file in place, then reads it back and compares it
    /// with the original bytes. Only use this after every other metadata
    /// change: copying flags from an uncompressed file onto a compressed one
    /// leaves it reading as empty.
    @discardableResult
    static func compressFile(atPath path: String) -> Outcome {
        // Opening a compressed file for writing decompresses it.
        guard !isCompressed(atPath: path) else { return .unchanged }
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unchanged }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & compressedFlag == 0,
              // Other links would change too.
              info.st_nlink == 1,
              info.st_size > 0,
              // Chunk offsets are 32-bit.
              info.st_size < Int64(UInt32.max / 2),
              // Compression stores its data in these attributes, so an
              // existing resource fork would be overwritten.
              !hasAttribute(fd, resourceForkName),
              !hasAttribute(fd, headerName)
        else {
            return .unchanged
        }

        let size = Int(info.st_size)
        var original = [UInt8](repeating: 0, count: size)
        guard readFully(fd, into: &original),
              let fork = resourceFork(for: original),
              // Worth it only when at least one disk block is saved.
              fork.count + 4096 <= size
        else {
            return .unchanged
        }

        var header = [UInt8]("fpmc".utf8)
        withUnsafeBytes(of: lzfseResourceForkType.littleEndian) { header += $0 }
        withUnsafeBytes(of: UInt64(size).littleEndian) { header += $0 }

        // XATTR_CREATE never replaces an attribute that appeared since the
        // check; on failure only the attributes created here are removed.
        let create = XATTR_SHOWCOMPRESSION | XATTR_CREATE
        guard fsetxattr(fd, resourceForkName, fork, fork.count, 0, create) == 0 else {
            return .unchanged
        }
        guard fsetxattr(fd, headerName, header, header.count, 0, create) == 0 else {
            fremovexattr(fd, resourceForkName, XATTR_SHOWCOMPRESSION)
            return .unchanged
        }

        guard ftruncate(fd, 0) == 0 else {
            removeCompressionAttributes(fd)
            return .unchanged
        }

        guard fchflags(fd, info.st_flags | compressedFlag) == 0 else {
            return restore(fd, path: path, original: original, info: info)
        }
        restoreTimes(fd, info: info)

        guard contents(atPath: path) == original else {
            return restore(fd, path: path, original: original, info: info)
        }
        return .compressed
    }

    /// Anything but a clear "no such attribute" counts as present.
    private static func hasAttribute(_ fd: Int32, _ name: String) -> Bool {
        fgetxattr(fd, name, nil, 0, 0, XATTR_SHOWCOMPRESSION) >= 0
            || errno != ENOATTR
    }

    private static func resourceFork(for data: [UInt8]) -> [UInt8]? {
        let chunkCount = (data.count + chunkSize - 1) / chunkSize
        let tableSize = (chunkCount + 1) * MemoryLayout<UInt32>.size
        var fork = [UInt8](repeating: 0, count: tableSize)
        fork.reserveCapacity(tableSize + data.count / 2)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: compression_encode_scratch_buffer_size(COMPRESSION_LZFSE),
            alignment: 16
        )
        defer { scratch.deallocate() }
        // LZFSE stores incompressible input raw with a small header.
        var encoded = [UInt8](repeating: 0, count: chunkSize + 1024)
        var offsets: [UInt32] = []

        for index in 0..<chunkCount {
            let start = index * chunkSize
            let length = min(chunkSize, data.count - start)
            let encodedLength = data.withUnsafeBufferPointer { source in
                encoded.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!,
                        destination.count,
                        source.baseAddress! + start,
                        length,
                        scratch,
                        COMPRESSION_LZFSE
                    )
                }
            }
            guard encodedLength > 0 else { return nil }
            offsets.append(UInt32(fork.count))
            fork += encoded[0..<encodedLength]
        }
        offsets.append(UInt32(fork.count))

        for (index, offset) in offsets.enumerated() {
            withUnsafeBytes(of: offset.littleEndian) { bytes in
                fork.replaceSubrange(index * 4..<index * 4 + 4, with: bytes)
            }
        }
        return fork
    }

    /// Puts the original bytes back after a failed attempt.
    private static func restore(
        _ fd: Int32,
        path: String,
        original: [UInt8],
        info: stat
    ) -> Outcome {
        NSLog("Transparent compression failed for %@; restoring.", path)
        guard fchflags(fd, info.st_flags & ~compressedFlag) == 0 else {
            return .damaged
        }
        removeCompressionAttributes(fd)
        guard ftruncate(fd, 0) == 0,
              writeFully(fd, original)
        else {
            return .damaged
        }
        restoreTimes(fd, info: info)
        return contents(atPath: path) == original ? .unchanged : .damaged
    }

    private static func removeCompressionAttributes(_ fd: Int32) {
        _ = fremovexattr(fd, headerName, XATTR_SHOWCOMPRESSION)
        _ = fremovexattr(fd, resourceForkName, XATTR_SHOWCOMPRESSION)
    }

    private static func restoreTimes(_ fd: Int32, info: stat) {
        var times = [info.st_atimespec, info.st_mtimespec]
        _ = futimens(fd, &times)
    }

    /// Reads through a fresh descriptor so the kernel decompresses the file.
    private static func contents(atPath path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        return readFully(fd, into: &buffer) ? buffer : nil
    }

    private static func readFully(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes in
                pread(fd, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private static func writeFully(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                pwrite(fd, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}
