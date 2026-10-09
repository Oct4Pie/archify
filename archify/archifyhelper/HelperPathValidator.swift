import Darwin
import Foundation

struct ValidatedHelperPath {
    let path: String
    let rootPath: String
    let relativeComponents: [String]
    let identity: FileSystemIdentity
}

struct SecureDirectoryRemover {
    static let partialRemovalMessage =
        "Some files in the language folder could not be removed. The folder was partly removed."

    func remove(_ target: ValidatedHelperPath) -> String? {
        let rootFD = target.rootPath.withCString { pointer in
            Darwin.open(
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootFD >= 0 else {
            return "Unable to open the allowed root safely."
        }
        defer { close(rootFD) }

        guard let parent = openParentDirectory(
            rootFD: rootFD,
            components: target.relativeComponents
        ) else {
            return "Unable to open the target parent safely."
        }
        defer { close(parent.fd) }

        guard FileSystemUtilities.identity(
            atDirectoryFD: parent.fd,
            name: parent.leaf,
            requireDirectory: true
        ) == target.identity else {
            return "The language directory changed before removal."
        }

        let claimedName = ".archify-remove-" + UUID().uuidString
        guard renameEntry(
            directoryFD: parent.fd,
            fromName: parent.leaf,
            toName: claimedName
        ) else {
            if Self.isNotPermitted(errno) {
                return ApplicationThinner.changeNotPermittedMessage
            }
            return "Unable to claim the language directory for safe removal."
        }

        guard FileSystemUtilities.identity(
            atDirectoryFD: parent.fd,
            name: claimedName,
            requireDirectory: true
        ) == target.identity else {
            _ = restoreClaimedDirectory(
                parentFD: parent.fd,
                claimedName: claimedName,
                originalName: parent.leaf
            )
            return "The language directory changed during removal."
        }

        let directoryFD = claimedName.withCString { pointer in
            openat(
                parent.fd,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryFD >= 0,
              FileSystemUtilities.identity(
                ofFileDescriptor: directoryFD,
                requireDirectory: true
              ) == target.identity
        else {
            if directoryFD >= 0 {
                close(directoryFD)
            }
            _ = restoreClaimedDirectory(
                parentFD: parent.fd,
                claimedName: claimedName,
                originalName: parent.leaf
            )
            return "Unable to open the language directory safely."
        }

        var removedEntries = 0
        let removalError = removeContents(
            ofDirectoryFD: directoryFD,
            removedEntries: &removedEntries
        )
        close(directoryFD)

        guard removalError == 0 else {
            _ = restoreClaimedDirectory(
                parentFD: parent.fd,
                claimedName: claimedName,
                originalName: parent.leaf
            )
            // Files deleted before the failure cannot be restored, so only
            // promise that nothing changed when nothing did.
            if removedEntries > 0 {
                return Self.partialRemovalMessage
            }
            if Self.isNotPermitted(removalError) {
                return ApplicationThinner.changeNotPermittedMessage
            }
            return "Failed to remove all files from the language directory."
        }

        guard claimedName.withCString({
            unlinkat(parent.fd, $0, AT_REMOVEDIR)
        }) == 0 else {
            _ = restoreClaimedDirectory(
                parentFD: parent.fd,
                claimedName: claimedName,
                originalName: parent.leaf
            )
            return "Failed to remove the empty language directory."
        }

        return nil
    }

    private func openParentDirectory(
        rootFD: Int32,
        components: [String]
    ) -> (fd: Int32, leaf: String)? {
        guard let leaf = components.last else {
            return nil
        }

        var currentFD = dup(rootFD)
        guard currentFD >= 0 else {
            return nil
        }

        for component in components.dropLast() {
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

    private static func isNotPermitted(_ error: Int32) -> Bool {
        error == EPERM || error == EACCES
    }

    /// Returns 0 on success, otherwise the `errno` of the first failure.
    /// `removedEntries` counts what was deleted before any failure.
    private func removeContents(
        ofDirectoryFD directoryFD: Int32,
        removedEntries: inout Int
    ) -> Int32 {
        let streamFD = dup(directoryFD)
        guard streamFD >= 0,
              let directory = fdopendir(streamFD)
        else {
            let error = errno
            if streamFD >= 0 {
                close(streamFD)
            }
            return error
        }
        defer { closedir(directory) }

        // Never follow a mount point out of the language folder: removal
        // runs as root and must stay on the app's own volume.
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0 else {
            return errno
        }

        while let entry = readdir(directory) {
            let name = directoryEntryName(entry)
            if name == "." || name == ".." {
                continue
            }

            var info = stat()
            let statStatus = name.withCString { pointer in
                fstatat(
                    directoryFD,
                    pointer,
                    &info,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statStatus == 0 else {
                return errno
            }

            guard info.st_dev == directoryInfo.st_dev else {
                return EXDEV
            }

            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                let childFD = name.withCString { pointer in
                    openat(
                        directoryFD,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard childFD >= 0 else {
                    return errno
                }
                // The entry may have been replaced since it was examined.
                var childInfo = stat()
                guard fstat(childFD, &childInfo) == 0,
                      childInfo.st_dev == info.st_dev,
                      childInfo.st_ino == info.st_ino
                else {
                    close(childFD)
                    return EBUSY
                }
                let childError = removeContents(
                    ofDirectoryFD: childFD,
                    removedEntries: &removedEntries
                )
                close(childFD)
                guard childError == 0 else {
                    return childError
                }
                guard name.withCString({
                    unlinkat(directoryFD, $0, AT_REMOVEDIR)
                }) == 0 else {
                    return errno
                }
                removedEntries += 1
            } else {
                guard name.withCString({
                    unlinkat(directoryFD, $0, 0)
                }) == 0 else {
                    return errno
                }
                removedEntries += 1
            }
        }

        return 0
    }

    private func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> String {
        withUnsafePointer(to: entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(
                    ofValue: entry.pointee.d_name
                )
            ) {
                String(cString: $0)
            }
        }
    }

    private func renameEntry(
        directoryFD: Int32,
        fromName: String,
        toName: String
    ) -> Bool {
        fromName.withCString { fromPointer in
            toName.withCString { toPointer in
                renameat(
                    directoryFD,
                    fromPointer,
                    directoryFD,
                    toPointer
                ) == 0
            }
        }
    }

    private func restoreClaimedDirectory(
        parentFD: Int32,
        claimedName: String,
        originalName: String
    ) -> Bool {
        guard FileSystemUtilities.identity(
            atDirectoryFD: parentFD,
            name: originalName
        ) == nil else {
            return false
        }
        return renameEntry(
            directoryFD: parentFD,
            fromName: claimedName,
            toName: originalName
        )
    }
}

struct HelperPathValidator {
    private let fileManager: FileManager
    private let allowedRoots: [String]

    init(allowedDirectories: [String], fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.allowedRoots = allowedDirectories.map {
            URL(fileURLWithPath: $0)
                .standardized
                .resolvingSymlinksInPath()
                .path
        }
    }

    func allowedPath(_ path: String) -> String? {
        validatedTarget(path)?.path
    }

    func applicationPath(_ path: String) -> String? {
        applicationTarget(path)?.path
    }

    func languageResourcePath(_ path: String) -> String? {
        languageResourceTarget(path)?.path
    }

    func applicationTarget(_ path: String) -> ValidatedHelperPath? {
        guard let target = validatedTarget(path),
              URL(fileURLWithPath: target.path)
                .pathExtension
                .lowercased() == "app",
              FileSystemUtilities.identity(
                atPath: target.path,
                requireDirectory: true
              ) == target.identity
        else {
            return nil
        }
        return target
    }

    func languageResourceTarget(_ path: String) -> ValidatedHelperPath? {
        guard let target = validatedTarget(path) else { return nil }

        let url = URL(fileURLWithPath: target.path)
        guard url.pathExtension.lowercased() == "lproj",
              url.lastPathComponent.caseInsensitiveCompare("Base.lproj")
                != .orderedSame,
              url.deletingLastPathComponent().pathComponents.contains(where: {
                   $0.lowercased().hasSuffix(".app")
              }),
              FileSystemUtilities.identity(
                atPath: target.path,
                requireDirectory: true
              ) == target.identity
        else {
            return nil
        }

        return target
    }

    private func validatedTarget(_ path: String) -> ValidatedHelperPath? {
        let candidate = URL(fileURLWithPath: path)
            .standardized
            .path

        for allowedRoot in allowedRoots {
            guard candidate.hasPrefix(allowedRoot + "/") else {
                continue
            }

            let relative = String(
                candidate.dropFirst(allowedRoot.count + 1)
            )
            let components = relative
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({
                      $0 != "." && $0 != ".."
                  }),
                  pathComponentsContainNoSymlinks(
                      rootPath: allowedRoot,
                      components: components
                  ),
                  let identity = FileSystemUtilities.identity(
                    atPath: candidate
                  )
            else {
                return nil
            }

            return ValidatedHelperPath(
                path: candidate,
                rootPath: allowedRoot,
                relativeComponents: components,
                identity: identity
            )
        }

        return nil
    }

    private func pathComponentsContainNoSymlinks(
        rootPath: String,
        components: [String]
    ) -> Bool {
        var current = rootPath
        for component in components {
            current = (current as NSString)
                .appendingPathComponent(component)

            var info = stat()
            let status = current.withCString { pointer in
                lstat(pointer, &info)
            }
            guard status == 0 else {
                return false
            }
            if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                return false
            }
        }
        return true
    }
}
