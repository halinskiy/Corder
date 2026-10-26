import XCTest
@testable import Corder

final class NewsPollerTests: XCTestCase {
    func testFailureScheduleCapsAtSixHoursAndSuccessResetsIt() {
        var schedule = NewsFetchSchedule()
        var now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(schedule.isDue(at: now))
        for minutes in [30, 60, 120, 240, 360, 360, 360] {
            schedule.failed(at: now)
            XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(Double(minutes * 60) - 1)))
            now = now.addingTimeInterval(Double(minutes * 60))
            XCTAssertTrue(schedule.isDue(at: now))
        }
        schedule.succeeded(at: now)
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(6 * 3600 - 1)))
        now = now.addingTimeInterval(6 * 3600)
        XCTAssertTrue(schedule.isDue(at: now))
        schedule.failed(at: now)
        XCTAssertTrue(schedule.isDue(at: now.addingTimeInterval(30 * 60)))
    }

    @MainActor
    func testFailureDoesNotSeedAndFrontendRequestsRespectRetryDelay() async {
        let now = Date()
        let failed = await NewsPoller.feedIfAvailable(now: now) { nil }
        XCTAssertNil(failed, "A failed fetch must not look like a valid empty feed to the banner seeder")
        let early = await NewsPoller.feedIfAvailable(now: now.addingTimeInterval(30 * 60 - 1)) {
            XCTFail("Frontend requests must not bypass backoff")
            return []
        }
        XCTAssertNil(early)
        let recovered = await NewsPoller.feedIfAvailable(now: now.addingTimeInterval(30 * 60)) {
            [["id": "news-1", "title": "News"]]
        }
        XCTAssertEqual(recovered?.first?["id"] as? String, "news-1")
        let cached = await NewsPoller.feedIfAvailable(now: now.addingTimeInterval(30 * 60 + 6 * 3600 - 1)) {
            XCTFail("A successful feed should be cached for six hours")
            return nil
        }
        XCTAssertEqual(cached?.first?["id"] as? String, "news-1")
    }
}
