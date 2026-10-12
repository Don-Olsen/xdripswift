import XCTest
import os
@testable import xdrip

/// Exercises the production trace function in the test application's own sandbox.
/// Existing developer traces and settings are restored after each fixture.
@MainActor
final class TraceFilteringTests: XCTestCase {
    private let log = OSLog(subsystem: "xdrip.tests", category: "trace-filtering")

    func testDisabledDebugKeepsTypedHistoryWithoutWritingDeveloperText() throws {
        try withTraceFixture { files in
            UserDefaults.standard.OSLogEnabled = true
            UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = false
            let marker = UUID().uuidString
            let entry = TroubleshootingLogEntry.standard(.app(.started), timestamp: Date())

            trace("Filtered test debug %{public}@", log: log, category: "TraceFilteringTests",
                  type: .debug, troubleshooting: entry, marker)

            XCTAssertTrue(TroubleshootingLogStore.shared.snapshot().contains(entry),
                          "The debug filter must run after the typed consumer-history offer")
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(marker))
            }
        }
    }

    func testEnabledDebugAndOrdinaryLevelsKeepExistingFileFormatting() throws {
        try withTraceFixture { files in
            UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = true
            let debugMarker = UUID().uuidString
            trace("Debug %{public}@ count %{public}d value %{public}f", log: log,
                  category: "TraceFilteringTests", type: .debug, debugMarker, 7, 1.25)
            let debugText = try String(contentsOf: files[0], encoding: .utf8)
            XCTAssertTrue(debugText.contains("TraceFilteringTests Debug \(debugMarker) count 7 value 1.25\n"))

            UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = false
            for level in [OSLogType.default, .info, .error, .fault] {
                let marker = UUID().uuidString
                trace("Ordinary %{public}@", log: log, category: "TraceFilteringTests",
                      type: level, marker)
                XCTAssertTrue(try String(contentsOf: files[0], encoding: .utf8)
                    .contains("TraceFilteringTests Ordinary \(marker)\n"))
            }
        }
    }

    func testFilteredDebugDefersRotationUntilNextFileEligibleMessage() throws {
        try withTraceFixture { files in
            UserDefaults.standard.addDebugLevelLogsInTraceFileAndNSLog = false
            let oversized = Data(repeating: 65,
                count: Int(ConstantsTrace.maximumFileSizeInMB * 1_024 * 1_024) + 1)
            try oversized.write(to: files[0])
            let skippedMarker = UUID().uuidString

            trace("Skipped %{public}@", log: log, category: "TraceFilteringTests",
                  type: .debug, skippedMarker)

            XCTAssertEqual(try Data(contentsOf: files[0]), oversized,
                           "Discarded debug must not write or rotate an existing oversized file")
            XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))

            let errorMarker = UUID().uuidString
            trace("Rotate %{public}@", log: log, category: "TraceFilteringTests",
                  type: .error, errorMarker)
            XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
            let rotated = try String(contentsOf: files[1], encoding: .utf8)
            XCTAssertTrue(rotated.contains(errorMarker))
            XCTAssertFalse(rotated.contains(skippedMarker))

            let nextMarker = UUID().uuidString
            trace("Next %{public}@", log: log, category: "TraceFilteringTests",
                  type: .default, nextMarker)
            XCTAssertTrue(try String(contentsOf: files[0], encoding: .utf8).contains(nextMarker),
                          "Logging resumes in file zero after the existing rotation")
        }
    }

    private func withTraceFixture(_ body: ([URL]) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let settingKeys = [UserDefaults.Key.OSLogEnabled.rawValue,
                           UserDefaults.Key.NSLogEnabled.rawValue,
                           UserDefaults.Key.addDebugLevelLogsInTraceFileAndNSLog.rawValue]
        let previousSettings = settingKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(settingKeys, previousSettings) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.OSLogEnabled = false
        defaults.NSLogEnabled = false

        let manager = FileManager.default
        let directory = try XCTUnwrap(manager.urls(for: .documentDirectory, in: .userDomainMask).first)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = manager.temporaryDirectory.appendingPathComponent("TraceFiltering-\(UUID().uuidString)")
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        let files = (0..<ConstantsTrace.maximumAmountOfTraceFiles).map {
            directory.appendingPathComponent("\(ConstantsTrace.traceFileName).\($0).log")
        }
        var movedFiles = [URL]()
        var prepared = false
        defer {
            for file in files where prepared || movedFiles.contains(file) {
                if manager.fileExists(atPath: file.path) { try? manager.removeItem(at: file) }
            }
            for file in movedFiles {
                do { try manager.moveItem(at: backup.appendingPathComponent(file.lastPathComponent), to: file) }
                catch { XCTFail("Could not restore test-container developer trace: \(error)") }
            }
            if (try? manager.contentsOfDirectory(atPath: backup.path).isEmpty) == true {
                try? manager.removeItem(at: backup)
            }
        }
        for file in files where manager.fileExists(atPath: file.path) {
            try manager.moveItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
            movedFiles.append(file)
        }
        prepared = true
        try body(files)
    }
}
