import Darwin
import Foundation
import XCTest

final class ProcessInfoArchitectureTests: XCTestCase {
    func testAppleSiliconHardwareIsReportedUnderRosetta() {
        var arm64Supported: Int32 = 0
        var size = MemoryLayout<Int32>.size

        guard sysctlbyname(
            "hw.optional.arm64",
            &arm64Supported,
            &size,
            nil,
            0
        ) == 0,
        arm64Supported == 1 else {
            return
        }

        XCTAssertEqual(ProcessInfo.processInfo.machineArchitecture, "arm64")
    }
}

final class MachOUtilitiesTests: XCTestCase {
    func testRecognizesAllSupportedMachOMagicNumbers() {
        for magic in MachOUtilities.magicNumbers {
            let data = bigEndianData(magic)
            XCTAssertTrue(MachOUtilities.isMachOMagic(data), String(format: "0x%08X", magic))
        }
    }

    func testRecognizesMagicWithTrailingBytes() {
        var data = bigEndianData(0xCAFEBABF)
        data.append(contentsOf: [0x00, 0x01, 0x02])
        XCTAssertTrue(MachOUtilities.isMachOMagic(data))
    }

    func testRejectsShortAndUnknownHeaders() {
        XCTAssertFalse(MachOUtilities.isMachOMagic(Data()))
        XCTAssertFalse(MachOUtilities.isMachOMagic(Data([0xFE, 0xED, 0xFA])))
        XCTAssertFalse(MachOUtilities.isMachOMagic(Data([0x00, 0x00, 0x00, 0x00])))
    }

    private func bigEndianData(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

final class MachOInspectorTests: XCTestCase {
    func testReadsThinArm64Header() throws {
        var data = Data([
            0xCF, 0xFA, 0xED, 0xFE, // MH_MAGIC_64, little endian
            0x0C, 0x00, 0x00, 0x01, // CPU_TYPE_ARM64
            0x00, 0x00, 0x00, 0x00  // CPU_SUBTYPE_ARM64_ALL
        ])
        data.append(Data(repeating: 0, count: 52))

        let path = try writeTemporaryBinary(data)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            MachOInspector.slices(atPath: path),
            [MachOSliceInfo(architecture: "arm64", size: UInt64(data.count))]
        )
    }

    func testReadsFat32ArchitectureSizes() throws {
        var data = Data([
            0xCA, 0xFE, 0xBA, 0xBE, // FAT_MAGIC, big endian
            0x00, 0x00, 0x00, 0x02  // 2 slices
        ])

        appendBigEndian32(0x0100_000C, to: &data) // arm64
        appendBigEndian32(0, to: &data)
        appendBigEndian32(0x0000_1000, to: &data)
        appendBigEndian32(0x0000_2000, to: &data)
        appendBigEndian32(12, to: &data)

        appendBigEndian32(0x0100_0007, to: &data) // x86_64
        appendBigEndian32(3, to: &data)
        appendBigEndian32(0x0000_3000, to: &data)
        appendBigEndian32(0x0000_5000, to: &data)
        appendBigEndian32(12, to: &data)

        let path = try writeTemporaryBinary(data)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            MachOInspector.architectureSizes(atPath: path),
            ["arm64": 0x2000, "x86_64": 0x5000]
        )
    }

    func testReadsFat64AndSpecialSubtypes() throws {
        var data = Data([
            0xCA, 0xFE, 0xBA, 0xBF, // FAT_MAGIC_64, big endian
            0x00, 0x00, 0x00, 0x02
        ])

        appendBigEndian32(0x0100_000C, to: &data) // arm64e
        appendBigEndian32(2, to: &data)
        appendBigEndian64(0x1_0000_0000, to: &data)
        appendBigEndian64(0x0000_0000_0001_2345, to: &data)
        appendBigEndian32(14, to: &data)
        appendBigEndian32(0, to: &data)

        appendBigEndian32(0x0100_0007, to: &data) // x86_64h
        appendBigEndian32(8, to: &data)
        appendBigEndian64(0x2_0000_0000, to: &data)
        appendBigEndian64(0x0000_0000_0002_3456, to: &data)
        appendBigEndian32(14, to: &data)
        appendBigEndian32(0, to: &data)

        let path = try writeTemporaryBinary(data)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            MachOInspector.slices(atPath: path),
            [
                MachOSliceInfo(architecture: "arm64e", size: 0x12345),
                MachOSliceInfo(architecture: "x86_64h", size: 0x23456)
            ]
        )
    }

    func testReadsArm64eX1Subtype() throws {
        var data = Data([
            0xCA, 0xFE, 0xBA, 0xBE,
            0x00, 0x00, 0x00, 0x02
        ])

        appendBigEndian32(0x0100_000C, to: &data)
        appendBigEndian32(0x8000_0002, to: &data)
        appendBigEndian32(0x1000, to: &data)
        appendBigEndian32(0x2000, to: &data)
        appendBigEndian32(12, to: &data)

        appendBigEndian32(0x0100_000C, to: &data)
        appendBigEndian32(0x8000_000C, to: &data)
        appendBigEndian32(0x3000, to: &data)
        appendBigEndian32(0x4000, to: &data)
        appendBigEndian32(12, to: &data)

        let path = try writeTemporaryBinary(data)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            MachOInspector.architectures(atPath: path),
            ["arm64e", "arm64e.x1"]
        )
    }

    func testUnknownArm64SubtypeIsNotMisidentifiedAsArm64() throws {
        var data = Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01,
            0x63, 0x00, 0x00, 0x00
        ])
        data.append(Data(repeating: 0, count: 32))

        let path = try writeTemporaryBinary(data)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(
            MachOInspector.architectures(atPath: path),
            ["arm64_subtype_99"]
        )
    }

    func testRejectsNonMachOData() throws {
        let path = try writeTemporaryBinary(Data("hello".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(MachOInspector.slices(atPath: path))
    }

    private func writeTemporaryBinary(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url.path
    }

    private func appendBigEndian32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func appendBigEndian64(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

final class ArchitectureUtilitiesTests: XCTestCase {
    func testAppTypeClassification() {
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: [], hostArchitecture: "arm64"),
            "Unknown"
        )
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: ["arm64", "x86_64"], hostArchitecture: "arm64"),
            "Universal"
        )
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: ["arm64"], hostArchitecture: "arm64"),
            "Native"
        )
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: ["x86_64"], hostArchitecture: "arm64"),
            "Intel"
        )
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: ["arm64"], hostArchitecture: "x86_64"),
            "Apple Silicon"
        )
        XCTAssertEqual(
            ArchitectureUtilities.appType(for: ["riscv64"], hostArchitecture: "arm64"),
            "Other"
        )
    }

    func testPreferredSliceUsesNativeTargetWhenAvailable() {
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["x86_64", "arm64"],
                targetArchitecture: "arm64"
            ),
            "arm64"
        )
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64", "x86_64"],
                targetArchitecture: "x86_64"
            ),
            "x86_64"
        )
    }

    func testPreferredSliceHandlesArm64AndArm64eCompatibility() {
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64e", "x86_64"],
                targetArchitecture: "arm64"
            ),
            "arm64e"
        )
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64", "x86_64"],
                targetArchitecture: "arm64e"
            ),
            "arm64"
        )
    }

    func testPreferredSliceHandlesArm64eX1Compatibility() {
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["x86_64", "arm64e.x1"],
                targetArchitecture: "arm64"
            ),
            "arm64e.x1"
        )
    }

    func testPreferredSliceHandlesX8664hCompatibility() {
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64", "x86_64h"],
                targetArchitecture: "x86_64"
            ),
            "x86_64h"
        )
    }

    func testPreferredSliceFallsBackToIntelForAppleSiliconTarget() {
        XCTAssertEqual(
            ArchitectureUtilities.preferredSlice(
                from: ["i386", "x86_64"],
                targetArchitecture: "arm64"
            ),
            "x86_64"
        )
    }

    func testPreferredSliceRejectsSingleArchitectureAndUnsupportedFallbacks() {
        XCTAssertNil(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64"],
                targetArchitecture: "arm64"
            )
        )
        XCTAssertNil(
            ArchitectureUtilities.preferredSlice(
                from: ["arm64", "arm64e"],
                targetArchitecture: "x86_64"
            )
        )
    }

    func testExternalExecutableMustContainHostArchitecture() {
        XCTAssertTrue(
            ArchitectureUtilities.executableSupportsHost(
                architectures: ["arm64", "x86_64"],
                hostArchitecture: "x86_64"
            )
        )
        XCTAssertFalse(
            ArchitectureUtilities.executableSupportsHost(
                architectures: ["arm64"],
                hostArchitecture: "x86_64"
            )
        )
    }

    func testRemovableSizeUsesTheActuallyKeptCompatibleSlice() {
        XCTAssertEqual(
            ArchitectureUtilities.removableSize(
                architectureSizes: ["arm64e": 60, "x86_64": 100],
                targetArchitecture: "arm64"
            ),
            100
        )
        XCTAssertEqual(
            ArchitectureUtilities.removableSize(
                architectureSizes: ["i386": 40, "x86_64": 100],
                targetArchitecture: "arm64"
            ),
            40
        )
        XCTAssertEqual(
            ArchitectureUtilities.removableSize(
                architectureSizes: ["arm64": 60],
                targetArchitecture: "arm64"
            ),
            0
        )
    }
}

final class HelperVersionUtilitiesTests: XCTestCase {
    func testNumericVersionValidation() {
        XCTAssertTrue(HelperVersionUtilities.isNumericBundleVersion("7"))
        XCTAssertTrue(HelperVersionUtilities.isNumericBundleVersion("7.0"))
        XCTAssertTrue(HelperVersionUtilities.isNumericBundleVersion("10.12.3"))

        XCTAssertFalse(HelperVersionUtilities.isNumericBundleVersion(""))
        XCTAssertFalse(HelperVersionUtilities.isNumericBundleVersion("release"))
        XCTAssertFalse(HelperVersionUtilities.isNumericBundleVersion("1."))
        XCTAssertFalse(HelperVersionUtilities.isNumericBundleVersion(".1"))
        XCTAssertFalse(HelperVersionUtilities.isNumericBundleVersion("1a.2"))
    }

    func testHelperRefreshDecision() {
        XCTAssertTrue(
            HelperVersionUtilities.needsRefresh(installedVersion: nil, bundledVersion: "7.0")
        )
        XCTAssertTrue(
            HelperVersionUtilities.needsRefresh(installedVersion: "release", bundledVersion: "7.0")
        )
        XCTAssertTrue(
            HelperVersionUtilities.needsRefresh(installedVersion: "6.9", bundledVersion: "7.0")
        )
        XCTAssertFalse(
            HelperVersionUtilities.needsRefresh(installedVersion: "7.0", bundledVersion: "7.0")
        )
        XCTAssertFalse(
            HelperVersionUtilities.needsRefresh(installedVersion: "8.0", bundledVersion: "7.0")
        )
        XCTAssertTrue(
            HelperVersionUtilities.needsRefresh(installedVersion: "9.9", bundledVersion: "10.0")
        )
    }
}

final class StorageUtilitiesTests: XCTestCase {
    func testSavedSpaceDoesNotUnderflow() {
        XCTAssertEqual(StorageUtilities.savedSpace(originalSize: 1_000, newSize: 400), 600)
        XCTAssertEqual(StorageUtilities.savedSpace(originalSize: 1_000, newSize: 1_000), 0)
        XCTAssertEqual(StorageUtilities.savedSpace(originalSize: 1_000, newSize: 1_500), 0)
    }

    func testSavedPercentageHandlesZeroAndGrowth() {
        XCTAssertEqual(
            StorageUtilities.savedPercentage(
                originalSize: 1_000,
                newSize: 400
            ),
            60,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StorageUtilities.savedPercentage(
                originalSize: 0,
                newSize: 0
            ),
            0
        )
        XCTAssertEqual(
            StorageUtilities.savedPercentage(
                originalSize: 1_000,
                newSize: 1_500
            ),
            0
        )
    }
}

final class RunControlTests: XCTestCase {
    func testCheckpointBlocksWhilePausedAndContinuesOnResume() {
        let control = RunControl()
        control.begin()
        control.pause()

        let passed = expectation(description: "checkpoint passed")
        let lock = NSLock()
        var result: Bool?
        DispatchQueue.global().async {
            let value = control.checkpoint()
            lock.lock()
            result = value
            lock.unlock()
            passed.fulfill()
        }

        // Still held after a moment while paused.
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock()
        XCTAssertNil(result, "A paused checkpoint must not return.")
        lock.unlock()
        control.resume()
        wait(for: [passed], timeout: 2)
        XCTAssertEqual(result, true)
    }

    func testCancelReleasesAPausedCheckpointAndStopsTheLoop() {
        let control = RunControl()
        control.begin()
        control.pause()

        let passed = expectation(description: "checkpoint returned")
        var result: Bool?
        DispatchQueue.global().async {
            result = control.checkpoint()
            passed.fulfill()
        }

        control.cancel()
        wait(for: [passed], timeout: 2)
        XCTAssertEqual(result, false)
        XCTAssertEqual(control.state, .stopping)
        XCTAssertFalse(control.checkpoint())
    }

    func testProceedHoldsTheNextStepUntilResumedExactlyOnce() {
        let control = RunControl()
        control.begin()
        var steps = 0
        var stops = 0

        control.proceed({ steps += 1 }, orStop: { stops += 1 })
        XCTAssertEqual(steps, 1)

        control.pause()
        control.proceed({ steps += 1 }, orStop: { stops += 1 })
        XCTAssertEqual(steps, 1, "A paused run must not start the next step.")

        control.resume()
        control.resume()
        XCTAssertEqual(steps, 2, "Resume runs the held step exactly once.")
        XCTAssertEqual(stops, 0)
    }

    func testCancelWhilePausedRunsStopInsteadOfTheHeldStep() {
        let control = RunControl()
        control.begin()
        var steps = 0
        var stops = 0

        control.pause()
        control.proceed({ steps += 1 }, orStop: { stops += 1 })
        control.cancel()

        XCTAssertEqual(steps, 0)
        XCTAssertEqual(stops, 1)

        control.finish()
        XCTAssertEqual(control.state, .idle)
    }
}
