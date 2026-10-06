import CoreData
import XCTest
@testable import Shopping

@MainActor
final class HomeNamedInvitationTests: XCTestCase {
    private func fixture() throws -> (URL, ActiveHomeScope, NamedInvitationTransport) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.named",
            environment: "Development", accountRecordName: "owner")
        let scope = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "phone-one",
            rootURI: "x-coredata://one/root", householdID: UUID(), listID: UUID()))
        let url = directory.appendingPathComponent("invite.json")
        return (url, scope, NamedInvitationTransport(native: MembershipTransportDouble(scope: scope, journalURL: url)))
    }

    func testDiscardedDraftReleasesNameAndCannotCreateLink() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let draft = try await coordinator.prepareInvitation(name: "Beka", scope: scope, share: nil, transport: transport)
        try await coordinator.discardInvitationDraft(recordID: draft.id, scope: scope, share: nil, transport: transport)
        let replacement = try await coordinator.prepareInvitation(name: "Beka", scope: scope, share: nil, transport: transport)
        XCTAssertNotEqual(draft.id, replacement.id)
        do {
            _ = try await coordinator.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
            XCTFail("A discarded draft cannot create a capability")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invitationCancelled) }
        let counts = await transport.native.counts()
        XCTAssertEqual(counts.created, 0)
        try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: draft.id,
            origin: scope, share: MembershipTransportDouble.share, name: "Beka", kind: .bound,
            participantID: "concurrent-link", createdAt: Date()), scope: scope)
        let records = try await coordinator.invitationRecords(scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        XCTAssertFalse(try XCTUnwrap(records.first { $0.id == draft.id }).isTerminal,
            "An unseen concurrent capability must remain visible for explicit cancellation")
    }

    func testNameIsDurableBeforeCreationAndReusesNormalizedNameAfterAcknowledgement() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let draft = try await coordinator.prepareInvitation(name: "  Beka \n Smith ", scope: scope, share: nil, transport: transport)
        let duplicate = try await coordinator.prepareInvitation(name: "beka smith", scope: scope, share: nil, transport: transport)
        XCTAssertEqual(draft.id, duplicate.id)
        let delivery = try await coordinator.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
        let bindingAtSubmission = await transport.bindingAtSubmission
        XCTAssertEqual(bindingAtSubmission, delivery.participantID)
        try await coordinator.acknowledge(delivery, journalURL: url)
        let reopened = HomeMembershipCoordinator()
        let existing = try await reopened.prepareInvitation(name: "BEKA SMITH", scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        XCTAssertEqual(existing.id, draft.id)
        XCTAssertNil(existing.lastHandoffAt, "Opening or dismissing sharing is not a completed handoff")
        try await reopened.recordInvitationHandoff(recordID: draft.id, scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        let resent = try await reopened.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
        XCTAssertEqual(resent.participantID, delivery.participantID)
        let records = try await reopened.invitationRecords(scope: scope, share: MembershipTransportDouble.share, transport: transport)
        XCTAssertNotNil(records.first?.lastHandoffAt)
        let counts = await transport.native.counts()
        XCTAssertEqual(counts.created, 1)
        XCTAssertEqual(counts.added, 1)
    }

    func testCrashAfterBindingNeverCreatesReplacementOrResubmits() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let draft = try await coordinator.prepareInvitation(name: "Beka", scope: scope, share: nil, transport: transport)
        await transport.interruptAfterBinding()
        do {
            _ = try await coordinator.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
            XCTFail("Expected interruption after the durable binding")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .shareUnavailable) }
        for _ in 0..<2 {
            do {
                _ = try await HomeMembershipCoordinator().invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
                XCTFail("A retained binding alone cannot authorize submission")
            } catch { XCTAssertEqual(error as? HomeMembershipError, .outcomeUncertain) }
        }
        let counts = await transport.native.counts()
        XCTAssertEqual(counts.created, 1)
        XCTAssertEqual(counts.added, 0)
        let cancellation = try await coordinator.prepareInvitationCancellation(recordID: draft.id, scope: scope,
            share: MembershipTransportDouble.share, journalURL: url, transport: transport)
        _ = try await coordinator.confirmRemoval(cancellation, scope: scope, journalURL: url, transport: transport)
        let cancelled = try await coordinator.invitationRecords(scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        XCTAssertTrue(try XCTUnwrap(cancelled.first).isTerminal)
        do {
            _ = try await coordinator.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
            XCTFail("Cancellation must suppress the unobserved capability")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invitationCancelled) }
    }

    func testAcceptedIdentityAndRetainedCancellationReleaseNamesWithoutDeletingHistory() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let draft = try await coordinator.prepareInvitation(name: "Beka", scope: scope, share: nil, transport: transport)
        let delivery = try await coordinator.invite(recordID: draft.id, scope: scope, journalURL: url, transport: transport)
        await transport.native.include(delivery.participantID, acceptance: .accepted)
        _ = try await coordinator.refresh(scope: scope, journalURL: url, transport: transport)
        let replacement = try await coordinator.prepareInvitation(name: "Beka", scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        XCTAssertNotEqual(draft.id, replacement.id)
        let second = try await coordinator.invite(recordID: replacement.id, scope: scope, journalURL: url, transport: transport)
        let confirmation = try await coordinator.prepareRemoval(purpose: .cancelInvitation, scope: scope,
            journalURL: url, transport: transport)
        _ = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        let records = try await coordinator.invitationRecords(scope: scope, share: MembershipTransportDouble.share, transport: transport)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy(\.isTerminal))
        XCTAssertTrue(records.contains { $0.participantID == second.participantID })
    }

    func testLabelExistingInvitationAndRenameNeverReplaceParticipant() async throws {
        let (_, scope, transport) = try fixture()
        await transport.native.include("legacy", acceptance: .pending)
        let coordinator = HomeMembershipCoordinator()
        let record = try await coordinator.labelInvitation(participantID: "legacy", name: "Beka", scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        try await coordinator.renameInvitation(recordID: record.id, name: "Beka Smith", scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        let records = try await coordinator.invitationRecords(scope: scope, share: MembershipTransportDouble.share, transport: transport)
        XCTAssertEqual(records.first?.name, "Beka Smith")
        XCTAssertEqual(records.first?.participantID, "legacy")
        let counts = await transport.native.counts()
        XCTAssertEqual(counts.created, 0)
        XCTAssertEqual(counts.added, 0)
        _ = try await coordinator.prepareInvitation(name: "Alex", scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        do {
            try await coordinator.renameInvitation(recordID: record.id, name: " ALEX ", scope: scope,
                share: MembershipTransportDouble.share, transport: transport)
            XCTFail("Existing active names must be reused or distinguished")
        } catch { XCTAssertEqual(error as? HomeMembershipError, .invitationNameConflict) }
    }

    func testConcurrentLinksCanBeCancelledIndividuallyAfterAnotherAccepts() async throws {
        let (url, scope, transport) = try fixture()
        let coordinator = HomeMembershipCoordinator()
        let draft = try await coordinator.prepareInvitation(name: "Beka", scope: scope, share: nil, transport: transport)
        for participantID in ["joined", "pending"] {
            try await transport.retainInvitationEvent(HomeInvitationEvent(id: UUID(), invitationID: draft.id,
                origin: scope, share: MembershipTransportDouble.share, name: draft.name, kind: .bound,
                participantID: participantID, createdAt: Date()), scope: scope)
        }
        await transport.native.include("joined", acceptance: .accepted)
        await transport.native.include("pending", acceptance: .pending)
        let snapshot = try await coordinator.refresh(scope: scope, journalURL: url, transport: transport)
        let records = try await coordinator.invitationRecords(scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        let record = try XCTUnwrap(records.first)
        XCTAssertFalse(record.isTerminal)
        let presentation = HomeInvitationPresentation(record: record, snapshot: snapshot)
        XCTAssertNil(presentation.acceptedMember)
        XCTAssertEqual(presentation.status, "Multiple links need review")
        let confirmation = try await coordinator.prepareInvitationCancellation(recordID: draft.id,
            participantID: "pending", scope: scope, share: MembershipTransportDouble.share,
            journalURL: url, transport: transport)
        XCTAssertEqual(confirmation.removal.participantIDs, ["pending"])
        _ = try await coordinator.confirmRemoval(confirmation, scope: scope, journalURL: url, transport: transport)
        let final = try await coordinator.invitationRecords(scope: scope,
            share: MembershipTransportDouble.share, transport: transport)
        XCTAssertTrue(try XCTUnwrap(final.first).isTerminal)
    }

    func testReplicaProjectionPreservesCompetingCapabilitiesAndPortableIdentity() throws {
        let (_, scope, _) = try fixture()
        let id = UUID()
        let named = HomeInvitationEvent(id: id, invitationID: id, origin: scope, share: nil,
            name: "Beka", kind: .named, participantID: nil, createdAt: Date())
        let bindings = ["person-one", "person-two"].map {
            HomeInvitationEvent(id: UUID(), invitationID: id, origin: scope, share: MembershipTransportDouble.share,
                name: "Beka", kind: .bound, participantID: $0, createdAt: Date())
        }
        let session = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "owner")
        let otherDevice = ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: "phone-two",
            rootURI: "x-coredata://two/root", householdID: scope.graph.householdID, listID: scope.graph.listID))
        let events = [named] + bindings
        let first = try HomeInvitationRecord.project(events, scope: otherDevice, share: MembershipTransportDouble.share)
        let reversed = try HomeInvitationRecord.project(events.reversed(), scope: otherDevice, share: MembershipTransportDouble.share)
        XCTAssertEqual(first, reversed)
        XCTAssertTrue(try XCTUnwrap(first.first).hasConflictingParticipants)
        XCTAssertNil(first.first?.participantID)
        XCTAssertEqual(first.first?.participantIDs, ["person-one", "person-two"])
        let otherAccount = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "someone-else")
        XCTAssertTrue(try HomeInvitationRecord.project(events, scope: ActiveHomeScope(session: otherAccount, graph: scope.graph),
            share: MembershipTransportDouble.share).isEmpty)
        let duplicateID = UUID()
        let duplicate = HomeInvitationEvent(id: duplicateID, invitationID: duplicateID, origin: otherDevice,
            share: nil, name: "BEKA", kind: .named, participantID: nil, createdAt: Date())
        XCTAssertTrue(try HomeInvitationRecord.project(events + [duplicate], scope: scope,
            share: MembershipTransportDouble.share).allSatisfy(\.hasConflictingName))
    }
}

private actor NamedInvitationTransport: HomeInvitationTrackingTransport {
    let native: MembershipTransportDouble
    var events: [HomeInvitationEvent] = []
    var bindingAtSubmission: String?
    private var interruptsBinding = false
    init(native: MembershipTransportDouble) { self.native = native }
    func interruptAfterBinding() { interruptsBinding = true }
    func invitationEvents(scope: ActiveHomeScope) async throws -> [HomeInvitationEvent] { events.filter { $0.matches(scope: scope) } }
    func retainInvitationEvent(_ event: HomeInvitationEvent, scope: ActiveHomeScope) async throws {
        try event.validate()
        events.append(event)
        if event.kind == .bound && interruptsBinding { throw HomeMembershipError.shareUnavailable }
    }
    func refresh(scope: ActiveHomeScope) async throws -> HomeMembershipSnapshot { try await native.refresh(scope: scope) }
    func makeInvitationParticipant(scope: ActiveHomeScope) async throws -> HomeInviteMaterial {
        guard events.contains(where: { $0.kind == .named }) else { throw HomeMembershipError.invalidJournal }
        return try await native.makeInvitationParticipant(scope: scope)
    }
    func addInvitation(_ material: HomeInviteMaterial, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        bindingAtSubmission = events.first { $0.kind == .bound && $0.participantID == material.participantID }?.participantID
        return try await native.addInvitation(material, expected: expected)
    }
    func invitationURL(participantID: String, scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> URL {
        try await native.invitationURL(participantID: participantID, scope: scope, share: share)
    }
    func retainedRemovals(scope: ActiveHomeScope, share: HomeShareIdentity) async throws -> [HomeMembershipRemoval] {
        try await native.retainedRemovals(scope: scope, share: share)
    }
    func retainRemoval(_ removal: HomeMembershipRemoval, scope: ActiveHomeScope) async throws {
        try await native.retainRemoval(removal, scope: scope)
    }
    func removeParticipants(_ participantIDs: Set<String>, expected: HomeMembershipSnapshot) async throws -> HomeMembershipSnapshot {
        try await native.removeParticipants(participantIDs, expected: expected)
    }
}
