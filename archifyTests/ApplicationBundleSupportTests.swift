import Foundation
import XCTest

final class ApplicationCopierTests: XCTestCase {
    private var sandboxURL: URL!
    private var sourceURL: URL!
    private var outputURL: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-copy-\(UUID().uuidString)", isDirectory: true)
        sourceURL = sandboxURL.appendingPathComponent("Source.app", isDirectory: true)
        outputURL = sandboxURL.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        try Data("payload".utf8).write(
            to: sourceURL.appendingPathComponent("Contents/MacOS/Runner")
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testCopiesApplicationBundleAndRefusesDestinationCollision() throws {
        let copier = ApplicationCopier()
        let copiedPath = try copier.copyApplication(
            from: sourceURL.path,
            toDirectory: outputURL.path
        )
        let copiedURL = URL(fileURLWithPath: copiedPath, isDirectory: true)

        XCTAssertEqual(copiedURL.lastPathComponent, "Source.app")
        XCTAssertEqual(
            try Data(contentsOf: copiedURL.appendingPathComponent("Contents/MacOS/Runner")),
            Data("payload".utf8)
        )
        XCTAssertThrowsError(
            try copier.copyApplication(
                from: sourceURL.path,
                toDirectory: outputURL.path
            )
        )
    }

    func testKeepBothSavesUnderANewNameWithoutTouchingTheExistingCopy() throws {
        let copier = ApplicationCopier()
        let first = try copier.copyApplication(from: sourceURL.path, toDirectory: outputURL.path)
        let marker = URL(fileURLWithPath: first).appendingPathComponent("Contents/marker")
        try Data("existing".utf8).write(to: marker)

        let second = try copier.copyApplication(
            from: sourceURL.path,
            toDirectory: outputURL.path,
            named: "Source 2.app"
        )

        XCTAssertEqual(URL(fileURLWithPath: second).lastPathComponent, "Source 2.app")
        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
        XCTAssertThrowsError(
            try copier.copyApplication(
                from: sourceURL.path,
                toDirectory: outputURL.path,
                named: "Source 2.app"
            )
        )
    }

    func testRejectsInvalidNamesAndDestinationsInsideTheApp() throws {
        let copier = ApplicationCopier()
        for name in ["Source", "../Escape.app", ".app"] {
            XCTAssertThrowsError(
                try copier.copyApplication(
                    from: sourceURL.path,
                    toDirectory: outputURL.path,
                    named: name
                ),
                name
            )
        }
        XCTAssertThrowsError(
            try copier.copyApplication(
                from: sourceURL.path,
                toDirectory: sourceURL.appendingPathComponent("Contents").path
            )
        )
    }

    func testFailedCopyRemovesPartialDestination() throws {
        let fakeDitto = sandboxURL.appendingPathComponent("fake-ditto")
        let script = """
        #!/bin/sh
        for arg in "$@"; do dest="$arg"; done
        mkdir -p "$dest"
        echo partial > "$dest/partial"
        echo "simulated ditto failure" >&2
        exit 42
        """
        try script.write(to: fakeDitto, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeDitto.path
        )

        let copier = ApplicationCopier(dittoURL: fakeDitto)
        XCTAssertThrowsError(
            try copier.copyApplication(
                from: sourceURL.path,
                toDirectory: outputURL.path
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outputURL.appendingPathComponent("Source.app").path
            )
        )
    }
}

final class ApplicationDiscoveryTests: XCTestCase {
    private var sandboxURL: URL!
    private var systemRoot: URL!
    private var userRoot: URL!
    private var outsideRoot: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-discovery-\(UUID().uuidString)", isDirectory: true)
        systemRoot = sandboxURL.appendingPathComponent("Applications", isDirectory: true)
        userRoot = sandboxURL.appendingPathComponent("UserApplications", isDirectory: true)
        outsideRoot = sandboxURL.appendingPathComponent("Outside", isDirectory: true)

        for directory in [systemRoot!, userRoot!, outsideRoot!] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testDiscoversAppsAcrossRootsAndOneGroupingLevelDeterministically() throws {
        let direct = systemRoot.appendingPathComponent("Zulu.app", isDirectory: true)
        let group = systemRoot.appendingPathComponent("Vendor", isDirectory: true)
        let grouped = group.appendingPathComponent("Alpha.app", isDirectory: true)
        let user = userRoot.appendingPathComponent("User.app", isDirectory: true)
        let deep = systemRoot
            .appendingPathComponent("Deep/Another/TooDeep.app", isDirectory: true)
        let hidden = systemRoot.appendingPathComponent(".Hidden.app", isDirectory: true)

        for app in [direct, grouped, user, deep, hidden] {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        }

        let discovery = ApplicationDiscovery()
        let paths = discovery.discoverApplicationPaths(in: [systemRoot, userRoot])

        XCTAssertEqual(
            paths,
            [
                grouped.standardized.path,
                direct.standardized.path,
                user.standardized.path
            ].sorted()
        )
    }

    func testRejectsSymlinkedAppsThatEscapeARoot() throws {
        let outsideApp = outsideRoot.appendingPathComponent("Escape.app", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideApp, withIntermediateDirectories: true)

        let symlink = systemRoot.appendingPathComponent("Escape.app")
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: outsideApp.path
        )

        let paths = ApplicationDiscovery()
            .discoverApplicationPaths(in: [systemRoot])
        XCTAssertTrue(paths.isEmpty)
    }

    func testDuplicateRootsDoNotDuplicateApps() throws {
        let app = systemRoot.appendingPathComponent("Only.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let paths = ApplicationDiscovery()
            .discoverApplicationPaths(in: [systemRoot, systemRoot])
        XCTAssertEqual(paths, [app.standardized.path])
    }
}

final class LanguageResourceDiscoveryTests: XCTestCase {
    private var sandboxURL: URL!
    private var appURL: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-languages-\(UUID().uuidString)", isDirectory: true)
        appURL = sandboxURL.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testFindsCanonicalLanguageDirectoriesInsideApp() throws {
        let english = appURL
            .appendingPathComponent("Contents/Resources/en.lproj", isDirectory: true)
        let french = appURL
            .appendingPathComponent("Contents/Frameworks/Nested.framework/Resources/fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: english,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: french,
            withIntermediateDirectories: true
        )

        let resources = LanguageResourceDiscovery()
            .languageResources(inApplication: appURL.path)

        XCTAssertEqual(
            resources["en"],
            [english.standardized.resolvingSymlinksInPath().path]
        )
        XCTAssertEqual(
            resources["fr"],
            [french.standardized.resolvingSymlinksInPath().path]
        )
    }

    func testOffersOnlyLanguageFoldersTheSignatureLetsGo() throws {
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        for language in ["fr", "de"] {
            let folder = resourcesURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        // fr is sealed as optional (the default for .lproj), de as required.
        let seal: [String: Any] = [
            "files2": [
                "Resources/fr.lproj/Localizable.strings": [
                    "hash2": Data(count: 32),
                    "optional": true
                ],
                "Resources/de.lproj/Localizable.strings": [
                    "hash2": Data(count: 32)
                ]
            ]
        ]
        let signatureURL = appURL.appendingPathComponent("Contents/_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: signatureURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: seal, format: .xml, options: 0)
            .write(to: signatureURL.appendingPathComponent("CodeResources"))

        let resources = LanguageResourceDiscovery()
            .languageResources(inApplication: appURL.path)

        XCTAssertNotNil(resources["fr"])
        XCTAssertNil(resources["de"])
    }

    func testRejectsLanguageSymlinkEscapingApp() throws {
        let outside = sandboxURL.appendingPathComponent("Outside/fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let resources = appURL.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("fr.lproj").path,
            withDestinationPath: outside.path
        )

        let discovery = LanguageResourceDiscovery()
        XCTAssertTrue(
            discovery.languageResources(inApplication: appURL.path).isEmpty
        )
        XCTAssertNil(
            discovery.validatedLanguageResourcePath(
                resources.appendingPathComponent("fr.lproj").path,
                inApplication: appURL.path
            )
        )
    }

    func testRejectsNonLanguageAndOutsidePaths() throws {
        let loose = sandboxURL.appendingPathComponent("Loose.lproj", isDirectory: true)
        let insideFile = appURL.appendingPathComponent("Contents/Resources/readme.txt")
        try FileManager.default.createDirectory(
            at: loose,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: insideFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: insideFile)

        let discovery = LanguageResourceDiscovery()
        XCTAssertNil(
            discovery.validatedLanguageResourcePath(
                loose.path,
                inApplication: appURL.path
            )
        )
        XCTAssertNil(
            discovery.validatedLanguageResourcePath(
                insideFile.path,
                inApplication: appURL.path
            )
        )
    }
}

final class ApplicationBundleInspectorTests: XCTestCase {
    private var sandboxURL: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sandboxURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testStandardMacBundleFindsDeclaredAndAdditionalExecutables() throws {
        let app = sandboxURL.appendingPathComponent("Mac.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try writePlist(
            ["CFBundleExecutable": "Main"],
            to: app.appendingPathComponent("Contents/Info.plist")
        )
        try Data([1]).write(to: macOS.appendingPathComponent("Main"))
        try Data([2]).write(to: macOS.appendingPathComponent("Helper"))

        XCTAssertEqual(
            ApplicationBundleInspector.executablePaths(in: app.path),
            [
                macOS.appendingPathComponent("Main")
                    .standardized.resolvingSymlinksInPath().path,
                macOS.appendingPathComponent("Helper")
                    .standardized.resolvingSymlinksInPath().path
            ]
        )
    }

    func testRootLevelIOSStyleBundleFindsDeclaredExecutable() throws {
        let app = sandboxURL.appendingPathComponent("IOS.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(
            ["CFBundleExecutable": "Runner"],
            to: app.appendingPathComponent("Info.plist")
        )
        let executable = app.appendingPathComponent("Runner")
        try Data([1, 2, 3]).write(to: executable)

        XCTAssertEqual(
            ApplicationBundleInspector.executablePaths(in: app.path),
            [executable.standardized.resolvingSymlinksInPath().path]
        )
    }

    func testDeclaredExecutableSymlinkCannotEscapeBundle() throws {
        let app = sandboxURL.appendingPathComponent("Escape.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(
            ["CFBundleExecutable": "Runner"],
            to: app.appendingPathComponent("Info.plist")
        )

        let outside = sandboxURL.appendingPathComponent("OutsideRunner")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("Runner").path,
            withDestinationPath: outside.path
        )

        XCTAssertTrue(ApplicationBundleInspector.executablePaths(in: app.path).isEmpty)
    }

    func testMissingDeclaredExecutableDoesNotInventAPath() throws {
        let app = sandboxURL.appendingPathComponent("Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(
            ["CFBundleExecutable": "Missing"],
            to: app.appendingPathComponent("Info.plist")
        )

        XCTAssertTrue(ApplicationBundleInspector.executablePaths(in: app.path).isEmpty)
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}

final class ApplicationThinnerTests: XCTestCase {
    private var sandboxURL: URL!
    private var appURL: URL!
    private var macOSURL: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-thinner-\(UUID().uuidString)", isDirectory: true)
        appURL = sandboxURL.appendingPathComponent("Test.app", isDirectory: true)
        macOSURL = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testThinningPreservesSignaturePermissionsAndLeavesNoStagingFiles() throws {
        let binary = macOSURL.appendingPathComponent("Runner")
        try FileManager.default.copyItem(
            atPath: "/usr/bin/true",
            toPath: binary.path
        )
        try writeTestAppInfoPlist(executableName: "Runner")
        XCTAssertTrue(signTestApp())

        let originalArchitectures = try architectures(at: binary.path)
        let target = ProcessInfo.processInfo.machineArchitecture
        let expectedArchitecture = try XCTUnwrap(
            ArchitectureUtilities.preferredSlice(
                from: originalArchitectures,
                targetArchitecture: target
            )
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: binary.path
        )
        XCTAssertTrue(hasValidCodeSignature(appURL.path, deep: true))

        let completion = expectation(description: "thin application")
        var success = false
        var error: String?
        ApplicationThinner().thinApplication(
            atPath: appURL.path,
            targetArchitecture: target
        ) { result, resultError in
            success = result
            error = resultError
            completion.fulfill()
        }
        wait(for: [completion], timeout: 10)

        XCTAssertTrue(success, error ?? "unknown error")
        XCTAssertEqual(try architectures(at: binary.path), [expectedArchitecture])
        XCTAssertTrue(hasValidCodeSignature(appURL.path, deep: true))

        let newAttributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        XCTAssertEqual(
            originalAttributes[.posixPermissions] as? NSNumber,
            newAttributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(
            originalAttributes[.ownerAccountID] as? NSNumber,
            newAttributes[.ownerAccountID] as? NSNumber
        )
        XCTAssertFalse(try directoryContainsArchifyStagingFiles(macOSURL))
        XCTAssertFalse(try parentContainsArchifyTransactionDirectory())
    }

    func testPreparationFailureLeavesEveryOriginalBinaryUntouched() throws {
        let good = macOSURL.appendingPathComponent("Good")
        let failing = macOSURL.appendingPathComponent("Fail")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: good.path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: failing.path)
        let goodBefore = try Data(contentsOf: good)
        let failingBefore = try Data(contentsOf: failing)

        let fakeLipo = sandboxURL.appendingPathComponent("fake-lipo")
        let script = """
        #!/bin/sh
        if [ "$1" = "-archs" ]; then
            exec /usr/bin/lipo "$@"
        fi
        case "$1" in
            *Fail*) exit 42 ;;
            *) exec /usr/bin/lipo "$@" ;;
        esac
        """
        try script.write(to: fakeLipo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLipo.path
        )

        let completion = expectation(description: "failed transaction")
        var success = true
        ApplicationThinner(lipoURL: fakeLipo).thinApplication(
            atPath: appURL.path,
            targetArchitecture: ProcessInfo.processInfo.machineArchitecture
        ) { result, _ in
            success = result
            completion.fulfill()
        }
        wait(for: [completion], timeout: 10)

        XCTAssertFalse(success)
        XCTAssertEqual(try Data(contentsOf: good), goodBefore)
        XCTAssertEqual(try Data(contentsOf: failing), failingBefore)
        XCTAssertFalse(try directoryContainsArchifyStagingFiles(macOSURL))
        XCTAssertFalse(try parentContainsArchifyTransactionDirectory())
    }

    func testThinningSkipsBinariesSealedAsResourcesInSignedApp() throws {
        let (runner, resource) = try makeSignedAppWithSealedResource()
        let resourceBefore = try Data(contentsOf: resource)
        let target = ProcessInfo.processInfo.machineArchitecture

        XCTAssertTrue(
            SealedResourceIndex(applicationPath: appURL.path)
                .isSealedResource(resource.path)
        )
        XCTAssertFalse(
            SealedResourceIndex(applicationPath: appURL.path)
                .isSealedResource(runner.path)
        )

        let result = try thin(signaturePolicy: .preserve, target: target)

        XCTAssertEqual(result.changedPaths, [runner.path], result.error ?? "")
        XCTAssertEqual(try Data(contentsOf: resource), resourceBefore)
        XCTAssertTrue(hasValidCodeSignature(appURL.path, deep: true))
        XCTAssertFalse(try parentContainsArchifyTransactionDirectory())
    }

    func testThinningForResignIncludesBinariesSealedAsResources() throws {
        let (runner, resource) = try makeSignedAppWithSealedResource()
        let target = ProcessInfo.processInfo.machineArchitecture

        let result = try thin(signaturePolicy: .willResign, target: target)

        XCTAssertEqual(
            result.changedPaths?.sorted(),
            [runner.path, resource.path].sorted(),
            result.error ?? ""
        )
        XCTAssertEqual(try architectures(at: resource.path).count, 1)
    }

    func testRefusedCommitLeavesEveryBinaryInPlace() throws {
        let binary = macOSURL.appendingPathComponent("Runner")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binary.path)
        let before = try Data(contentsOf: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: macOSURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: macOSURL.path
            )
        }

        let result = try thin(
            signaturePolicy: .preserve,
            target: ProcessInfo.processInfo.machineArchitecture
        )

        XCTAssertNil(result.changedPaths)
        XCTAssertEqual(result.error, ApplicationThinner.changeNotPermittedMessage)
        XCTAssertEqual(try Data(contentsOf: binary), before)
        XCTAssertFalse(try parentContainsArchifyTransactionDirectory())
    }

    private func makeSignedAppWithSealedResource() throws -> (URL, URL) {
        let runner = macOSURL.appendingPathComponent("Runner")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: runner.path)
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let resource = resourcesURL.appendingPathComponent("addon.node")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: resource.path)
        try writeTestAppInfoPlist(executableName: "Runner")
        XCTAssertTrue(signTestApp())
        XCTAssertTrue(hasValidCodeSignature(appURL.path, deep: true))
        return (runner, resource)
    }

    private func thin(
        signaturePolicy: ApplicationThinner.SignaturePolicy,
        target: String
    ) throws -> (changedPaths: [String]?, error: String?) {
        let completion = expectation(description: "thin application")
        var changedPaths: [String]?
        var error: String?
        ApplicationThinner().thinApplicationReportingChanges(
            atPath: appURL.path,
            targetArchitecture: target,
            signaturePolicy: signaturePolicy
        ) { paths, resultError in
            changedPaths = paths
            error = resultError
            completion.fulfill()
        }
        wait(for: [completion], timeout: 20)
        return (changedPaths, error)
    }

    private func architectures(at path: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private func hasValidCodeSignature(
        _ path: String,
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

    private func writeTestAppInfoPlist(executableName: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": executableName,
                "CFBundleIdentifier": "test.archify.thinner",
                "CFBundlePackageType": "APPL"
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: infoURL)
    }

    private func signTestApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--deep",
            "--sign",
            "-",
            appURL.path
        ]
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

    private func directoryContainsArchifyStagingFiles(_ directory: URL) throws -> Bool {
        let items = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return items.contains {
            $0.hasPrefix(".archify-thin-") || $0.hasPrefix(".archify-backup-")
        }
    }

    private func parentContainsArchifyTransactionDirectory() throws -> Bool {
        let items = try FileManager.default.contentsOfDirectory(
            atPath: appURL.deletingLastPathComponent().path
        )
        return items.contains { $0.hasPrefix(".archify-transaction-") }
    }
}

final class LanguageProtectionTests: XCTestCase {
    func testLanguageCodeNormalizesRegionsScriptsAndLegacyNames() {
        XCTAssertEqual(LanguageProtection.languageCode("en_GB"), "en")
        XCTAssertEqual(LanguageProtection.languageCode("en-US"), "en")
        XCTAssertEqual(LanguageProtection.languageCode("English"), "en")
        XCTAssertEqual(LanguageProtection.languageCode("zh-Hans"), "zh")
        XCTAssertEqual(LanguageProtection.languageCode("pt_BR"), "pt")
    }

    func testGroupsFolderNamesByLanguageWithReadableNames() {
        XCTAssertEqual(LanguageProtection.languageKey("English"), "en")
        XCTAssertEqual(LanguageProtection.languageKey("pt_BR"), "pt-BR")
        XCTAssertEqual(LanguageProtection.languageKey("pt-BR"), "pt-BR")
        XCTAssertEqual(LanguageProtection.languageKey("zh-Hans"), "zh-Hans")

        let english = Locale(identifier: "en_US")
        XCTAssertEqual(LanguageProtection.displayName(forKey: "fr", locale: english), "French")
        XCTAssertEqual(
            LanguageProtection.displayName(forKey: "pt-BR", locale: english),
            "Portuguese (Brazil)"
        )
        XCTAssertEqual(LanguageProtection.displayName(forKey: "Base", locale: english), "Base")
    }

    func testProtectsDevelopmentRegionAndPreferredLanguages() {
        let protected = LanguageProtection.protectedLanguages(
            ["Base", "English", "en_GB", "fr", "de", "ja"],
            developmentLanguageCode: "en",
            preferredLanguageCodes: LanguageProtection.preferredLanguageCodes(
                ["de-DE"]
            )
        )

        XCTAssertEqual(protected, ["English", "en_GB", "de"])
    }

    func testDevelopmentRegionDefaultsToEnglish() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-lang-\(UUID().uuidString)/Test.app")
        defer {
            try? FileManager.default.removeItem(
                at: appURL.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")

        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test"],
            format: .xml,
            options: 0
        ).write(to: infoURL)
        XCTAssertEqual(
            LanguageProtection.developmentLanguageCode(inApplication: appURL.path),
            "en"
        )

        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleDevelopmentRegion": "fr_CA"],
            format: .xml,
            options: 0
        ).write(to: infoURL)
        XCTAssertEqual(
            LanguageProtection.developmentLanguageCode(inApplication: appURL.path),
            "fr"
        )
    }
}
