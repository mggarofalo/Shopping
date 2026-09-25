import XCTest
@testable import ShoppingWatch

final class WatchSyncStatusTests: XCTestCase {
    func testWaitingWorkingAndCompletedAreObservedStatesWithoutDeliveryClaim() {
        var cloud = CloudSyncStatus()
        XCTAssertEqual(WatchSyncStatus(cloud: cloud).state, .waiting)
        cloud.record(.init(store: "private", operation: .upload, started: Date(timeIntervalSince1970: 1), ended: nil, failure: nil))
        XCTAssertEqual(WatchSyncStatus(cloud: cloud).state, .working)
        cloud.record(.init(store: "private", operation: .upload, started: Date(timeIntervalSince1970: 1), ended: Date(), failure: nil))
        let finished = WatchSyncStatus(cloud: cloud)
        XCTAssertEqual(finished.state, .recentActivity)
        XCTAssertTrue(finished.details.contains("does not confirm another device"))
    }

    func testSetupCompletionAloneDoesNotBecomeCompletedSync() {
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .setup, started: Date(timeIntervalSince1970: 1), ended: Date(), failure: nil))
        XCTAssertEqual(WatchSyncStatus(cloud: cloud).state, .waiting)
    }

    func testCloudFailureWinsOverWorkingAndCompletionFromOtherStore() {
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .upload, started: Date(timeIntervalSince1970: 1), ended: Date(), failure: .quota))
        cloud.record(.init(store: "shared", operation: .download, started: Date(), ended: nil, failure: nil))
        XCTAssertEqual(WatchSyncStatus(cloud: cloud).state, .attention)
        cloud.record(.init(store: "shared", operation: .download, started: Date(), ended: Date(), failure: nil))
        let status = WatchSyncStatus(cloud: cloud)
        XCTAssertEqual(status.state, .attention)
        XCTAssertTrue(status.details.contains("storage is full"))
    }

    func testAccountSharingHistoryAndOperationAttentionSurviveRoutineCompletion() {
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .upload, started: Date(timeIntervalSince1970: 1), ended: Date(), failure: nil))
        let messages = ["Account requires attention", "Household sharing pending", "History refresh failed", "Checkout recovery pending"]
        let status = WatchSyncStatus(cloud: cloud, attentionMessages: messages + [messages[0]])
        XCTAssertEqual(status.state, .attention)
        for message in messages { XCTAssertTrue(status.details.contains(message)) }
        XCTAssertEqual(status.details.components(separatedBy: messages[0]).count, 2)
        XCTAssertEqual(status.title, "Sync needs attention")
    }
}
