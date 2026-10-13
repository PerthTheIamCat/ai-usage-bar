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

    func testParsesConnectRPCModelGroupsResponse() throws {
        let payload = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "buckets": [
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "description": "You have used some of your weekly limit, it will fully refresh in 14 hours, 39 minutes.",
                    "window": "weekly",
                    "remainingFraction": 0.25,
                    "resetTime": "2026-10-14T03:38:21Z"
                  },
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "window": "5h",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-10-13T17:59:08Z"
                  }
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                "buckets": [
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit Remaining",
                    "description": "You have used some of your weekly limit, it will fully refresh in 18 hours, 55 minutes.",
                    "window": "weekly",
                    "remainingFraction": 0.48,
                    "resetTime": "2026-10-14T07:54:57Z"
                  },
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit Remaining",
                    "window": "5h",
                    "remainingFraction": 1.0,
                    "resetTime": "2026-10-13T17:59:08Z"
                  }
                ]
              }
            ]
          }
        }
        """
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(snapshot.groups.count, 2)
        XCTAssertEqual(snapshot.groups[0].name, "Gemini Models")
        XCTAssertEqual(try XCTUnwrap(snapshot.groups[0].weekly).usedPercent, 75.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.groups[0].weekly?.resetDescription, "You have used some of your weekly limit, it will fully refresh in 14 hours, 39 minutes.")
        XCTAssertEqual(try XCTUnwrap(snapshot.groups[0].fiveHour).usedPercent, 0.0, accuracy: 0.001)

        XCTAssertEqual(snapshot.groups[1].name, "Claude and GPT models")
        XCTAssertEqual(try XCTUnwrap(snapshot.groups[1].weekly).usedPercent, 52.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.groups[1].weekly?.resetDescription, "You have used some of your weekly limit, it will fully refresh in 18 hours, 55 minutes.")

        // Primary windows fallback to Gemini models
        XCTAssertEqual(try XCTUnwrap(snapshot.weekly).usedPercent, 75.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).usedPercent, 0.0, accuracy: 0.001)
    }

    func testParsesStoredSnapshotRecordWithGroups() throws {
        let payload = """
        {
          "observed_at": 1700000000,
          "weekly_used": 75.0,
          "five_hour_used": 0.0,
          "groups": [
            {
              "name": "Gemini Models",
              "description": "Flash, Pro",
              "weekly_used": 75.0,
              "five_hour_used": 0.0
            }
          ]
        }
        """
        let snapshot = try XCTUnwrap(
            AntigravityLimitsReader.parseStatusLinePayload(Data(payload.utf8), observedAt: observedAt))

        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups[0].name, "Gemini Models")
        XCTAssertEqual(snapshot.groups[0].description, "Flash, Pro")
        XCTAssertEqual(try XCTUnwrap(snapshot.groups[0].weekly).usedPercent, 75.0, accuracy: 0.001)
    }
}
