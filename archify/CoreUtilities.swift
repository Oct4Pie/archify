import Combine
import Darwin
import Foundation

struct FileSystemIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

enum FileSystemUtilities {
    static func identity(
        atPath path: String,
        requireRegularFile: Bool = false,
        requireDirectory: Bool = false
    ) -> FileSystemIdentity? {
        var info = stat()
        let status = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard status == 0 else { return nil }

        let type = info.st_mode & mode_t(S_IFMT)
        if requireRegularFile, type != mode_t(S_IFREG) {
            return nil
        }
        if requireDirectory, type != mode_t(S_IFDIR) {
            return nil
        }

        return FileSystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    static func identity(
        ofFileDescriptor fileDescriptor: Int32,
        requireRegularFile: Bool = false,
        requireDirectory: Bool = false
    ) -> FileSystemIdentity? {
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            return nil
        }

        let type = info.st_mode & mode_t(S_IFMT)
        if requireRegularFile, type != mode_t(S_IFREG) {
            return nil
        }
        if requireDirectory, type != mode_t(S_IFDIR) {
            return nil
        }

        return FileSystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    static func identity(
        atDirectoryFD directoryFD: Int32,
        name: String,
        requireRegularFile: Bool = false,
        requireDirectory: Bool = false
    ) -> FileSystemIdentity? {
        var info = stat()
        let status = name.withCString { pointer in
            fstatat(
                directoryFD,
                pointer,
                &info,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0 else { return nil }

        let type = info.st_mode & mode_t(S_IFMT)
        if requireRegularFile, type != mode_t(S_IFREG) {
            return nil
        }
        if requireDirectory, type != mode_t(S_IFDIR) {
            return nil
        }

        return FileSystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }
}

extension ProcessInfo {
    var machineArchitecture: String {
        // Prefer the physical Mac architecture over the current process
        // architecture. Under Rosetta, uname reports x86_64 even though the
        // user is on an Apple Silicon Mac.
        var arm64Supported: Int32 = 0
        var arm64SupportedSize = MemoryLayout<Int32>.size
        if sysctlbyname(
            "hw.optional.arm64",
            &arm64Supported,
            &arm64SupportedSize,
            nil,
            0
        ) == 0,
        arm64Supported == 1 {
            return "arm64"
        }

        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return identifier
            }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
}

enum MachOUtilities {
    static let magicNumbers: Set<UInt32> = [
        0xFEEDFACE, 0xCEFAEDFE,
        0xFEEDFACF, 0xCFFAEDFE,
        0xCAFEBABE, 0xBEBAFECA,
        0xCAFEBABF, 0xBFBAFECA
    ]

    static func isMachOMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(4))
        let magic = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return magicNumbers.contains(magic)
    }
}

struct MachOSliceInfo: Equatable {
    let architecture: String
    let size: UInt64
}

enum MachOInspector {
    private enum ByteOrder {
        case big
        case little
    }

    private enum HeaderKind {
        case thin(ByteOrder)
        case fat32(ByteOrder)
        case fat64(ByteOrder)
    }

    static func slices(
        atPath path: String,
        fileSize knownFileSize: UInt64? = nil
    ) -> [MachOSliceInfo]? {
        // Inspect the file that was actually opened. O_NONBLOCK keeps a FIFO
        // swapped in for the path from stalling the open.
        let fd = path.withCString { pointer in
            Darwin.open(
                pointer,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
        }
        guard fd >= 0 else {
            return nil
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else {
            close(fd)
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        let prefix = handle.readData(ofLength: 12)
        guard let kind = headerKind(in: prefix) else {
            return nil
        }

        switch kind {
        case .thin(let order):
            guard prefix.count >= 12,
                  let cpuType = readUInt32(prefix, offset: 4, order: order),
                  let cpuSubtype = readUInt32(prefix, offset: 8, order: order)
            else {
                return nil
            }

            let size = knownFileSize ?? UInt64(info.st_size)

            return [
                MachOSliceInfo(
                    architecture: architectureName(
                        cpuType: cpuType,
                        cpuSubtype: cpuSubtype
                    ),
                    size: size
                )
            ]

        case .fat32(let order), .fat64(let order):
            guard prefix.count >= 8,
                  let count = readUInt32(prefix, offset: 4, order: order),
                  count > 0,
                  count <= 64
            else {
                return nil
            }

            let is64Bit: Bool
            if case .fat64 = kind {
                is64Bit = true
            } else {
                is64Bit = false
            }
            let entrySize = is64Bit ? 32 : 20
            let headerSize = 8 + Int(count) * entrySize

            try? handle.seek(toOffset: 0)
            let header = handle.readData(ofLength: headerSize)
            guard header.count >= headerSize else {
                return nil
            }

            var slices: [MachOSliceInfo] = []
            slices.reserveCapacity(Int(count))

            for index in 0..<Int(count) {
                let base = 8 + index * entrySize
                guard let cpuType = readUInt32(
                    header,
                    offset: base,
                    order: order
                ),
                let cpuSubtype = readUInt32(
                    header,
                    offset: base + 4,
                    order: order
                )
                else {
                    return nil
                }

                let size: UInt64?
                if is64Bit {
                    size = readUInt64(
                        header,
                        offset: base + 16,
                        order: order
                    )
                } else {
                    size = readUInt32(
                        header,
                        offset: base + 12,
                        order: order
                    ).map(UInt64.init)
                }

                guard let size else {
                    return nil
                }

                slices.append(
                    MachOSliceInfo(
                        architecture: architectureName(
                            cpuType: cpuType,
                            cpuSubtype: cpuSubtype
                        ),
                        size: size
                    )
                )
            }

            return slices
        }
    }

    static func architectures(
        atPath path: String,
        fileSize: UInt64? = nil
    ) -> [String]? {
        guard let slices = slices(atPath: path, fileSize: fileSize) else {
            return nil
        }
        let architectures = slices.map(\.architecture)
        return architectures.isEmpty ? nil : architectures
    }

    static func architectureSizes(
        atPath path: String,
        fileSize: UInt64? = nil
    ) -> [String: UInt64]? {
        guard let slices = slices(atPath: path, fileSize: fileSize) else {
            return nil
        }

        var result: [String: UInt64] = [:]
        for slice in slices {
            result[slice.architecture, default: 0] += slice.size
        }
        return result.isEmpty ? nil : result
    }

    private static func headerKind(in data: Data) -> HeaderKind? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))

        switch bytes {
        case [0xFE, 0xED, 0xFA, 0xCE],
             [0xFE, 0xED, 0xFA, 0xCF]:
            return .thin(.big)
        case [0xCE, 0xFA, 0xED, 0xFE],
             [0xCF, 0xFA, 0xED, 0xFE]:
            return .thin(.little)
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            return .fat32(.big)
        case [0xBE, 0xBA, 0xFE, 0xCA]:
            return .fat32(.little)
        case [0xCA, 0xFE, 0xBA, 0xBF]:
            return .fat64(.big)
        case [0xBF, 0xBA, 0xFE, 0xCA]:
            return .fat64(.little)
        default:
            return nil
        }
    }

    private static func architectureName(
        cpuType: UInt32,
        cpuSubtype: UInt32
    ) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF

        switch cpuType {
        case 7:
            return "i386"
        case 0x0100_0007:
            switch subtype {
            case 3:
                return "x86_64"
            case 8:
                return "x86_64h"
            default:
                return "x86_64_subtype_\(subtype)"
            }
        case 12:
            return "arm"
        case 0x0100_000C:
            switch subtype {
            case 0, 1:
                return "arm64"
            case 2:
                return "arm64e"
            case 12:
                return "arm64e.x1"
            default:
                return "arm64_subtype_\(subtype)"
            }
        case 0x0200_000C:
            return "arm64_32"
        case 18:
            return "ppc"
        case 0x0100_0012:
            return "ppc64"
        default:
            return "cpu_\(cpuType)_subtype_\(subtype)"
        }
    }

    private static func readUInt32(
        _ data: Data,
        offset: Int,
        order: ByteOrder
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else {
            return nil
        }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        switch order {
        case .big:
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        case .little:
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        }
    }

    private static func readUInt64(
        _ data: Data,
        offset: Int,
        order: ByteOrder
    ) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else {
            return nil
        }
        let bytes = [UInt8](data[offset..<(offset + 8)])

        switch order {
        case .big:
            return bytes.reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        case .little:
            return bytes.reversed().reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        }
    }
}

enum ArchitectureUtilities {
    static func appType(for architectures: [String], hostArchitecture: String) -> String {
        guard !architectures.isEmpty else { return "Unknown" }
        guard architectures.count == 1, let architecture = architectures.first else {
            return "Universal"
        }

        if architecture == hostArchitecture {
            return "Native"
        }

        switch architecture {
        case "x86_64", "x86_64h", "i386":
            return "Intel"
        case "arm64", "arm64e", "arm64e.x1":
            return "Apple Silicon"
        default:
            return "Other"
        }
    }

    static func preferredSlice(from architectures: [String], targetArchitecture: String) -> String? {
        guard architectures.count > 1 else { return nil }

        if architectures.contains(targetArchitecture) {
            return targetArchitecture
        }

        if targetArchitecture == "arm64", architectures.contains("arm64e") {
            return "arm64e"
        }

        if targetArchitecture == "arm64",
           architectures.contains("arm64e.x1") {
            return "arm64e.x1"
        }

        if targetArchitecture == "arm64e", architectures.contains("arm64") {
            return "arm64"
        }

        if targetArchitecture == "arm64e",
           architectures.contains("arm64e.x1") {
            return "arm64e.x1"
        }

        if targetArchitecture == "x86_64",
           architectures.contains("x86_64h") {
            return "x86_64h"
        }

        if ["arm64", "arm64e"].contains(targetArchitecture),
           architectures.contains("x86_64") {
            return "x86_64"
        }

        return nil
    }

    static func executableSupportsHost(
        architectures: [String],
        hostArchitecture: String
    ) -> Bool {
        architectures.contains(hostArchitecture)
    }

    static func removableSize(
        architectureSizes: [String: UInt64],
        targetArchitecture: String
    ) -> UInt64 {
        guard let keptArchitecture = preferredSlice(
            from: Array(architectureSizes.keys),
            targetArchitecture: targetArchitecture
        ) else {
            return 0
        }

        return architectureSizes
            .filter { $0.key != keptArchitecture }
            .reduce(0) { $0 + $1.value }
    }
}

enum HelperVersionUtilities {
    static func isNumericBundleVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func needsRefresh(installedVersion: String?, bundledVersion: String?) -> Bool {
        guard let bundledVersion,
              isNumericBundleVersion(bundledVersion),
              let installedVersion,
              isNumericBundleVersion(installedVersion)
        else {
            return true
        }

        return installedVersion.compare(bundledVersion, options: .numeric) == .orderedAscending
    }
}

enum StorageUtilities {
    static func savedSpace(originalSize: UInt64, newSize: UInt64) -> UInt64 {
        originalSize > newSize ? originalSize - newSize : 0
    }

    static func savedPercentage(
        originalSize: UInt64,
        newSize: UInt64
    ) -> Double {
        guard originalSize > 0, originalSize > newSize else {
            return 0
        }
        return Double(originalSize - newSize)
            / Double(originalSize)
            * 100
    }
}

/// Apps that Optimize Apps changed in place, so that an app that has since
/// updated itself, and with that put back the code for other Macs, can be
/// pointed out. Stored only on this Mac, in Archify's preferences.
struct OptimizationHistory {
    struct Update: Equatable {
        let path: String
        let previousVersion: String?
        let currentVersion: String?
    }

    private static let key = "OptimizedApps"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ appPath: String) {
        guard let bundleID = Self.bundleID(of: appPath) else { return }
        var records = storedRecords()
        records[appPath] = [
            "bundleID": bundleID,
            "version": Self.version(of: appPath) ?? ""
        ]
        defaults.set(records, forKey: Self.key)
    }

    /// Previously optimized apps among `scannedPaths`, the apps that have
    /// removable code again. An app replaced by a different one at the same
    /// path is not included. Records of apps that are gone are dropped.
    func updates(among scannedPaths: [String]) -> [Update] {
        var records = storedRecords()
        let missing = records.keys.filter {
            !FileManager.default.fileExists(atPath: $0)
        }
        if !missing.isEmpty {
            missing.forEach { records.removeValue(forKey: $0) }
            defaults.set(records, forKey: Self.key)
        }

        return scannedPaths.compactMap { path in
            guard let record = records[path],
                  record["bundleID"] == Self.bundleID(of: path)
            else {
                return nil
            }
            let previous = record["version"].flatMap { $0.isEmpty ? nil : $0 }
            return Update(
                path: path,
                previousVersion: previous,
                currentVersion: Self.version(of: path)
            )
        }
    }

    var isEmpty: Bool {
        storedRecords().isEmpty
    }

    private func storedRecords() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:]
    }

    private static func infoValue(_ key: String, of appPath: String) -> String? {
        let path = (appPath as NSString)
            .appendingPathComponent("Contents/Info.plist")
        // Apps can be changed by others: read only a regular file of
        // reasonable size, and never wait on a FIFO in its place.
        let fd = path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size <= 4 * 1024 * 1024
        else {
            return nil
        }
        guard let data = try? handle.readToEnd(),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any]
        else {
            return nil
        }
        return plist[key] as? String
    }

    private static func bundleID(of appPath: String) -> String? {
        infoValue("CFBundleIdentifier", of: appPath)
    }

    private static func version(of appPath: String) -> String? {
        infoValue("CFBundleShortVersionString", of: appPath)
            ?? infoValue("CFBundleVersion", of: appPath)
    }
}

/// Pause, resume, and cancel for long-running work. Every change Archify
/// makes to an app is all-or-nothing, so pausing and canceling take effect
/// between items: the item in progress always finishes.
///
/// Background loops call `checkpoint()`, which blocks while paused.
/// Main-thread step chains call `proceed(_:orStop:)`, which holds the next
/// step until `resume()`. Control methods are called on the main thread.
final class RunControl: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case paused
        /// Canceled; the item in progress is finishing.
        case stopping
    }

    @Published private(set) var state: State = .idle

    /// A control that never runs, for views that show no controls.
    static let inactive = RunControl()

    private let condition = NSCondition()
    private var paused = false
    private var canceled = false
    private var heldStep: (() -> Void)?

    var isCanceled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return canceled
    }

    func begin() {
        condition.lock()
        paused = false
        canceled = false
        condition.unlock()
        heldStep = nil
        state = .running
    }

    func finish() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
        heldStep = nil
        state = .idle
    }

    func pause() {
        guard state == .running else { return }
        condition.lock()
        paused = true
        condition.unlock()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
        state = .running
        releaseHeldStep()
    }

    func cancel() {
        guard state == .running || state == .paused else { return }
        condition.lock()
        canceled = true
        paused = false
        condition.broadcast()
        condition.unlock()
        state = .stopping
        releaseHeldStep()
    }

    /// For background loops: waits while paused. Returns false once
    /// canceled, meaning the loop should stop before its next item.
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !canceled {
            condition.wait()
        }
        return !canceled
    }

    /// For main-thread step chains: runs `next` now, holds it until
    /// `resume()` while paused, or runs `stop` instead once canceled.
    func proceed(_ next: @escaping () -> Void, orStop stop: @escaping () -> Void) {
        condition.lock()
        let isCanceled = canceled
        let isPaused = paused
        condition.unlock()

        if isCanceled {
            stop()
        } else if isPaused {
            heldStep = { [weak self] in self?.proceed(next, orStop: stop) }
        } else {
            next()
        }
    }

    private func releaseHeldStep() {
        let step = heldStep
        heldStep = nil
        step?()
    }
}
