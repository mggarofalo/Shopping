import XCTest
@testable import Shopping

@MainActor
final class HomeInvitationInboxTests: XCTestCase {
    private let container = "iCloud.test.invitations"
    private let environment = "Development"

    private func fixture() throws -> (URL, ShopperSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory.appendingPathComponent("inbox.json"), try session("account-a"))
    }

    private func session(_ name: String) throws -> ShopperSession {
        try ShopperSession.authenticated(containerIdentifier: container, environment: environment, accountRecordName: name)
    }

    private func inbox(_ url: URL) throws -> HomeInvitationInbox {
        try HomeInvitationInbox(url: url, containerIdentifier: container, environment: environment)
    }

    private func identity(_ name: String = "share", owner: String = "owner") -> HomeInvitationIdentity {
        HomeInvitationIdentity(containerIdentifier: container, environment: environment,
            share: HomeShareIdentity(recordName: name, zoneName: "zone", zoneOwnerName: owner))
    }

    private func graph(store: String = "shared-store") -> HomeGraphIdentity {
        HomeGraphIdentity(storeIdentifier: store, rootURI: "x-coredata://shared/Household/p1",
            householdID: UUID(), listID: UUID())
    }

    func testReopeningAcceptedLinkRestoresOpenIntentWithoutRepeatingAcceptance() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        let acceptance = try service.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        try service.finishAcceptance(acceptance)
        let imported = try service.beginImportResolution(id: entry.id, sharedStoreIdentifier: "shared-store")
        let home = graph()
        try service.markReady(imported, graph: home)
        try service.resolveActivation(id: entry.id)
        let reopened = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        XCTAssertEqual(reopened.id, entry.id)
        XCTAssertEqual(reopened.state, .ready(home))
        XCTAssertFalse(reopened.activationResolved)
        XCTAssertTrue(reopened.openRequested)
        XCTAssertFalse(reopened.requiresNativeAcceptance)
        XCTAssertTrue(service.hasPendingActivation)
        let relaunched = try inbox(url)
        try relaunched.setSession(session)
        XCTAssertEqual(relaunched.entries, [reopened])
        try relaunched.deferOpen(id: entry.id)
        XCTAssertFalse(relaunched.entries[0].openRequested)
    }

    func testColdAndWarmIngressDeduplicateAndPersistBeforeAccountIsReady() throws {
        let (url, session) = try fixture()
        let first = try inbox(url)
        let entry = try first.enqueue(identity: identity(), metadataArchive: Data([1, 2]))
        let duplicate = try first.enqueue(identity: identity(), metadataArchive: Data([3]))
        XCTAssertEqual(entry.id, duplicate.id)
        XCTAssertNil(entry.session)
        XCTAssertTrue(first.hasPendingActivation)
        XCTAssertThrowsError(try first.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store"))
        let restored = try inbox(url)
        XCTAssertEqual(restored.entries, [duplicate])
        try restored.setSession(session)
        XCTAssertEqual(restored.entries.first?.session, session)
        let attempt = try restored.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(attempt.metadataArchive, Data([3]))
        XCTAssertTrue(try restored.finishAcceptance(attempt))
    }

    func testVerifiedDisplayNamePersistsAndOldJournalDecodesWithoutIt() throws {
        let (url, _) = try fixture()
        let service = try inbox(url)
        let first = try service.enqueue(identity: identity(), metadataArchive: Data([1]), displayName: "Kitchen")
        XCTAssertEqual(try inbox(url).entries.first?.displayName, "Kitchen")
        XCTAssertEqual(try service.enqueue(identity: identity(), metadataArchive: Data([2])).displayName,
            "Kitchen", "A link without a title retains the last known plain name")
        let renamed = try service.enqueue(identity: identity(), metadataArchive: Data([3]), displayName: "Our Home")
        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(try inbox(url).entries.first?.displayName, "Our Home")

        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(journal["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "displayName")
        journal["entries"] = entries
        try JSONSerialization.data(withJSONObject: journal).write(to: url, options: .atomic)
        XCTAssertNil(try inbox(url).entries.first?.displayName)
    }

    func testOpenIntentSurvivesImportButDismissalAndNewerChoiceDeferNavigation() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        XCTAssertTrue(entry.openRequested)
        try service.setSession(session)
        let attempt = try service.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        try service.finishAcceptance(attempt)
        XCTAssertTrue(service.entries[0].openRequested)
        try service.deferOpen(id: entry.id)
        let reopened = try inbox(url)
        try reopened.setSession(session)
        XCTAssertFalse(reopened.entries[0].openRequested)
        let imported = graph()
        let resolution = try reopened.beginImportResolution(id: entry.id, sharedStoreIdentifier: imported.storeIdentifier)
        XCTAssertTrue(try reopened.markReady(resolution, graph: imported))
        XCTAssertEqual(reopened.entries[0].state, .ready(imported))
        XCTAssertFalse(reopened.entries[0].openRequested)
        try reopened.requestOpen(id: entry.id)
        XCTAssertTrue(try inbox(url).entries[0].openRequested)
        try reopened.resolveActivation(id: entry.id)
        XCTAssertFalse(reopened.entries[0].openRequested)
        XCTAssertTrue(reopened.entries[0].activationResolved)
    }

    func testUnboundNotNowRetainsInvitationAndHomesOpenRearmsExactIntent() throws {
        let (url, _) = try fixture()
        let service = try inbox(url)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.deferOpen(id: entry.id)
        let deferred = try inbox(url)
        XCTAssertEqual(deferred.entries.first?.id, entry.id)
        XCTAssertEqual(deferred.entries.first?.state, .queued)
        XCTAssertFalse(deferred.entries.first?.openRequested == true)
        try deferred.requestOpen(id: entry.id)
        XCTAssertTrue(try inbox(url).entries.first?.openRequested == true)
    }

    func testColdDuplicateKeepsItsDeferredChoiceWhenMergedIntoBoundInvitation() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let bound = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.setSession(nil)
        let cold = try service.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertNotEqual(cold.id, bound.id)
        try service.deferOpen(id: cold.id)
        try service.setSession(session)

        let merged = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(merged.id, bound.id)
        XCTAssertEqual(merged.metadataArchive, Data([2]))
        XCTAssertFalse(merged.openRequested)
        let relaunched = try inbox(url)
        try relaunched.setSession(session)
        XCTAssertFalse(relaunched.entries.first?.openRequested == true)
    }

    func testDeferredInvitationFromOriginalAccountCannotBeRearmedByAnotherAccount() throws {
        let (url, originalSession) = try fixture()
        let otherSession = try session("account-b")
        let service = try inbox(url)
        try service.setSession(originalSession)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.deferOpen(id: entry.id)
        try service.setSession(otherSession)
        XCTAssertThrowsError(try service.requestOpen(id: entry.id))
        XCTAssertThrowsError(try service.deferOpen(id: entry.id))
        XCTAssertFalse(service.entries[0].openRequested)
        try service.setSession(originalSession)
        XCTAssertFalse(service.entries[0].openRequested)
    }

    func testAccountBoundaryDurablyDefersOnlyBoundOldNavigationAndKeepsManualOpen() throws {
        let (url, originalSession) = try fixture()
        let otherSession = try session("account-b")
        let service = try inbox(url)
        try service.setSession(originalSession)
        let old = try service.enqueue(identity: identity("old"), metadataArchive: Data([1]))
        let attempt = try service.beginAcceptance(id: old.id, sharedStoreIdentifier: "shared-store")
        try service.finishAcceptance(attempt)
        try service.setSession(otherSession)
        let current = try service.enqueue(identity: identity("current"), metadataArchive: Data([2]))
        try service.setSession(nil)
        let cold = try service.enqueue(identity: identity("cold"), metadataArchive: Data([3]))

        try service.retireAutomaticOpen(boundToOtherAccountThan: otherSession)
        let restored = try inbox(url)
        XCTAssertEqual(restored.entries.first { $0.id == old.id }?.state, .loading)
        XCTAssertFalse(restored.entries.first { $0.id == old.id }?.openRequested == true)
        XCTAssertTrue(restored.entries.first { $0.id == current.id }?.openRequested == true)
        XCTAssertTrue(restored.entries.first { $0.id == cold.id }?.openRequested == true,
            "An unbound native delivery still opens after its account is verified")

        try restored.setSession(originalSession)
        try restored.requestOpen(id: old.id)
        XCTAssertTrue(try inbox(url).entries.first { $0.id == old.id }?.openRequested == true)
        try restored.setSession(nil)
        try restored.retireAutomaticOpen(boundTo: originalSession)
        XCTAssertFalse(try inbox(url).entries.first { $0.id == old.id }?.openRequested == true)
    }

    func testPersistedUnknownAccountInvalidationDefersAllBoundButNotFreshUnboundIngress() throws {
        let (url, originalSession) = try fixture()
        let otherSession = try session("account-b")
        let service = try inbox(url)
        try service.setSession(originalSession)
        let original = try service.enqueue(identity: identity("old"), metadataArchive: Data([1]))
        try service.setSession(otherSession)
        let other = try service.enqueue(identity: identity("other"), metadataArchive: Data([2]))
        try service.setSession(nil)
        let fresh = try service.enqueue(identity: identity("cold"), metadataArchive: Data([3]))

        try service.retireAutomaticOpenForAllBoundAccounts()
        let relaunched = try inbox(url)
        XCTAssertFalse(relaunched.entries.first { $0.id == original.id }?.openRequested == true)
        XCTAssertFalse(relaunched.entries.first { $0.id == other.id }?.openRequested == true)
        XCTAssertTrue(relaunched.entries.first { $0.id == fresh.id }?.openRequested == true)
        try relaunched.setSession(originalSession)
        try relaunched.requestOpen(id: original.id)
        XCTAssertTrue(try inbox(url).entries.first { $0.id == original.id }?.openRequested == true)
    }

    func testCachedAccountCanDeferOnlyItsOwnNavigationIntent() throws {
        let (url, originalSession) = try fixture()
        let otherSession = try session("account-b")
        let service = try inbox(url)
        try service.setSession(originalSession)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.setSession(nil)
        XCTAssertThrowsError(try service.deferOpen(id: entry.id, expectedSession: otherSession))
        try service.deferOpen(id: entry.id, expectedSession: originalSession)
        XCTAssertFalse(service.entries[0].openRequested)
        XCTAssertThrowsError(try service.requestOpen(id: entry.id),
            "A cached account can stop navigation but cannot start an invitation operation")
    }

    func testAlreadyAcceptedColdDuplicateCollapsesAfterAuthentication() throws {
        let (url, session) = try fixture()
        let first = try inbox(url)
        try first.setSession(session)
        let entry = try first.enqueue(identity: identity(), metadataArchive: Data([1]))
        let attempt = try first.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        try first.finishAcceptance(attempt)
        let restored = try inbox(url)
        _ = try restored.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertEqual(restored.entries.count, 2)
        try restored.setSession(session)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries[0].id, entry.id)
        XCTAssertEqual(restored.entries[0].state, .loading)
        let duplicate = try restored.enqueue(identity: identity(), metadataArchive: Data([3]))
        XCTAssertEqual(duplicate.id, entry.id)
        XCTAssertThrowsError(try restored.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store"))
    }

    func testTwoInvitationsAreSerializedAndDismissalDoesNotReleaseNativeGate() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let first = try service.enqueue(identity: identity("first"), metadataArchive: Data([1]))
        let second = try service.enqueue(identity: identity("second"), metadataArchive: Data([2]))
        let attempt = try service.beginAcceptance(id: first.id, sharedStoreIdentifier: "shared-store")
        try service.dismiss(id: first.id)
        XCTAssertTrue(service.isAcceptanceInFlight)
        XCTAssertTrue(service.hasPendingActivation)
        XCTAssertThrowsError(try service.beginAcceptance(id: second.id, sharedStoreIdentifier: "shared-store"))
        try service.finishAcceptance(attempt)
        XCTAssertEqual(service.entries[0].state, .loading)
        XCTAssertTrue(service.entries[0].dismissalRequested)
        let next = try service.beginAcceptance(id: second.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(next.entryID, second.id)
        try service.finishAcceptance(next, failure: .acceptance("Offline. Try again."))
    }

    func testAccountChangeRetainsOriginalSuccessWithoutRebindingOrReleasingGateEarly() throws {
        let (url, firstSession) = try fixture()
        let secondSession = try session("account-b")
        let service = try inbox(url)
        try service.setSession(firstSession)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        let attempt = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        try service.setSession(secondSession)
        XCTAssertFalse(service.hasPendingActivation)
        XCTAssertTrue(service.isAcceptanceInFlight)
        let other = try service.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertNotEqual(other.id, original.id)
        XCTAssertThrowsError(try service.beginAcceptance(id: other.id, sharedStoreIdentifier: "other-store"))
        XCTAssertFalse(try service.finishAcceptance(attempt))
        XCTAssertEqual(service.entries.first?.session, firstSession)
        XCTAssertEqual(service.entries.first?.state, .loading)
        XCTAssertEqual(service.entriesForCurrentSession.map(\.id), [other.id])
        XCTAssertThrowsError(try service.retry(id: original.id))
        try service.setSession(firstSession)
        XCTAssertEqual(service.entriesForCurrentSession.map(\.id), [original.id])
        XCTAssertTrue(service.hasPendingActivation)
    }

    func testRelaunchDuringJoiningRequiresExplicitRetryAndRetainsStoreAndArchive() throws {
        let (url, session) = try fixture()
        let first = try inbox(url)
        try first.setSession(session)
        let entry = try first.enqueue(identity: identity(), metadataArchive: Data([1]))
        _ = try first.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        let restored = try inbox(url)
        try restored.setSession(session)
        XCTAssertEqual(restored.entries[0].state, .failed(.interrupted))
        XCTAssertThrowsError(try restored.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store"))
        try restored.retry(id: entry.id)
        XCTAssertThrowsError(try restored.beginAcceptance(id: entry.id, sharedStoreIdentifier: "replacement-store"))
        let retried = try restored.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(retried.entryID, entry.id)
        XCTAssertEqual(retried.metadataArchive, Data([1]))
        try restored.finishAcceptance(retried)
    }

    func testLoadingSurvivesRestartAndReadyRequiresCurrentSessionAndExactSharedStore() throws {
        let (url, session) = try fixture()
        let first = try inbox(url)
        try first.setSession(session)
        let entry = try first.enqueue(identity: identity(), metadataArchive: Data([1]))
        try first.finishAcceptance(first.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store"))
        let restored = try inbox(url)
        XCTAssertTrue(restored.hasPendingActivation, "Cached-account discovery must not autoactivate an imported invitation")
        XCTAssertTrue(restored.entriesForCurrentSession.isEmpty, "Bound details need verified account authority")
        try restored.setSession(session)
        XCTAssertEqual(restored.entries[0].state, .loading)
        XCTAssertThrowsError(try restored.retry(id: entry.id))
        let stale = try restored.beginImportResolution(id: entry.id, sharedStoreIdentifier: "shared-store")
        try restored.setSession(nil)
        try restored.setSession(session)
        XCTAssertFalse(try restored.markReady(stale, graph: graph()))
        let current = try restored.beginImportResolution(id: entry.id, sharedStoreIdentifier: "shared-store")
        XCTAssertThrowsError(try restored.markReady(current, graph: graph(store: "private-store")))
        let imported = graph()
        XCTAssertTrue(try restored.markReady(current, graph: imported))
        XCTAssertTrue(restored.hasPendingActivation)
        try restored.dismiss(id: entry.id)
        XCTAssertTrue(restored.hasPendingActivation)
        XCTAssertEqual(restored.entries[0].state, .ready(imported))
        try restored.resolveActivation(id: entry.id)
        XCTAssertFalse(restored.hasPendingActivation)
        let reopened = try inbox(url)
        try reopened.setSession(session)
        XCTAssertFalse(reopened.hasPendingActivation)
    }

    func testFailureRetryIsExplicitAndUnboundDismissalDoesNotHoldActivation() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        let dismissed = try service.enqueue(identity: identity("dismissed"), metadataArchive: Data([1]))
        try service.dismiss(id: dismissed.id)
        XCTAssertFalse(service.hasPendingActivation)
        try service.setSession(session)
        let entry = try service.enqueue(identity: identity("retry"), metadataArchive: Data([2]))
        let attempt = try service.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        XCTAssertThrowsError(try service.retry(id: entry.id))
        try service.finishAcceptance(attempt, failure: .acceptance("Invitation could not be accepted."))
        XCTAssertEqual(service.entries.last?.state, .failed(.acceptance("Invitation could not be accepted.")))
        try service.retry(id: entry.id)
        XCTAssertEqual(service.entries.last?.state, .queued)
        XCTAssertThrowsError(try service.resolveActivation(id: entry.id))
    }

    func testInvalidIdentityCorruptJournalAndFutureVersionFailWithoutReplacement() throws {
        let (url, _) = try fixture()
        let service = try inbox(url)
        let foreign = HomeInvitationIdentity(containerIdentifier: "iCloud.foreign", environment: environment, share: identity().share)
        XCTAssertThrowsError(try service.enqueue(identity: foreign, metadataArchive: Data([1])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let corrupt = Data("not a journal".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try inbox(url))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let future = Data("{\"version\":99,\"entries\":[]}".utf8)
        try future.write(to: url)
        XCTAssertThrowsError(try inbox(url))
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testZoneOwnerIsPartOfIdentityAndSessionCannotCrossEnvironment() throws {
        let (url, _) = try fixture()
        let service = try inbox(url)
        let first = try service.enqueue(identity: identity(owner: "owner-a"), metadataArchive: Data([1]))
        let second = try service.enqueue(identity: identity(owner: "owner-b"), metadataArchive: Data([2]))
        XCTAssertNotEqual(first.id, second.id)
        let foreign = try ShopperSession.authenticated(containerIdentifier: container, environment: "Production", accountRecordName: "account-a")
        XCTAssertThrowsError(try service.setSession(foreign))
        XCTAssertNil(service.currentSession)
        XCTAssertTrue(service.entries.allSatisfy { $0.session == nil })
    }

    func testReopeningDismissedLinkRestoresQueueButNeverReacceptsImportedHome() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        let initial = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.dismiss(id: initial.id)
        let reopened = try service.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertEqual(reopened.id, initial.id)
        XCTAssertEqual(reopened.state, .queued)
        XCTAssertFalse(reopened.dismissalRequested)
        try service.setSession(session)
        let acceptance = try service.beginAcceptance(id: initial.id, sharedStoreIdentifier: "shared-store")
        try service.finishAcceptance(acceptance)
        let resolution = try service.beginImportResolution(id: initial.id, sharedStoreIdentifier: "shared-store")
        let imported = graph()
        try service.markReady(resolution, graph: imported)
        try service.dismiss(id: initial.id)
        let ready = try service.enqueue(identity: identity(), metadataArchive: Data([3]))
        XCTAssertEqual(ready.state, .ready(imported))
        XCTAssertFalse(ready.dismissalRequested)
        XCTAssertThrowsError(try service.beginAcceptance(id: initial.id, sharedStoreIdentifier: "shared-store"))
    }

    func testColdReopenOfDismissedBoundInvitationReusesOriginalIdentity() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.dismiss(id: original.id)
        let restored = try inbox(url)
        XCTAssertThrowsError(try restored.dismiss(id: original.id), "An unauthenticated UI cannot change bound entries")
        _ = try restored.enqueue(identity: identity(), metadataArchive: Data([2]))
        try restored.setSession(session)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries[0].id, original.id)
        XCTAssertEqual(restored.entries[0].state, .queued)
    }

    func testFailedJournalWriteCannotStartAcceptanceAndCallbackFailureRemainsRetryable() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let entry = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try service.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store"))
        XCTAssertFalse(service.isAcceptanceInFlight)
        XCTAssertEqual(service.entries[0].state, .queued)
        try FileManager.default.removeItem(at: url)
        let attempt = try service.beginAcceptance(id: entry.id, sharedStoreIdentifier: "shared-store")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try service.finishAcceptance(attempt))
        XCTAssertFalse(service.isAcceptanceInFlight)
        XCTAssertEqual(service.entries[0].state, .failed(.interrupted))
        try FileManager.default.removeItem(at: url)
        try service.retry(id: entry.id)
        XCTAssertEqual(service.entries[0].state, .queued)
    }

    func testReplacementLinkRecoversFailedParticipantWithoutReplacingInvitationIdentity() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        let attempt = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        try service.finishAcceptance(attempt, failure: .acceptance("The old invitation expired."))
        let replacement = try service.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.session, session)
        XCTAssertEqual(replacement.state, .queued)
        let retried = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(retried.metadataArchive, Data([2]))
        _ = try service.enqueue(identity: identity(), metadataArchive: Data([3]))
        XCTAssertEqual(retried.metadataArchive, Data([2]), "The active native attempt retains its original capability")
        XCTAssertEqual(service.entries[0].metadataArchive, Data([3]), "The replacement must remain available after failure")
        try service.finishAcceptance(retried, failure: .acceptance("The earlier link expired."))
        XCTAssertEqual(service.entries[0].state, .failed(.acceptance("The earlier link expired.")))
        try service.retry(id: original.id)
        let latest = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(latest.metadataArchive, Data([3]))
        try service.finishAcceptance(latest)
    }

    func testPendingReinvitationRequiresNativeAcceptanceAndANewExplicitChoice() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.finishAcceptance(service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store"))
        let resolution = try service.beginImportResolution(id: original.id, sharedStoreIdentifier: "shared-store")
        let originalGraph = graph()
        try service.markReady(resolution, graph: originalGraph)
        try service.resolveActivation(id: original.id)
        let ordinary = try service.enqueue(identity: identity(), metadataArchive: Data([2]))
        XCTAssertEqual(ordinary.state, .ready(originalGraph))
        XCTAssertFalse(ordinary.requiresNativeAcceptance)
        XCTAssertTrue(ordinary.openRequested)
        XCTAssertTrue(service.hasPendingActivation, "Reopening an accepted link requests navigation, not another acceptance")
        let reinvited = try service.enqueue(identity: identity(), metadataArchive: Data([3]), participantPending: true)
        XCTAssertEqual(reinvited.id, original.id)
        XCTAssertEqual(reinvited.state, .queued)
        XCTAssertTrue(reinvited.requiresNativeAcceptance)
        XCTAssertTrue(service.hasPendingActivation)
        let acceptance = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertTrue(acceptance.requiresNativeAcceptance)
        try service.finishAcceptance(acceptance, failure: .acceptance("Offline"))
        XCTAssertTrue(service.entries[0].requiresNativeAcceptance)
        let restored = try inbox(url)
        try restored.setSession(session)
        try restored.retry(id: original.id)
        let retry = try restored.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertTrue(retry.requiresNativeAcceptance)
        XCTAssertEqual(retry.metadataArchive, Data([3]))
        try restored.finishAcceptance(retry)
        XCTAssertFalse(restored.entries[0].requiresNativeAcceptance)
        let imported = try restored.beginImportResolution(id: original.id, sharedStoreIdentifier: "shared-store")
        let newGraph = graph()
        try restored.markReady(imported, graph: newGraph)
        XCTAssertEqual(restored.entries[0].state, .ready(newGraph))
        XCTAssertTrue(restored.hasPendingActivation)
    }

    func testColdPendingReinvitationPreservesRenewalThroughAuthenticationAndRelaunch() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.finishAcceptance(service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store"))
        try service.markReady(service.beginImportResolution(id: original.id, sharedStoreIdentifier: "shared-store"), graph: graph())
        try service.resolveActivation(id: original.id)
        let cold = try inbox(url)
        _ = try cold.enqueue(identity: identity(), metadataArchive: Data([2]), participantPending: true)
        let restarted = try inbox(url)
        try restarted.setSession(session)
        XCTAssertEqual(restarted.entries.count, 1)
        XCTAssertEqual(restarted.entries[0].id, original.id)
        XCTAssertEqual(restarted.entries[0].state, .queued)
        XCTAssertTrue(restarted.entries[0].requiresNativeAcceptance)
        let attempt = try restarted.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertEqual(attempt.metadataArchive, Data([2]))
        XCTAssertTrue(attempt.requiresNativeAcceptance)
        try restarted.finishAcceptance(attempt)
    }

    func testPendingRenewalWhileLoadingRejectsThePreviousImportCallbackAfterReacceptance() throws {
        let (url, session) = try fixture()
        let service = try inbox(url)
        try service.setSession(session)
        let original = try service.enqueue(identity: identity(), metadataArchive: Data([1]))
        try service.finishAcceptance(service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store"))
        let staleImport = try service.beginImportResolution(id: original.id, sharedStoreIdentifier: "shared-store")
        let renewed = try service.enqueue(identity: identity(), metadataArchive: Data([2]), participantPending: true)
        XCTAssertEqual(renewed.state, .queued)
        XCTAssertTrue(renewed.requiresNativeAcceptance)
        let acceptance = try service.beginAcceptance(id: original.id, sharedStoreIdentifier: "shared-store")
        XCTAssertTrue(acceptance.requiresNativeAcceptance)
        XCTAssertEqual(acceptance.metadataArchive, Data([2]))
        try service.finishAcceptance(acceptance)
        XCTAssertEqual(service.entries[0].state, .loading)
        XCTAssertFalse(try service.markReady(staleImport, graph: graph()))
        XCTAssertEqual(service.entries[0].state, .loading)
        let currentImport = try service.beginImportResolution(id: original.id, sharedStoreIdentifier: "shared-store")
        let imported = graph()
        XCTAssertTrue(try service.markReady(currentImport, graph: imported))
        XCTAssertEqual(service.entries[0].state, .ready(imported))
        XCTAssertTrue(service.hasPendingActivation)
    }

    func testBlockedWorkerLeavesMainActorResponsiveAndPreservesFIFOOperationSnapshots() async throws {
        enum WorkerFailure: Error { case timedOut }
        let (url, _) = try fixture()
        let container = container, environment = environment, identity = identity()
        let entered = expectation(description: "Factory entered its worker queue")
        let firstFinished = expectation(description: "First operation finished")
        let secondFinished = expectation(description: "Second operation finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let worker = HomeInvitationWorker(factory: {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw WorkerFailure.timedOut }
            return try HomeInvitationInbox(url: url, containerIdentifier: container, environment: environment)
        })
        worker.perform({ inbox in
            XCTAssertFalse(Thread.isMainThread)
            return try inbox.enqueue(identity: identity, metadataArchive: Data([1])).id
        }, completion: { result in
            switch result {
            case .success(let result):
                XCTAssertEqual(result.snapshot.revision, 1)
                XCTAssertEqual(result.snapshot.entries.map(\.id), [result.value])
            case .failure(let error): XCTFail("First worker operation failed: \(error)")
            }
            firstFinished.fulfill()
        })
        worker.perform({ $0.entries.count }, completion: { result in
            XCTAssertFalse(Thread.isMainThread)
            switch result {
            case .success(let result):
                XCTAssertEqual(result.value, 1)
                XCTAssertEqual(result.snapshot.revision, 2)
                XCTAssertTrue(result.snapshot.hasPendingActivation)
            case .failure(let error): XCTFail("Second worker operation failed: \(error)")
            }
            secondFinished.fulfill()
        })
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(Thread.isMainThread, "The main actor can continue while journal opening is held")
        release.signal()
        await fulfillment(of: [firstFinished, secondFinished], timeout: 5)
    }

    func testWorkerFailureCanBeFollowedByAnOrderedRecoverySnapshot() async throws {
        enum WorkerFailure: Error { case interrupted }
        let (url, _) = try fixture()
        let worker = HomeInvitationWorker(inbox: try inbox(url))
        let identity = identity()
        let failed = expectation(description: "Failed operation delivered")
        let recovered = expectation(description: "Recovery snapshot delivered")
        worker.perform({ inbox -> Bool in
            _ = try inbox.enqueue(identity: identity, metadataArchive: Data([1]))
            throw WorkerFailure.interrupted
        }, completion: { result in
            guard case .failure = result else { XCTFail("Expected an operation failure"); failed.fulfill(); return }
            failed.fulfill()
        })
        worker.perform({ $0.entries.count }, completion: { result in
            switch result {
            case .success(let result):
                XCTAssertEqual(result.value, 1)
                XCTAssertEqual(result.snapshot.revision, 1, "Only successful operations issue snapshot revisions")
                XCTAssertEqual(result.snapshot.entries.first?.identity, identity)
            case .failure(let error): XCTFail("Recovery failed: \(error)")
            }
            recovered.fulfill()
        })
        await fulfillment(of: [failed, recovered], timeout: 5)
    }
}
