import XCTest
@testable import AIUsageBar

final class AntigravityLimitsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesDocumentedSnakeCaseQuotaBuckets() throws {
        let payload = #"{"quota":{"gemini-5h":{"remaining_fraction":0.72,"reset_time":"2026-09-05T23:00:00Z"},"gemini-weekly":{"remaining_fraction":0.41,"reset_time":"2026-09-10T12:00:00Z"}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 59, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, UsageReader.parseISO("2026-09-05T23:00:00Z"))
        XCTAssertEqual(snapshot.weekly?.resetsAt, UsageReader.parseISO("2026-09-10T12:00:00Z"))
    }

    func testUsesResetSecondsForUnlabelledShortWindow() throws {
        let payload = #"{"quota":{"primary":{"remaining_fraction":0.5,"reset_in_seconds":3600},"secondary":{"remaining_fraction":0.8,"reset_in_seconds":604800}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 20, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, observedAt.addingTimeInterval(3600))
        XCTAssertEqual(snapshot.weekly?.resetsAt, observedAt.addingTimeInterval(604800))
    }

    func testIgnoresMalformedQuotaEntries() {
        let payload = #"{"quota":{"bad":{"remaining_fraction":2},"missing":{},"wrong":{"remaining_fraction":"0.4"}}}"#
        XCTAssertNil(AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))
    }

    func testWeekBucketNamesRouteToTheWeeklyWindow() throws {
        let payload = #"{"quota":{"model-7d":{"remaining_fraction":0.9,"reset_in_seconds":100}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        // A short reset must not override an explicit weekly bucket name.
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 10, accuracy: 0.001)
    }

    func testMostUsedWindowIsNotHiddenBehindARoomierModelBucket() throws {
        // When several models report the same window, the snapshot keeps the
        // lowest used percentage — pin it so a change here is deliberate.
        let payload = #"{"quota":{"a-5h":{"remaining_fraction":0.2},"b-5h":{"remaining_fraction":0.6}}}"#
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 40, accuracy: 0.001)
    }

    func testPayloadWithoutQuotaObjectIsRejected() {
        XCTAssertNil(AntigravityLimitsReader.parseStatusLinePayload(Data("{}".utf8), observedAt: observedAt))
        XCTAssertNil(AntigravityLimitsReader.parseStatusLinePayload(Data("not json".utf8), observedAt: observedAt))
    }

    func testSnapshotBecomesStaleAfterThirtyMinutes() {
        let snapshot = AntigravityLimitsReader.Snapshot(
            fiveHour: LimitWindow(usedPercent: 10, resetsAt: nil), weekly: nil, observedAt: observedAt)

        XCTAssertFalse(AntigravityLimitsReader.isStale(snapshot, now: observedAt.addingTimeInterval(29 * 60)))
        XCTAssertTrue(AntigravityLimitsReader.isStale(snapshot, now: observedAt.addingTimeInterval(31 * 60)))
    }
}

final class AntigravityStatusLineSetupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-setup-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var settingsURL: URL { AntigravityStatusLineSetup.settingsFileURL(in: directory) }

    private func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    func testInstallCreatesExecutableBridgeAndSettings() throws {
        XCTAssertEqual(AntigravityStatusLineSetup.currentState(in: directory), .notConfigured)

        guard case .success = AntigravityStatusLineSetup.install(in: directory) else {
            return XCTFail("install should succeed in an empty directory")
        }

        let script = AntigravityStatusLineSetup.scriptURL(in: directory)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        XCTAssertEqual(AntigravityStatusLineSetup.currentState(in: directory), .configured)
    }

    func testInstallKeepsExistingSettingsAndBacksThemUp() throws {
        try writeSettings("{\n  \"theme\": \"dark\"\n}\n")

        guard case .success = AntigravityStatusLineSetup.install(in: directory) else {
            return XCTFail("install should succeed alongside unrelated settings")
        }

        let updated = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)) as? [String: Any]
        XCTAssertEqual(updated?["theme"] as? String, "dark")
        XCTAssertNotNil(updated?["statusLine"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("settings.json.bak-aiusagebar").path))
    }

    func testInstallRefusesToOverwriteAnotherStatusLine() throws {
        let original = "{\"statusLine\": {\"type\": \"command\", \"command\": \"/usr/local/bin/mine\"}}"
        try writeSettings(original)

        guard case .failure(.conflictingStatusLine) = AntigravityStatusLineSetup.install(in: directory) else {
            return XCTFail("a foreign statusLine must not be replaced")
        }
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), original)
    }

    func testInstallIsIdempotent() throws {
        _ = AntigravityStatusLineSetup.install(in: directory)
        let afterFirst = try String(contentsOf: settingsURL, encoding: .utf8)

        guard case .success = AntigravityStatusLineSetup.install(in: directory) else {
            return XCTFail("second install should be a no-op success")
        }
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), afterFirst)
    }

    func testInstallRejectsInvalidJSON() throws {
        try writeSettings("{ not json")

        guard case .failure(.writeFailed) = AntigravityStatusLineSetup.install(in: directory) else {
            return XCTFail("invalid settings must be reported, not overwritten")
        }
    }
}
