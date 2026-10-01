import XCTest
@testable import Shopping

final class HomeSharingActivityTests: XCTestCase {
    private func observations() -> CloudSyncStatus {
        var status = CloudSyncStatus()
        for (store, operation, time) in [("private", CloudSyncStatus.Operation.upload, 10.0),
                                        ("shared", .download, 20.0), ("other-home", .upload, 40.0)] {
            status.record(.init(store: store, operation: operation,
                started: Date(timeIntervalSince1970: time), ended: Date(timeIntervalSince1970: time + 1), failure: nil))
        }
        return status
    }

    func testHealthyHomeOmitsDiagnosticAndZeroOrUnknownWorkNotices() {
        for home in [HomeSharingStatus.Home.availableOwner, .availableContributor] {
            for work in [HomeSharingStatus.Work(), .init(pendingCheckout: 0, pendingUndo: 0, retained: 0)] {
                let activity = HomeSharingActivity(input: .init(account: .verified, home: home,
                    work: work, ownerAssociationCount: 0))
                XCTAssertNil(activity.lastSuccess)
                XCTAssertTrue(activity.notices.isEmpty)
            }
        }
    }

    func testRecentActivityUsesLatestSuccessFromScopedStoresOnly() {
        let status = observations()
        let activity = HomeSharingActivity(input: .init(account: .verified, home: .availableOwner,
            ownedStore: status.snapshot(forStores: ["private"]), sharedStore: status.snapshot(forStores: ["shared"])))
        XCTAssertEqual(activity.lastSuccess, Date(timeIntervalSince1970: 21))
        XCTAssertTrue(activity.notices.isEmpty)
    }

    func testUnavailableOrChangedAccountHidesPreviousAccountActivityAndWork() {
        for account in [HomeSharingStatus.Account.unavailable, .changed, .localOnly] {
            let activity = HomeSharingActivity(input: .init(account: account, home: .availableOwner,
                invitation: .ready, ownedStore: observations().snapshot(),
                work: .init(pendingCheckout: 5, pendingUndo: 4, retained: 3),
                ownerAssociationCount: 8, associationNeedsAttention: true, leavePendingCount: 1))
            XCTAssertNil(activity.lastSuccess)
            XCTAssertTrue(activity.notices.allSatisfy { $0.id == .account })
        }
    }

    func testCloudFailureSurvivesOtherStoreSuccess() throws {
        var status = observations()
        status.record(.init(store: "private", operation: .upload, started: Date(timeIntervalSince1970: 30),
            ended: Date(timeIntervalSince1970: 31), failure: .quota))
        let activity = HomeSharingActivity(input: .init(account: .verified, home: .availableOwner,
            ownedStore: status.snapshot(forStores: ["private"]), sharedStore: status.snapshot(forStores: ["shared"])))
        XCTAssertEqual(activity.lastSuccess, Date(timeIntervalSince1970: 21))
        let failure = try XCTUnwrap(activity.notices.first { $0.id == .cloud })
        XCTAssertEqual(failure.action, .openSettings)
    }

    func testPreparationCountAloneAndHeldChangesCreateNoUnactionableNotice() throws {
        let preparation = HomeSharingActivity(input: .init(account: .verified, home: .availableOwner,
            ownerAssociationCount: 7))
        XCTAssertTrue(preparation.notices.isEmpty)
        let held = HomeSharingActivity(input: .init(account: .verified, home: .availableOwner,
            work: .init(pendingCheckout: 1, pendingUndo: 0, retained: 1)))
        XCTAssertTrue(held.notices.isEmpty, "Held publications cannot be released by reviewing the cart")
        let pending = HomeSharingActivity(input: .init(account: .verified, home: .availableOwner,
            work: .init(pendingCheckout: 1, pendingUndo: 0, retained: 0)))
        XCTAssertTrue(pending.notices.contains { $0.id == .savedWork })
    }
}
