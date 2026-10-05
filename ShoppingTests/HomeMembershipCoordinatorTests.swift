import CloudKit
import XCTest
@testable import Shopping

@MainActor
final class HomeMembershipCoordinatorTests: XCTestCase {
    private func fixture() throws -> (URL, ActiveHomeScope, MembershipTransportDouble) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.members",
            environment: "Development", accountRecordName: "owner")
        let scope = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "store",
            rootURI: "x-coredata://store/Household/p1", householdID: UUID(), listID: UUID()))
        let url = directory.appendingPathComponent("invitations/intent.json")
        return (url, scope, MembershipTransportDouble(scope: scope, journalURL: url))
    }

    private func saved(_ url: URL, scope: ActiveHomeScope, phase: HomeInviteJournal.Phase) throws -> HomeInviteJournal.Intent {
        let journal = HomeInviteJournal(url: url)
        var intent = try journal.begin(scope: scope, share: MembershipTransportDouble.share,
            material: HomeInviteMaterial(participantID: "restored", archive: Data([0, 255, 1, 2])), baseChangeTag: "old")
        intent.phase = phase
        try journal.update(intent)
        return intent
    }

    private func expect(_ expected: HomeMembershipError,
                        operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? HomeMembershipError, expected, file: file, line: line) }
    }

    func testInvitePersistsOriginalArchiveAndCoalescesUntilPresentationAcknowledged() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let first = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        let restored = try XCTUnwrap(HomeInviteJournal(url: url).load(scope: scope))
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.phase, .applied)
        XCTAssertEqual(restored.material.archive, Data([1, 0, 255]))
        let atSubmission = await transport.journalAtSubmission
        XCTAssertEqual(atSubmission.first?.phase, .submitted)
        XCTAssertEqual(atSubmission.first?.material, restored.material)
        XCTAssertEqual(atSubmission.first?.id, first.id)
        let duplicate = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(first.id, duplicate.id)
        let before = await transport.counts()
        XCTAssertEqual(before.created, 1)
        XCTAssertEqual(before.added, 1)
        try await coordinator.acknowledge(first, journalURL: url)
        let second = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertNotEqual(second.participantID, first.participantID)
        try await coordinator.acknowledge(first, journalURL: url)
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.id, second.id,
            "A delayed presentation acknowledgement must not erase the next invitation.")
    }

    func testRefreshRetiresAcceptedAndPreviouslyAppliedMissingInvitations() async throws {
        for accepted in [false, true] {
            let (url, scope, transport) = try fixture()
            let intent = try saved(url, scope: scope, phase: accepted ? .submitted : .applied)
            if accepted { await transport.include(intent.material.participantID, acceptance: .accepted) }
            let coordinator = HomeMembershipCoordinator()
            _ = try await coordinator.refresh(scope: scope, journalURL: url, transport: transport)
            let pending = try await coordinator.pending(scope: scope, journalURL: url)
            XCTAssertNil(pending)
            let next = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
            XCTAssertNotEqual(next.participantID, intent.material.participantID)
            let counts = await transport.counts()
            XCTAssertEqual(counts.added, 1)
        }
    }

    func testRestartSubmittedPresentRecoversExactParticipantWithoutAnotherAdd() async throws {
        let (url, scope, transport) = try fixture()
        let intent = try saved(url, scope: scope, phase: .submitted)
        await transport.include(intent.material.participantID, acceptance: .pending)
        let delivery = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(delivery.id, intent.id)
        XCTAssertEqual(delivery.participantID, intent.material.participantID)
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.material, intent.material)
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
    }

    func testRestartSubmittedAbsentRemainsUncertainAcrossRepeatedAttempts() async throws {
        let (url, scope, transport) = try fixture()
        let intent = try saved(url, scope: scope, phase: .submitted)
        for _ in 0..<2 {
            await expect(.outcomeUncertain) {
                _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
            }
        }
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope), intent)
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
    }

    func testCallbackFailureAfterServerApplicationReconcilesSameParticipant() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setMode(.applyThenFail)
        let delivery = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(delivery.participantID, "invited-1")
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.phase, .applied)
        let counts = await transport.counts()
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.refreshed, 2)
    }

    func testNativeFailureWithoutObservedApplicationDoesNotAuthorizeRetry() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setMode(.fail)
        let coordinator = HomeMembershipCoordinator()
        await expect(.outcomeUncertain) {
            _ = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        }
        await transport.setMode(.succeed)
        await expect(.outcomeUncertain) {
            _ = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        }
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.phase, .submitted)
        let counts = await transport.counts()
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.created, 1)
    }

    func testNotSubmittedCloudFailurePreservesCauseAndSameInvitationForRetry() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setPreflightFailure(CKError(.networkUnavailable))
        let coordinator = HomeMembershipCoordinator()
        do {
            _ = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
            XCTFail("Expected preflight failure")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        }
        let intent = try XCTUnwrap(HomeInviteJournal(url: url).load(scope: scope))
        XCTAssertEqual(intent.phase, .prepared)
        await transport.setPreflightFailure(nil)
        let delivery = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(delivery.id, intent.id)
        XCTAssertEqual(delivery.participantID, intent.material.participantID)
    }

    func testKnownNotSubmittedAllowsExplicitRetryUsingArchivedMaterialAndFreshTag() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setMode(.notSubmitted)
        let coordinator = HomeMembershipCoordinator()
        await expect(.membershipChanged) {
            _ = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        }
        let prepared = try XCTUnwrap(HomeInviteJournal(url: url).load(scope: scope))
        XCTAssertEqual(prepared.phase, .prepared)
        await transport.setMode(.succeed)
        await transport.setTag("new-tag")
        let delivery = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(delivery.id, prepared.id)
        let materials = await transport.submittedMaterials
        XCTAssertEqual(materials, [prepared.material, prepared.material])
        XCTAssertEqual(try HomeInviteJournal(url: url).load(scope: scope)?.baseChangeTag, "new-tag")
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 1)
    }

    func testAcceptedOutstandingInvitationClearsWithoutGeneratingURLOrAnotherInvitation() async throws {
        let (url, scope, transport) = try fixture()
        let intent = try saved(url, scope: scope, phase: .submitted)
        await transport.include(intent.material.participantID, acceptance: .accepted)
        await expect(.invitationAlreadyAccepted) {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        }
        XCTAssertNil(try HomeInviteJournal(url: url).load(scope: scope))
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.urls, 0)
        _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        let later = await transport.counts()
        XCTAssertEqual(later.created, 1)
    }

    func testMissingURLRetainsAppliedIntentAndResendChecksCurrentAcceptance() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setURLFailure(true)
        let coordinator = HomeMembershipCoordinator()
        await expect(.missingURL) {
            _ = try await coordinator.invite(scope: scope, journalURL: url, transport: transport)
        }
        let intent = try XCTUnwrap(HomeInviteJournal(url: url).load(scope: scope))
        XCTAssertEqual(intent.phase, .applied)
        await transport.setURLFailure(false)
        let delivery = try await coordinator.resend(participantID: intent.material.participantID,
            scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(delivery.id, intent.id)
        try await coordinator.acknowledge(delivery, journalURL: url)
        await transport.include(delivery.participantID, acceptance: .accepted)
        let before = await transport.counts()
        await expect(.invitationAlreadyAccepted) {
            _ = try await coordinator.resend(participantID: delivery.participantID,
                scope: scope, journalURL: url, transport: transport)
        }
        let after = await transport.counts()
        XCTAssertEqual(after.urls, before.urls)
    }

    func testPreviouslyAppliedButNowRemovedParticipantReleasesResolvedIntentOnly() async throws {
        let (url, scope, transport) = try fixture()
        _ = try saved(url, scope: scope, phase: .applied)
        await expect(.invitationUnavailable) {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        }
        XCTAssertNil(try HomeInviteJournal(url: url).load(scope: scope))
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
    }

    func testCancelledWaiterKeepsMutationGateAndConcurrentInviteCoalesces() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setMode(.hold)
        let coordinator = HomeMembershipCoordinator()
        let first = Task { try await coordinator.invite(scope: scope, journalURL: url, transport: transport) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await transport.isHeld) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await transport.isHeld
        guard held else {
            first.cancel()
            await transport.release()
            _ = await first.result
            XCTFail("Native operation did not start")
            return
        }
        first.cancel()
        let second = Task { try await coordinator.invite(scope: scope, journalURL: url, transport: transport) }
        let refresh = Task { try await coordinator.refresh(scope: scope, journalURL: url, transport: transport) }
        let queueDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await coordinator.activeRequestCount != 3, ContinuousClock.now < queueDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let queued = await coordinator.activeRequestCount
        XCTAssertEqual(queued, 3, "Both commands must enter the coordinator while the native operation remains held.")
        await transport.release()
        let results = await (first.result, second.result, refresh.result)
        let firstDelivery = try results.0.get()
        let secondDelivery = try results.1.get()
        _ = try results.2.get()
        XCTAssertEqual(firstDelivery.id, secondDelivery.id)
        let counts = await transport.counts()
        XCTAssertEqual(counts.created, 1)
        XCTAssertEqual(counts.added, 1)
        let overlap = await transport.refreshOverlappedAdd
        XCTAssertFalse(overlap)
    }

    func testWrongScopeAndCorruptionFailBeforeTransportEffects() async throws {
        let (url, scope, transport) = try fixture()
        _ = try saved(url, scope: scope, phase: .prepared)
        let otherSession = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "other")
        let other = ActiveHomeScope(session: otherSession, graph: scope.graph)
        await expect(.scopeChanged) {
            _ = try await HomeMembershipCoordinator().invite(scope: other, journalURL: url, transport: transport)
        }
        let corrupt = Data("not a journal".utf8)
        try corrupt.write(to: url)
        await expect(.invalidJournal) {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let counts = await transport.counts()
        XCTAssertEqual(counts.refreshed, 0)
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
    }

    func testUnverifiedOwnerAndJournalWriteFailureCannotSubmit() async throws {
        let (url, scope, transport) = try fixture()
        await transport.setOwner(false)
        await expect(.ownerRequired) {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
        }
        await transport.setOwner(true)
        try Data([1]).write(to: url.deletingLastPathComponent())
        do {
            _ = try await HomeMembershipCoordinator().invite(scope: scope, journalURL: url, transport: transport)
            XCTFail("A non-directory journal parent must fail before submission")
        } catch { }
        let counts = await transport.counts()
        XCTAssertEqual(counts.added, 0)
    }
}

actor MembershipTransportDouble: HomeMembershipTransport {
    enum Mode { case succeed, notSubmitted, applyThenFail, fail, hold }
    struct Counts: Sendable { let created: Int; let added: Int; let refreshed: Int; let urls: Int }
    static let share = HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")
    private let scope: ActiveHomeScope
    private let journalURL: URL
    private var mode = Mode.succeed
    private var members: [HomeMember] = []
    private var tag = "initial"
    private var owner = true
    private var failURL = false
    private var created = 0
    private var added = 0
    private var refreshed = 0
    private var urls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var removals: [UUID: HomeMembershipRemoval] = [:]
    private var removalMode = Mode.succeed
    private var failRetention = false
    private var preflightFailure: Error?
    private(set) var removedParticipants: [Set<String>] = []
    private(set) var submittedMaterials: [HomeInviteMaterial] = []
    private(set) var journalAtSubmission: [HomeInviteJournal.Intent] = []
    private(set) var refreshOverlappedAdd = false
    var isHeld: Bool { held != nil }

    init(scope: ActiveHomeScope, journalURL: URL) { self.scope = scope; self.journalURL = journalURL }
    func setMode(_ value: Mode) { mode = value }
    func setPreflightFailure(_ error: Error?) { preflightFailure = error }
    func setTag(_ value: String) { tag = value }
    func setOwner(_ value: Bool) { owner = value }
    func setURLFailure(_ value: Bool) { failURL = value }
    func setRemovalMode(_ value: Mode) { removalMode = value }
    func setRetentionFailure(_ value: Bool) { failRetention = value }
    func importAuthorizations(_ values: [HomeMembershipRemoval]) { for value in values { removals[value.id] = value } }
    func counts() -> Counts { Counts(created: created, added: added, refreshed: refreshed, urls: urls) }
    func release() {
        // Latch release even if startup failed before reaching the native callback.
        mode = .succeed
        let continuation = held
        held = nil
        continuation?.resume()
    }
    func include(_ id: String, acceptance: HomeMember.Acceptance) {
        members.removeAll { $0.id == id }
        members.append(HomeMember(id: id, name: nil, role: .contributor, acceptance: acceptance,
            isCurrentUser: false, canResend: acceptance == .pending))
    }
    private func snapshot() -> HomeMembershipSnapshot {
        let current = HomeMember(id: "owner", name: "Owner", role: owner ? .owner : .contributor,
            acceptance: .accepted, isCurrentUser: true, canResend: false)
        return HomeMembershipSnapshot(scope: scope, share: Self.share, homeName: "Home",
            access: owner ? .owner : .contributor, currentParticipantID: current.id,
            members: [current] + members, changeTag: tag, observedAt: Date(), source: .server)
    }
    func refresh(scope: ActiveHomeScope) async throws -> HomeMembershipSnapshot {
        refreshed += 1
        if held != nil { refreshOverlappedAdd = true }
        return snapshot()
    }
    func makeInvitationParticipant(scope: ActiveHomeScope) async throws -> HomeInviteMaterial {
        created += 1
        return HomeInviteMaterial(participantID: "invited-\(created)", archive: Data([UInt8(created), 0, 255]))
    }
    func addInvitation(_ material: HomeInviteMaterial, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        added += 1
        submittedMaterials.append(material)
        if let intent = try HomeInviteJournal(url: journalURL).load(scope: scope) { journalAtSubmission.append(intent) }
        if let preflightFailure { throw HomeMembershipNotSubmitted(reason: preflightFailure) }
        if mode == .notSubmitted { throw HomeMembershipNotSubmitted(reason: HomeMembershipError.membershipChanged) }
        if mode == .fail { throw HomeMembershipError.shareUnavailable }
        if mode == .hold { await withCheckedContinuation { held = $0 } }
        include(material.participantID, acceptance: .pending)
        if mode == .applyThenFail { throw HomeMembershipError.shareUnavailable }
        return snapshot()
    }
    func invitationURL(participantID: String, scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> URL {
        urls += 1
        if failURL { throw HomeMembershipError.missingURL }
        return URL(string: "https://example.invalid/\(participantID)")!
    }

    func retainedRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> [HomeMembershipRemoval] {
        removals.values.filter { $0.matches(scope: scope, share: share) }
    }

    func retainRemoval(_ removal: HomeMembershipRemoval, scope: ActiveHomeScope) async throws {
        guard owner else { throw HomeMembershipError.ownerRequired }
        guard !failRetention else { throw HomeMembershipError.shareUnavailable }
        guard removal.matches(scope: self.scope, share: Self.share), scope == self.scope else { throw HomeMembershipError.scopeChanged }
        if let previous = removals[removal.id], previous != removal { throw HomeMembershipError.invalidJournal }
        removals[removal.id] = removal
    }

    func removeParticipants(_ participantIDs: Set<String>, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        guard owner, expected.scope == scope, !participantIDs.contains("owner") else { throw HomeMembershipError.ownerRequired }
        removedParticipants.append(participantIDs)
        if removalMode == .fail { throw HomeMembershipError.shareUnavailable }
        members.removeAll { participantIDs.contains($0.id) }
        tag = UUID().uuidString
        if removalMode == .applyThenFail { throw HomeMembershipError.outcomeUncertain }
        return snapshot()
    }
}
