import CloudKit
import XCTest
@testable import Shopping

@MainActor
final class HomeNamedInvitationsModelTests: XCTestCase {
    private final class Gate<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        let started = XCTestExpectation(description: "Operation reached its controlled boundary")

        func wait() async throws -> Value {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func finish(_ value: Value) { resolve(.success(value)) }
        func cancel() { resolve(.failure(CancellationError())) }
        private func resolve(_ result: Result<Value, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func withGate<Value: Sendable>(_ gate: Gate<Value>,
        operation: @escaping @MainActor () async -> Void,
        body: (Task<Void, Never>) async throws -> Void) async throws {
        let task = Task { await operation() }
        do {
            let result = await XCTWaiter.fulfillment(of: [gate.started], timeout: 2)
            guard result == .completed else { throw TestFailure.didNotStart }
            try await body(task)
        } catch {
            gate.cancel()
            await task.value
            throw error
        }
        gate.cancel()
        await task.value
    }

    private enum TestFailure: Error { case didNotStart, expected }

    private final class Actions {
        let scope: ActiveHomeScope
        var records: [HomeInvitationRecord] = []
        var loadOperation: (() async throws -> [HomeInvitationRecord])?
        var prepareOperation: ((String) async throws -> HomeInvitationRecord)?
        var createOperation: ((UUID) async throws -> HomeInvitationDelivery)?
        var renameOperation: (() async throws -> Void)?
        var onCreate: (() -> Void)?
        var onHandoff: (() -> Void)?
        var loadCount = 0
        var created: [UUID] = []
        var handedOff: [UUID] = []

        init(scope: ActiveHomeScope) { self.scope = scope }

        var actions: HomeNamedInvitationActions {
            HomeNamedInvitationActions(load: {
                self.loadCount += 1
                return try await self.loadOperation?() ?? self.records
            }, prepare: { name in
                if let operation = self.prepareOperation { return try await operation(name) }
                if let existing = self.records.first(where: { $0.normalizedName == HomeInvitationRecord.normalize(name) }) {
                    return existing
                }
                let record = HomeInvitationRecord(id: UUID(), name: name, origin: self.scope,
                    share: nil, participantIDs: [], lastHandoffAt: nil)
                self.records.append(record)
                return record
            }, create: { id, _ in
                self.created.append(id)
                self.onCreate?()
                if let operation = self.createOperation { return try await operation(id) }
                let index = try XCTUnwrap(self.records.firstIndex { $0.id == id })
                let old = self.records[index]
                self.records[index] = HomeInvitationRecord(id: id, name: old.name, origin: old.origin,
                    share: Self.share, participantIDs: ["participant"], lastHandoffAt: old.lastHandoffAt)
                return HomeInvitationDelivery(id: id, scope: self.scope, participantID: "participant",
                    url: URL(string: "https://example.invalid/invitation")!)
            }, rename: { _, _ in try await self.renameOperation?() }, label: { _, _ in throw TestFailure.expected },
            handoff: { self.handedOff.append($0); self.onHandoff?() }, cancel: { _ in throw TestFailure.expected })
        }

        static let share = HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")
    }

    private func scope(account: String = "owner") throws -> ActiveHomeScope {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.named-presentation",
            environment: "Development", accountRecordName: account)
        return ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: UUID().uuidString,
            rootURI: "x-coredata://test/Household/" + UUID().uuidString, householdID: UUID(), listID: UUID()))
    }

    private func record(_ scope: ActiveHomeScope, name: String = "Beka", participants: Set<String> = [],
                        handoff: Date? = nil, terminal: Bool = false) -> HomeInvitationRecord {
        HomeInvitationRecord(id: UUID(), name: name, origin: scope,
            share: participants.isEmpty ? nil : Actions.share, participantIDs: participants,
            lastHandoffAt: handoff, isTerminal: terminal)
    }

    func testFailedCreationRetainsNamedDraftAndRetryUsesSameInvitation() async throws {
        let actions = Actions(scope: try scope())
        actions.createOperation = { _ in throw CKError(.networkUnavailable) }
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        let preparedValue = await model.prepare(name: "Beka")
        let prepared = try XCTUnwrap(preparedValue)
        XCTAssertEqual(prepared.name, "Beka")
        XCTAssertEqual(model.records, [prepared])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.busy)
        actions.createOperation = nil
        await model.createOrShare(prepared, share: false)
        XCTAssertEqual(actions.created, [prepared.id, prepared.id])
        XCTAssertEqual(model.records.first?.id, prepared.id)
        XCTAssertEqual(model.records.first?.participantIDs, ["participant"])
        XCTAssertNil(model.delivery, "Creating is distinct from asking to share")
        XCTAssertNil(model.error)
    }

    func testNormalizedExistingDraftContinuesWithoutResubmitting() async throws {
        let actions = Actions(scope: try scope())
        let draft = record(actions.scope, name: "Beka Smith")
        actions.records = [draft]
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        await model.refresh()
        let continued = await model.prepare(name: "  BEKA  Smith \n")
        XCTAssertEqual(continued?.id, draft.id)
        XCTAssertTrue(actions.created.isEmpty)
        XCTAssertEqual(model.records, [draft])
    }

    func testLoadFailurePreservesRecordsAndDoesNotBecomeCommandError() async throws {
        let actions = Actions(scope: try scope())
        actions.records = [record(actions.scope)]
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        await model.refresh()
        actions.loadOperation = { throw CKError(.networkUnavailable) }
        await model.refresh()
        XCTAssertEqual(model.records, actions.records)
        XCTAssertNotNil(model.refreshError)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy)
    }

    func testCoalescedLoadCannotOverwriteNewlyPreparedInvitation() async throws {
        let actions = Actions(scope: try scope())
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        let gate = Gate<[HomeInvitationRecord]>()
        actions.loadOperation = { try await gate.wait() }
        try await withGate(gate, operation: { await model.refresh() }) { oldLoad in
            let second = Task { await model.refresh() }
            await Task.yield()
            XCTAssertEqual(actions.loadCount, 1)
            let creating = expectation(description: "Named command superseded old load")
            actions.onCreate = { creating.fulfill() }
            let command = Task { await model.prepare(name: "Beka") }
            await fulfillment(of: [creating], timeout: 2)
            actions.loadOperation = nil
            gate.finish([])
            await oldLoad.value
            await second.value
            let prepared = await command.value
            XCTAssertEqual(prepared?.name, "Beka")
            XCTAssertEqual(model.records.first?.name, "Beka")
            XCTAssertEqual(model.records.first?.participantIDs, ["participant"])
            XCTAssertNil(model.refreshError)
        }
    }

    func testRetiredLoadCannotPublishRecordsOrError() async throws {
        for fails in [false, true] {
            let actions = Actions(scope: try scope())
            let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
            let gate = Gate<[HomeInvitationRecord]>()
            actions.loadOperation = { try await gate.wait() }
            try await withGate(gate, operation: { await model.refresh() }) { task in
                model.retire()
                if fails { gate.cancel() } else { gate.finish([record(actions.scope)]) }
                await task.value
                XCTAssertTrue(model.records.isEmpty)
                XCTAssertNil(model.refreshError)
            }
        }
    }

    func testForeignAccountLoadAndPreparedRecordNeverPublish() async throws {
        let actions = Actions(scope: try scope())
        let local = record(actions.scope)
        actions.records = [local]
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        await model.refresh()
        let foreign = record(try scope(account: "someone-else"))
        actions.loadOperation = { [foreign] }
        await model.refresh()
        XCTAssertEqual(model.records, [local])
        XCTAssertNotNil(model.refreshError)
        actions.prepareOperation = { _ in foreign }
        let prepared = await model.prepare(name: "Beka")
        XCTAssertNil(prepared)
        XCTAssertEqual(model.records, [local])
        XCTAssertTrue(actions.created.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testRetiredAndForeignAccountCreationCannotPublishShareSheet() async throws {
        for retire in [false, true] {
            let actions = Actions(scope: try scope())
            let draft = record(actions.scope)
            actions.records = [draft]
            let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
            await model.refresh()
            let gate = Gate<HomeInvitationDelivery>()
            actions.createOperation = { _ in try await gate.wait() }
            try await withGate(gate, operation: { await model.createOrShare(draft, share: true) }) { task in
                if retire { model.retire() }
                gate.finish(HomeInvitationDelivery(id: draft.id, scope: retire ? actions.scope : try scope(account: "other"),
                    participantID: "participant", url: URL(string: "https://example.invalid/invitation")!))
                await task.value
                XCTAssertNil(model.delivery)
                XCTAssertFalse(model.busy)
                XCTAssertTrue(actions.handedOff.isEmpty)
                if retire { XCTAssertNil(model.error) } else { XCTAssertNotNil(model.error) }
            }
        }
    }

    func testShareCancellationFailureAndCompletionConsumeOnlyMatchingActivityOnce() async throws {
        for outcome in ["cancelled", "failed", "completed"] {
            let actions = Actions(scope: try scope())
            let draft = record(actions.scope)
            actions.records = [draft]
            let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
            await model.refresh()
            await model.createOrShare(draft, share: true)
            let delivery = try XCTUnwrap(model.delivery)
            let stale = HomeInvitationDelivery(id: UUID(), scope: actions.scope, participantID: delivery.participantID, url: delivery.url)
            await model.finishedSharing(stale, completed: true, failure: nil)
            XCTAssertTrue(actions.handedOff.isEmpty)
            // UIKit/SwiftUI may clear the binding before its completion callback arrives.
            model.delivery = nil
            await model.finishedSharing(delivery, completed: outcome == "completed",
                failure: outcome == "failed" ? CKError(.networkUnavailable) : nil)
            await model.finishedSharing(delivery, completed: true, failure: nil)
            XCTAssertEqual(actions.handedOff, outcome == "completed" ? [draft.id] : [])
            XCTAssertEqual(model.records.first?.id, draft.id)
            XCTAssertEqual(model.error != nil, outcome == "failed")
        }
    }

    func testReactivationDuringOldLoadDrainsThenLoadsCurrentRecords() async throws {
        let actions = Actions(scope: try scope())
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        let gate = Gate<[HomeInvitationRecord]>()
        actions.loadOperation = { try await gate.wait() }
        try await withGate(gate, operation: { await model.refresh() }) { old in
            model.retire()
            model.activate()
            actions.records = [record(actions.scope)]
            actions.loadOperation = nil
            let resumed = Task { await model.refresh() }
            await Task.yield()
            gate.finish([])
            await old.value
            await resumed.value
            XCTAssertEqual(model.records, actions.records)
            XCTAssertEqual(actions.loadCount, 2)
        }
    }

    func testCompletedHandoffDuringRenameDoesNotRetireCommandOrClearProgress() async throws {
        let actions = Actions(scope: try scope())
        let invitation = record(actions.scope, participants: ["participant"])
        actions.records = [invitation]
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        await model.refresh()
        await model.createOrShare(invitation, share: true)
        let delivery = try XCTUnwrap(model.delivery)
        let gate = Gate<Bool>()
        actions.renameOperation = { _ = try await gate.wait() }
        var saved = false
        try await withGate(gate, operation: { saved = await model.rename(invitation, name: "Beka Smith") }) { task in
            let progress = model.operation
            await model.finishedSharing(delivery, completed: true, failure: nil)
            XCTAssertEqual(model.operation, progress)
            XCTAssertTrue(model.busy)
            XCTAssertEqual(actions.handedOff, [invitation.id])
            gate.finish(true)
            await task.value
            XCTAssertTrue(saved)
            XCTAssertFalse(model.busy)
        }
    }

    func testCompletedActivityBeforePostCreationLoadTracksOriginalNamedDraft() async throws {
        let actions = Actions(scope: try scope())
        let invitation = record(actions.scope)
        actions.records = [invitation]
        let model = HomeNamedInvitationsModel(scope: actions.scope, actions: actions.actions)
        await model.refresh()
        let gate = Gate<[HomeInvitationRecord]>()
        actions.loadOperation = { try await gate.wait() }
        try await withGate(gate, operation: { await model.createOrShare(invitation, share: true) }) { creation in
            let delivery = try XCTUnwrap(model.delivery)
            XCTAssertEqual(model.records.first?.participantIDs, [], "The saved binding is still loading")
            model.delivery = nil
            let handedOff = expectation(description: "Activity recorded before binding load completes")
            actions.onHandoff = { handedOff.fulfill() }
            let callback = Task { await model.finishedSharing(delivery, completed: true, failure: nil) }
            await fulfillment(of: [handedOff], timeout: 2)
            gate.finish(actions.records)
            await creation.value
            await callback.value
            XCTAssertEqual(actions.handedOff, [invitation.id])
            await model.finishedSharing(delivery, completed: true, failure: nil)
            XCTAssertEqual(actions.handedOff, [invitation.id])
        }
    }

    func testPresentationDistinguishesDraftReadyHandoffAndActualAcceptance() throws {
        let home = try scope()
        let pending = HomeMember(id: "participant", name: nil, role: .contributor,
            acceptance: .pending, isCurrentUser: false, canResend: true)
        let accepted = HomeMember(id: "participant", name: "Actual identity", role: .contributor,
            acceptance: .accepted, isCurrentUser: false, canResend: false)
        func snapshot(_ members: [HomeMember]) -> HomeMembershipSnapshot {
            HomeMembershipSnapshot(scope: home, share: Actions.share, homeName: "Home", access: .owner,
                currentParticipantID: "owner", members: members, changeTag: "v1", observedAt: Date(), source: .server)
        }
        let draft = HomeInvitationPresentation(record: record(home), snapshot: snapshot([]))
        XCTAssertEqual(draft.status, "Draft")
        XCTAssertFalse(draft.canShare)
        let bound = record(home, participants: ["participant"])
        let ready = HomeInvitationPresentation(record: bound, snapshot: snapshot([pending]))
        XCTAssertEqual(ready.status, "Ready to share")
        XCTAssertTrue(ready.canShare)
        let handedOff = record(home, participants: ["participant"], handoff: Date())
        let waiting = HomeInvitationPresentation(record: handedOff, snapshot: snapshot([pending]))
        XCTAssertEqual(waiting.status, "Waiting to join")
        XCTAssertNil(waiting.acceptedMember)
        let joined = HomeInvitationPresentation(record: handedOff, snapshot: snapshot([accepted]))
        XCTAssertEqual(joined.status, "Joined")
        XCTAssertEqual(joined.acceptedMember?.name, "Actual identity")
        XCTAssertFalse(joined.canShare)
        XCTAssertEqual(HomeInvitationPresentation(record: bound, snapshot: nil).status, "Check invitation")
        XCTAssertFalse(HomeInvitationPresentation(record: bound, snapshot: nil).canShare)
        let conflict = HomeInvitationPresentation(record: record(home, participants: ["a", "b"]), snapshot: snapshot([pending]))
        XCTAssertEqual(conflict.status, "Multiple links need review")
        XCTAssertFalse(conflict.canShare)
    }

    func testPresentationKeepsCancellationPendingUntilAbsenceIsObserved() throws {
        let home = try scope()
        let bound = record(home, participants: ["participant"])
        let removal = HomeMembershipRemoval(id: UUID(), origin: home, share: Actions.share,
            ownerParticipantID: "owner", participantIDs: ["participant"], cancelledInvitationID: bound.id,
            purpose: .cancelInvitation, confirmedAt: Date())
        for observed in [false, true] {
            var snapshot = HomeMembershipSnapshot(scope: home, share: Actions.share, homeName: "Home", access: .owner,
                currentParticipantID: "owner", members: [], changeTag: "v1", observedAt: Date(), source: .server)
            snapshot.removals = [.init(removal: removal, absentObservedAt: observed ? Date() : nil)]
            let presentation = HomeInvitationPresentation(record: bound, snapshot: snapshot)
            XCTAssertEqual(presentation.status, observed ? "Invitation cancelled" : "Cancelling invitation…")
            XCTAssertEqual(presentation.cancelling, !observed)
            XCTAssertFalse(presentation.canShare)
        }
    }
}
