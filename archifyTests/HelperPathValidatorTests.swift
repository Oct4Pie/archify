import Foundation
import XCTest

final class HelperPathValidatorTests: XCTestCase {
    private var sandboxURL: URL!
    private var allowedURL: URL!
    private var outsideURL: URL!
    private var validator: HelperPathValidator!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("archify-tests-\(UUID().uuidString)", isDirectory: true)
        sandboxURL = base
        allowedURL = base.appendingPathComponent("Applications", isDirectory: true)
        outsideURL = base.appendingPathComponent("Outside", isDirectory: true)

        try FileManager.default.createDirectory(
            at: allowedURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )

        validator = HelperPathValidator(allowedDirectories: [allowedURL.path])
    }

    override func tearDownWithError() throws {
        if let sandboxURL {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testRejectsAllowlistedRootItselfAndPrefixSibling() throws {
        XCTAssertNil(validator.allowedPath(allowedURL.path))

        let sibling = sandboxURL.appendingPathComponent("ApplicationsEvil", isDirectory: true)
        let app = sibling.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertNil(validator.allowedPath(app.path))
        XCTAssertNil(validator.applicationPath(app.path))
    }

    func testAcceptsApplicationDirectoryInsideAllowedRoot() throws {
        let app = allowedURL.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertEqual(
            validator.applicationPath(app.path),
            app.standardized.resolvingSymlinksInPath().path
        )
    }

    func testRejectsNonApplicationDirectoryForApplicationOperation() throws {
        let directory = allowedURL.appendingPathComponent("Example", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertNil(validator.applicationPath(directory.path))
    }

    func testAcceptsLanguageResourceOnlyInsideApplicationBundle() throws {
        let language = allowedURL
            .appendingPathComponent("Example.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)

        XCTAssertEqual(
            validator.languageResourcePath(language.path),
            language.standardized.resolvingSymlinksInPath().path
        )

        let looseLanguage = allowedURL.appendingPathComponent("fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: looseLanguage, withIntermediateDirectories: true)
        XCTAssertNil(validator.languageResourcePath(looseLanguage.path))
    }

    func testRejectsBaseLocalizationAtPrivilegedBoundary() throws {
        let baseLanguage = allowedURL
            .appendingPathComponent("Example.app", isDirectory: true)
            .appendingPathComponent(
                "Contents/Resources/Base.lproj",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: baseLanguage,
            withIntermediateDirectories: true
        )

        XCTAssertNil(
            validator.languageResourceTarget(baseLanguage.path)
        )
    }

    func testRejectsSymlinkedIntermediateComponent() throws {
        let realApp = allowedURL
            .appendingPathComponent("Real.app", isDirectory: true)
        let resources = realApp
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let language = resources.appendingPathComponent(
            "fr.lproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: language,
            withIntermediateDirectories: true
        )

        let aliasApp = allowedURL.appendingPathComponent(
            "Alias.app",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: aliasApp.path,
            withDestinationPath: realApp.path
        )

        XCTAssertNil(
            validator.languageResourceTarget(
                aliasApp
                    .appendingPathComponent(
                        "Contents/Resources/fr.lproj",
                        isDirectory: true
                    )
                    .path
            )
        )
    }

    func testRemovingOfferedLanguageFolderKeepsSignedAppValid() throws {
        let appURL = allowedURL.appendingPathComponent("Signed.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            atPath: "/usr/bin/true",
            toPath: contentsURL.appendingPathComponent("MacOS/Runner").path
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Runner",
                "CFBundleIdentifier": "test.archify.languages",
                "CFBundlePackageType": "APPL"
            ],
            format: .xml,
            options: 0
        ).write(to: contentsURL.appendingPathComponent("Info.plist"))
        for language in ["en", "fr"] {
            let folder = contentsURL.appendingPathComponent(
                "Resources/\(language).lproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("\"k\" = \"v\";".utf8)
                .write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        XCTAssertEqual(runCodesign(["--force", "--sign", "-", appURL.path]), 0)
        XCTAssertEqual(runCodesign(["--verify", "--deep", "--strict", appURL.path]), 0)

        // Discovery offers the folder because codesign seals .lproj as optional.
        let offered = try XCTUnwrap(
            LanguageResourceDiscovery()
                .languageResources(inApplication: appURL.path)["fr"]?
                .first
        )
        let target = try XCTUnwrap(validator.languageResourceTarget(offered))
        XCTAssertNil(SecureDirectoryRemover().remove(target))

        XCTAssertFalse(FileManager.default.fileExists(atPath: offered))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: contentsURL.appendingPathComponent("Resources/en.lproj").path
            )
        )
        XCTAssertEqual(runCodesign(["--verify", "--deep", "--strict", appURL.path]), 0)
    }

    private func runCodesign(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    func testSecureDirectoryRemoverDeletesTargetWithoutFollowingSymlinks()
        throws
    {
        let language = allowedURL
            .appendingPathComponent("Example.app", isDirectory: true)
            .appendingPathComponent(
                "Contents/Resources/fr.lproj",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: language,
            withIntermediateDirectories: true
        )
        let nested = language.appendingPathComponent(
            "Nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(
            to: nested.appendingPathComponent("Localizable.strings")
        )

        let outsideFile = outsideURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            atPath: language.appendingPathComponent("outside-link").path,
            withDestinationPath: outsideFile.path
        )

        let target = try XCTUnwrap(
            validator.languageResourceTarget(language.path)
        )
        XCTAssertNil(SecureDirectoryRemover().remove(target))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: language.path)
        )
        XCTAssertEqual(
            try String(contentsOf: outsideFile, encoding: .utf8),
            "keep"
        )
    }

    func testRejectsApplicationSymlinkEscapingAllowedRoot() throws {
        let outsideApp = outsideURL.appendingPathComponent("Escape.app", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideApp, withIntermediateDirectories: true)

        let link = allowedURL.appendingPathComponent("Escape.app")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outsideApp.path
        )

        XCTAssertNil(validator.allowedPath(link.path))
        XCTAssertNil(validator.applicationPath(link.path))
    }

    func testRejectsLanguageResourceSymlinkEscapingAllowedRoot() throws {
        let appResources = allowedURL
            .appendingPathComponent("Example.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)

        let outsideLanguage = outsideURL.appendingPathComponent("fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideLanguage,
            withIntermediateDirectories: true
        )

        let link = appResources.appendingPathComponent("fr.lproj")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outsideLanguage.path
        )

        XCTAssertNil(validator.languageResourcePath(link.path))
    }
}
