import XCTest
@testable import Shopping

final class HomeSharingStatusTests: XCTestCase {
    func testLocalChecksRemainDistinctFromCloudFailureAndAssociationSuccess() throws {
        var engine = CloudSyncStatus()
        engine.record(event(.upload))
        let result = HomeSharingStatus(input: .init(account: .verified, home: .availableOwner,
            ownedStore: engine.snapshot(forStores: ["private"]), ownerAssociationCount: 0,
            localCheckNeedsAttention: true))
        XCTAssertEqual(result.summary.title, "Saved data needs another check")
        XCTAssertTrue(try section(result, .localChecks).presentation.details.contains("drafts are retained"))
        XCTAssertFalse(try section(result, .ownerAssociations).presentation.details.contains("could not be checked"))
        XCTAssertTrue(try section(result, .ownedStore).presentation.details.contains("Successful activity"))
        XCTAssertTrue(result.actions.contains(.checkStatus))
    }

    func testAnnouncementsDeduplicateObservationsButAnnounceRecoveryAndRecurrence() {
        var announcements = HomeSharingStatusAnnouncements()
        XCTAssertNil(announcements.observe(title: "Using saved data"), "Initial screen content is read normally")
        XCTAssertNil(announcements.observe(title: "Using saved data"), "Repeated activity does not interrupt VoiceOver")
        XCTAssertEqual(announcements.observe(title: "Home access unavailable"), "Home access unavailable")
        XCTAssertNil(announcements.observe(title: "Home access unavailable"))
        XCTAssertEqual(announcements.observe(title: "Recent iCloud activity"), "Recent iCloud activity")
        XCTAssertEqual(announcements.observe(title: "Home access unavailable"), "Home access unavailable")
    }

    private func status(account: HomeSharingStatus.Account = .verified,
                        home: HomeSharingStatus.Home = .availableOwner,
                        invitation: HomeSharingStatus.Invitation = .none,
                        engine: CloudSyncStatus = .init(),
                        work: HomeSharingStatus.Work = .init()) -> HomeSharingStatus {
        HomeSharingStatus(input: .init(account: account, home: home, invitation: invitation,
            ownedStore: engine.snapshot(forStores: ["private"]),
            sharedStore: engine.snapshot(forStores: ["shared"]), work: work))
    }

    private func event(_ operation: CloudSyncStatus.Operation, store: String = "private",
                       time: TimeInterval = 1, active: Bool = false,
                       failure: CloudSyncStatus.Failure? = nil) -> CloudSyncStatus.Event {
        .init(store: store, operation: operation, started: Date(timeIntervalSince1970: time),
              ended: active ? nil : Date(timeIntervalSince1970: time + 1), failure: failure)
    }

    private func section(_ status: HomeSharingStatus, _ id: HomeSharingStatus.SectionID) throws -> HomeSharingStatus.Section {
        try XCTUnwrap(status.sections.first { $0.id == id })
    }

    func testUnknownActivityIsNotFailureOrUniversalPendingCount() throws {
        let result = status()
        XCTAssertEqual(result.summary.title, "No recent iCloud activity observed")
        XCTAssertEqual(try section(result, .ownedStore).presentation.symbol, "icloud")
        XCTAssertTrue(try section(result, .sharedStore).presentation.details.contains("Delivery is unknown"))
        XCTAssertTrue(try section(result, .savedWork).presentation.details.contains("not yet known"))
        XCTAssertTrue(result.actions.contains(.returnToHome))
        XCTAssertFalse(result.actions.contains(.openSettings))
    }

    func testOneStoreFailureSurvivesOtherStoreSuccessAndRetryStarting() throws {
        for failingStore in ["private", "shared"] {
            var engine = CloudSyncStatus()
            engine.record(event(.upload, store: failingStore, failure: .quota))
            engine.record(event(.download, store: failingStore == "private" ? "shared" : "private", time: 2))
            engine.record(event(.upload, store: failingStore, time: 3, active: true))
            let result = status(engine: engine)
            let failed = try section(result, failingStore == "private" ? .ownedStore : .sharedStore)
            let healthy = try section(result, failingStore == "private" ? .sharedStore : .ownedStore)
            XCTAssertTrue(result.summary.title.contains("needs attention"))
            XCTAssertTrue(failed.presentation.details.contains("storage is full"))
            XCTAssertTrue(healthy.presentation.details.contains("Successful activity was observed"))
            XCTAssertTrue(failed.actions.contains(.openSettings))
            XCTAssertFalse(healthy.actions.contains(.openSettings))
            XCTAssertNil(failed.lastUpload)
            XCTAssertEqual(healthy.lastDownload, Date(timeIntervalSince1970: 3))
        }
    }

    func testReadOnlyUnavailableAndUnresolvedAccessOverrideSuccessfulActivity() {
        var engine = CloudSyncStatus()
        engine.record(event(.upload))
        for (home, expected) in [(HomeSharingStatus.Home.readOnly, "Home is read-only"),
                                 (.unavailable, "Home access unavailable"),
                                 (.unresolved, "Home access not verified")] {
            let result = status(home: home, engine: engine)
            XCTAssertEqual(result.summary.title, expected)
            XCTAssertEqual(result.actions.contains(.returnToHome), home == .readOnly)
            XCTAssertFalse(result.summary.details.contains("revoked"), "Missing or incomplete home data does not prove revocation")
        }
    }

    func testTemporaryAccountErrorKeepsCalmSavedDataAndRetainsIndependentFailure() throws {
        var engine = CloudSyncStatus()
        engine.record(event(.upload, failure: .network))
        let result = status(account: .cached, engine: engine)
        XCTAssertEqual(result.summary.title, "Using saved data")
        XCTAssertTrue(result.actions.contains(.returnToHome))
        XCTAssertFalse(result.actions.contains(.openSettings))
        XCTAssertTrue(try section(result, .ownedStore).presentation.details.contains("unreachable"))
        for account in [HomeSharingStatus.Account.unavailable, .changed] {
            let unavailable = status(account: account, engine: engine)
            XCTAssertTrue(unavailable.actions.contains(.openSettings))
            XCTAssertFalse(unavailable.actions.contains(.returnToHome))
        }
    }

    func testDelayedInvitationImportDoesNotPromiseDeadlineOrBecomeCloudEngineActivity() throws {
        for (invitation, title) in [(HomeSharingStatus.Invitation.joining, "Joining home"),
                                    (.loading, "Loading invited home"),
                                    (.ready, "Invited home is ready to open"),
                                    (.attention, "Invitation needs attention")] {
            let result = status(invitation: invitation)
            XCTAssertEqual(result.summary.title, title)
            XCTAssertTrue(result.actions.contains(.returnToHome))
            XCTAssertTrue(result.actions.contains(.checkStatus))
            XCTAssertEqual(result.actions.contains(.reviewInvitation), invitation == .ready || invitation == .attention)
            XCTAssertTrue(try section(result, .ownedStore).presentation.details.contains("No upload or download"))
        }
        let importing = status(home: .waitingForImport)
        XCTAssertEqual(importing.summary.title, "Loading home")
        XCTAssertFalse(importing.actions.contains(.returnToHome))
        XCTAssertTrue(importing.summary.details.contains("leave this screen"))
    }

    func testCheckoutUndoHeldSubsetAndAssociationsRemainSeparateFromCloudObservations() throws {
        let result = HomeSharingStatus(input: .init(account: .verified, home: .availableContributor,
            ownedStore: CloudSyncStatus().snapshot(), sharedStore: CloudSyncStatus().snapshot(),
            work: .init(pendingCheckout: 3, pendingUndo: 2, retained: 4, isIncomplete: true),
            ownerAssociationCount: 7))
        let saved = try section(result, .savedWork).presentation.details
        XCTAssertTrue(saved.contains("3 saved checkout operations and 2 saved undo operations"))
        XCTAssertTrue(saved.contains("4 of the pending operations"))
        XCTAssertTrue(saved.contains("counts may be incomplete"))
        XCTAssertFalse(saved.contains("9"), "Held operations must not be added to pending operations")
        XCTAssertTrue(try section(result, .ownerAssociations).presentation.details.contains("not a count of all unsent changes"))
        XCTAssertEqual(result.summary.title, "Saved home changes are held")
        XCTAssertTrue(try section(result, .sharedStore).presentation.details.contains("Delivery is unknown"))
    }

    func testZeroPendingOperationsDoesNotClaimAllChangesDelivered() throws {
        var engine = CloudSyncStatus()
        engine.record(event(.upload))
        let result = status(engine: engine, work: .init(pendingCheckout: 0, pendingUndo: 0, retained: 0))
        XCTAssertEqual(result.summary.title, "Recent iCloud activity")
        XCTAssertTrue(result.summary.details.contains("does not confirm"))
        XCTAssertTrue(try section(result, .savedWork).presentation.details.contains("do not measure CloudKit delivery"))
    }

    func testPendingLocalProcessingRemainsVisibleAfterSuccessfulUpload() {
        var engine = CloudSyncStatus()
        engine.record(event(.upload))
        for work in [HomeSharingStatus.Work(pendingCheckout: 1, pendingUndo: 0, retained: 0),
                     .init(pendingCheckout: 0, pendingUndo: 1, retained: 0)] {
            let result = status(engine: engine, work: work)
            XCTAssertEqual(result.summary.title, "Saved changes awaiting processing")
            XCTAssertTrue(result.summary.details.contains("waiting for the app to finish processing"))
            XCTAssertTrue(result.summary.details.contains("do not measure CloudKit delivery"))
        }
    }

    func testObservedOperationsUseCorrectSendingReceivingAndSetupMeaning() throws {
        for (operation, expected) in [(CloudSyncStatus.Operation.upload, "Sending activity"),
                                      (.download, "Receiving activity"), (.setup, "setup activity")] {
            var engine = CloudSyncStatus()
            engine.record(event(operation, active: true))
            let result = status(engine: engine)
            XCTAssertTrue(try section(result, .ownedStore).presentation.details.contains(expected))
            XCTAssertTrue(try section(result, .sharedStore).presentation.details.contains("Delivery is unknown"))
        }
    }

    func testUnfinishedHistoricalActivityIsUnknownInsteadOfIndefinitelyBusy() throws {
        var engine = CloudSyncStatus()
        engine.record(event(.download, active: true), source: .history)
        let result = status(engine: engine)
        XCTAssertEqual(result.summary.title, "Earlier iCloud activity is unconfirmed")
        XCTAssertEqual(result.summary.symbol, "icloud")
        XCTAssertTrue(try section(result, .ownedStore).presentation.details.contains("may no longer be running"))
        XCTAssertTrue(result.actions.contains(.checkStatus))
        XCTAssertTrue(result.actions.contains(.returnToHome))
    }

    func testDuplicateAndOlderEventsCannotChangePresentationAfterSuccess() {
        var engine = CloudSyncStatus()
        let completion = event(.upload, time: 20)
        engine.record(completion)
        let expected = status(engine: engine)
        engine.record(completion)
        engine.record(event(.upload, time: 1, failure: .permission))
        engine.record(event(.upload, time: 20, active: true))
        XCTAssertEqual(status(engine: engine), expected)
    }

    func testRawStoreIdentityNeverAppearsInPresentation() {
        var engine = CloudSyncStatus()
        let secret = "private-account-id-invite-url-grocery-content"
        engine.record(event(.upload, store: secret, failure: .permission))
        let result = HomeSharingStatus(input: .init(account: .verified, home: .availableOwner,
            ownedStore: engine.snapshot(forStores: [secret])))
        XCTAssertFalse(result.summary.details.contains(secret))
        XCTAssertTrue(result.sections.allSatisfy { !$0.presentation.details.contains(secret) })
        XCTAssertFalse(result.sections.contains { $0.id == .sharedStore }, "An unattached store is not an observed idle store")
        XCTAssertEqual(Set(result.actions.map(\.rawValue)).count, result.actions.count)
    }

    func testAccountWideLeaveAndAssociationFailureDoNotClaimCurrentHomeWasLeft() throws {
        let result = HomeSharingStatus(input: .init(account: .verified, home: .availableOwner,
            associationNeedsAttention: true, leavePendingCount: 2))
        XCTAssertTrue(result.actions.contains(.returnToHome))
        XCTAssertTrue(result.actions.contains(.chooseHome))
        XCTAssertTrue(try section(result, .leavingHomes).presentation.details.contains("different home or device"))
        XCTAssertTrue(try section(result, .ownerAssociations).presentation.details.contains("unknown"))
        XCTAssertTrue(try section(result, .ownerAssociations).presentation.details.contains("could not be checked"))
    }

    func testLocalOnlyDoesNotOfferAccountOrCloudActions() {
        var engine = CloudSyncStatus()
        engine.record(event(.upload, failure: .account))
        let result = status(account: .localOnly, invitation: .attention, engine: engine)
        XCTAssertEqual(result.summary.title, "Saved on this device")
        XCTAssertEqual(result.sections.map(\.id), [.account])
        XCTAssertTrue(result.actions.isEmpty)
    }
}
