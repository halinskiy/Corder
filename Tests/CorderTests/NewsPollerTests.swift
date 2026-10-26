import XCTest
@testable import Corder

final class NewsPollerTests: XCTestCase {
    @MainActor
    func testFailureDoesNotSeedAnEmptyFeedOrSuppressRetry() async {
        let failed = await NewsPoller.feedIfAvailable { nil }
        XCTAssertNil(failed, "A failed fetch must not look like a valid empty feed to the banner seeder")
        let recovered = await NewsPoller.feedIfAvailable { [["id": "news-1", "title": "News"]] }
        XCTAssertEqual(recovered?.first?["id"] as? String, "news-1")
        let cached = await NewsPoller.feedIfAvailable {
            XCTFail("A successful feed should be cached for six hours")
            return nil
        }
        XCTAssertEqual(cached?.first?["id"] as? String, "news-1")
    }
}
