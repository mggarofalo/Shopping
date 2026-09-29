import XCTest
@testable import Shopping

@MainActor
final class HomeDetailsModelTests: XCTestCase {
    @MainActor
    private final class Gate<Value: Sendable> {
        enum Failure: Error { case actionDidNotStart, multipleWaiters }
        private enum State {
            case idle
            case waiting(CheckedContinuation<Value, Error>)
            case finished(Result<Value, Error>)
        }
        private var state: State = .idle
        private let started = XCTestExpectation(description: "Action reached its controlled boundary")

        init() { started.assertForOverFulfill = false }

        func wait() async throws -> Value {
            switch state {
            case .finished(let result): return try result.get()
            case .waiting: throw Failure.multipleWaiters
            case .idle: break
            }
            return try await withCheckedThrowingContinuation { continuation in
                state = .waiting(continuation)
                started.fulfill()
            }
        }
        func waitUntilStarted() async throws {
            let result = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(result, .completed, "The action returned or failed before reaching its controlled boundary")
            guard result == .completed else { throw Failure.actionDidNotStart }
        }
        func finish(_ value: Value) { resolve(.success(value)) }
        func cancel() { resolve(.failure(CancellationError())) }

        private func resolve(_ result: Result<Value, Error>) {
            switch state {
            case .finished: return
            case .idle: state = .finished(result)
            case .waiting(let continuation):
                state = .finished(result)
                continuation.resume(with: result)
            }
        }
    }

    /// Always release the controlled suspension and drain its task, including when a
    /// fixture read throws before the test reaches finish(). Cancellation is terminal
    /// even when the action reaches the gate only after the startup timeout.
    private func withGateTask<Value: Sendable>(_ gate: Gate<Value>,
        operation: @escaping @MainActor () async throws -> Void,
        body: @MainActor (Task<Void, Error>) async throws -> Void) async throws {
        let task = Task { try await operation() }
        do {
            try await gate.waitUntilStarted()
            try await body(task)
        } catch {
            gate.cancel()
            task.cancel()
            _ = await task.result
            throw error
        }
        gate.cancel()
        task.cancel()
        _ = await task.result
    }

    @MainActor
    private final class Actions {
        var value: HomeMembershipSnapshot
        var pending: HomeMembershipCoordinator.Pending?
        var delivery: HomeInvitationDelivery
        var refreshOperation: (() async throws -> HomeMembershipSnapshot)?
        var inviteOperation: (() async throws -> HomeInvitationDelivery)?
        var renameFailure: Error?
        var renamed: [String] = []
        var acknowledged: [UUID] = []
        var invitationRetries: [Bool] = []
        var resent: [String] = []

        init(value: HomeMembershipSnapshot) {
            self.value = value
            delivery = HomeInvitationDelivery(id: UUID(), scope: value.scope,
                participantID: "pending-member", url: URL(string: "https://example.invalid/invitation")!)
        }
        var actions: HomeDetailsActions {
            HomeDetailsActions(refresh: {
                if let operation = self.refreshOperation { return try await operation() }
                return self.value
            }, pending: { self.pending }, invite: { retry in
                self.invitationRetries.append(retry)
                if let operation = self.inviteOperation { return try await operation() }
                return self.delivery
            }, resend: { participant in
                self.resent.append(participant)
                return self.delivery
            }, acknowledge: { delivery in self.acknowledged.append(delivery.id) }, rename: { name in
                self.renamed.append(name)
                if let failure = self.renameFailure { throw failure }
            })
        }
    }

    private func scope() throws -> ActiveHomeScope {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-details",
            environment: "Development", accountRecordName: "owner")
        return ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: UUID().uuidString,
            rootURI: "x-coredata://isolated/Household/" + UUID().uuidString, householdID: UUID(), listID: UUID()))
    }

    private func snapshot(scope: ActiveHomeScope, access: HomeMembershipSnapshot.Access = .owner,
                          members: [HomeMember] = []) -> HomeMembershipSnapshot {
        HomeMembershipSnapshot(scope: scope,
            share: HomeShareIdentity(recordName: "share", zoneName: "zone", zoneOwnerName: "owner"),
            homeName: "Our home", access: access, currentParticipantID: "self", members: members,
            changeTag: "revision", observedAt: Date(timeIntervalSince1970: 0), source: .server)
    }

    func testOwnerContributorAndRestrictedAffordancesRequireCurrentVerifiedSnapshot() async throws {
        let scope = try scope()
        for access in [HomeMembershipSnapshot.Access.owner, .contributor, .restricted] {
            let actions = Actions(value: snapshot(scope: scope, access: access))
            let model = HomeDetailsModel(scope: scope, actions: actions.actions)
            XCTAssertFalse(model.canInvite)
            XCTAssertFalse(model.canRename)
            await model.refresh()
            XCTAssertEqual(model.canInvite, access == .owner)
            XCTAssertEqual(model.canRename, access != .restricted)
            model.retire()
            XCTAssertFalse(model.canInvite)
            XCTAssertFalse(model.canRename)
            await model.invite()
            XCTAssertTrue(actions.invitationRetries.isEmpty)
        }
    }

    func testPendingAndAcceptedMembersHaveSeparateCountsAndPrivacySafeFallbackLabels() throws {
        let members = [
            HomeMember(id: "self", name: "Me", role: .owner, acceptance: .accepted, isCurrentUser: true, canResend: false),
            HomeMember(id: "accepted", name: "Taylor", role: .contributor, acceptance: .accepted, isCurrentUser: false, canResend: false),
            HomeMember(id: "restricted", name: nil, role: .restricted, acceptance: .accepted, isCurrentUser: false, canResend: false),
            HomeMember(id: "pending", name: "Undisplayed lookup name", role: .contributor, acceptance: .pending, isCurrentUser: false, canResend: true),
            HomeMember(id: "unknown", name: nil, role: .contributor, acceptance: .unknown, isCurrentUser: false, canResend: false)
        ]
        let snapshot = snapshot(scope: try scope(), members: members)
        XCTAssertEqual(snapshot.acceptedOtherCount, 2)
        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertEqual(members[1].label, "Taylor")
        XCTAssertEqual(members[2].label, "Member")
        XCTAssertEqual(members[3].label, "Invitation pending")
        XCTAssertEqual(members[4].label, "Contributor")
        XCTAssertEqual(HomeMember(id: "owner", name: " \n", role: .owner, acceptance: .accepted,
            isCurrentUser: false, canResend: false).label, "Owner")
    }

    func testRefreshAfterRetirementCannotPublishAndReactivationCanRefreshAgain() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        let gate = Gate<HomeMembershipSnapshot>()
        actions.refreshOperation = { try await gate.wait() }
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        try await withGateTask(gate, operation: { await model.refresh() }) { operation in
            XCTAssertTrue(model.busy)
            model.retire()
            gate.finish(actions.value)
            try await operation.value
        }
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isCurrent)
        XCTAssertFalse(model.busy)
        actions.refreshOperation = nil
        model.activate()
        await model.refresh()
        XCTAssertEqual(model.snapshot, actions.value)
        XCTAssertTrue(model.canInvite)
    }

    func testMismatchedRefreshRevokesPreviouslyEnabledActions() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        XCTAssertTrue(model.canInvite)
        actions.value = snapshot(scope: try self.scope())
        await model.refresh()
        XCTAssertFalse(model.isCurrent)
        XCTAssertFalse(model.canInvite)
        XCTAssertFalse(model.canRename)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.error, HomeMembershipError.scopeChanged.localizedDescription)
        XCTAssertEqual(model.snapshot?.scope, scope, "A mismatched completion must never replace the original snapshot")
    }

    func testRenameFailureLeavesEditorEligibleForRetry() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope, access: .contributor))
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        actions.renameFailure = HomeMembershipError.membershipChanged
        let failed = await model.rename("Draft home name")
        XCTAssertFalse(failed, "The view must retain its editor and draft")
        XCTAssertTrue(model.canRename)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.error, HomeMembershipError.membershipChanged.localizedDescription)
        actions.renameFailure = nil
        let succeeded = await model.rename("Draft home name")
        XCTAssertTrue(succeeded)
        XCTAssertEqual(actions.renamed, ["Draft home name", "Draft home name"])
        XCTAssertNil(model.error)
    }

    func testDeliveryIsAcknowledgedOnlyAfterMatchingExplicitPresentation() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        actions.pending = HomeMembershipCoordinator.Pending(id: actions.delivery.id,
            participantID: actions.delivery.participantID, phase: .applied)
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.invite()
        XCTAssertEqual(model.delivery?.id, actions.delivery.id)
        XCTAssertTrue(actions.acknowledged.isEmpty)
        XCTAssertNotNil(model.pending)
        let wrongID = HomeInvitationDelivery(id: UUID(), scope: scope,
            participantID: actions.delivery.participantID, url: actions.delivery.url)
        await model.presented(wrongID)
        let wrongScope = HomeInvitationDelivery(id: actions.delivery.id, scope: try self.scope(),
            participantID: actions.delivery.participantID, url: actions.delivery.url)
        await model.presented(wrongScope)
        XCTAssertTrue(actions.acknowledged.isEmpty)
        await model.presented(actions.delivery)
        XCTAssertEqual(actions.acknowledged, [actions.delivery.id])
        XCTAssertNil(model.pending)
    }

    func testCancelledDeliveryDoesNotAcknowledgeOrCountAsAcceptedMembership() async throws {
        let scope = try scope()
        let member = HomeMember(id: "pending-member", name: nil, role: .contributor,
            acceptance: .pending, isCurrentUser: false, canResend: true)
        let actions = Actions(value: snapshot(scope: scope, members: [member]))
        actions.pending = HomeMembershipCoordinator.Pending(id: actions.delivery.id,
            participantID: member.id, phase: .applied)
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.invite()
        model.delivery = nil // User dismisses the delivery sheet without presenting its link.
        await model.presented(actions.delivery)
        XCTAssertTrue(actions.acknowledged.isEmpty)
        XCTAssertNotNil(model.pending)
        XCTAssertEqual(model.snapshot?.pendingCount, 1)
        XCTAssertEqual(model.snapshot?.acceptedOtherCount, 0)
        await model.resend(member.id)
        XCTAssertEqual(actions.resent, [member.id])
        XCTAssertEqual(model.delivery?.participantID, member.id)
        XCTAssertTrue(actions.acknowledged.isEmpty)
    }

    func testLateInvitationAfterRetirementCannotPublishLinkOrAcknowledgeDelivery() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        let gate = Gate<HomeInvitationDelivery>()
        actions.inviteOperation = { try await gate.wait() }
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        try await withGateTask(gate, operation: { await model.invite() }) { operation in
            model.retire()
            gate.finish(actions.delivery)
            try await operation.value
        }
        XCTAssertNil(model.delivery)
        XCTAssertFalse(model.busy)
        await model.presented(actions.delivery)
        XCTAssertTrue(actions.acknowledged.isEmpty)
        model.activate()
        await model.refresh()
        XCTAssertTrue(model.canInvite)
    }

    func testMismatchedInvitationCompletionCannotPublishLinkOrLatchBusyState() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        actions.delivery = HomeInvitationDelivery(id: UUID(), scope: try self.scope(),
            participantID: "wrong-home-participant", url: URL(string: "https://example.invalid/wrong-home")!)
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.invite()
        XCTAssertNil(model.delivery)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(actions.acknowledged.isEmpty)
        XCTAssertEqual(model.error, HomeMembershipError.scopeChanged.localizedDescription)
    }

#if DEBUG
    func testUIFixtureRequiresIsolationAndInvitationDeliveryNeverMeansAcceptance() async throws {
        let scope = try scope()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        for environment in [[:], ["SHOPPING_UI_TEST_STORE_PATH": path],
                            ["SHOPPING_UI_TEST_HOME_MEMBERS": "owner"],
                            ["SHOPPING_UI_TEST_STORE_PATH": "  ", "SHOPPING_UI_TEST_HOME_MEMBERS": "owner"],
                            ["SHOPPING_UI_TEST_STORE_PATH": path, "SHOPPING_UI_TEST_HOME_MEMBERS": "invalid"]] {
            XCTAssertNil(HomeDetailsUITestFixture.make(scope: scope, name: "Original", rename: { _ in }, environment: environment))
        }
        let actions = try XCTUnwrap(HomeDetailsUITestFixture.make(scope: scope, name: "Original", rename: { _ in },
            environment: ["SHOPPING_UI_TEST_STORE_PATH": path, "SHOPPING_UI_TEST_HOME_MEMBERS": "owner"]))
        let model = HomeDetailsModel(scope: scope, actions: actions)
        await model.refresh()
        XCTAssertEqual(model.snapshot?.acceptedOtherCount, 1)
        XCTAssertEqual(model.snapshot?.pendingCount, 0)
        await model.invite()
        let invitation = try XCTUnwrap(model.delivery)
        XCTAssertEqual(model.snapshot?.acceptedOtherCount, 1)
        XCTAssertEqual(model.snapshot?.pendingCount, 1)
        model.delivery = nil
        await model.presented(invitation)
        XCTAssertNotNil(model.pending, "Cancellation must not acknowledge delivery")
        await model.resend(invitation.participantID)
        let resent = try XCTUnwrap(model.delivery)
        XCTAssertEqual(resent.participantID, invitation.participantID)
        await model.presented(resent)
        let pending = try await actions.pending()
        let after = try await actions.refresh()
        XCTAssertNil(pending)
        XCTAssertEqual(after.acceptedOtherCount, 1)
        XCTAssertEqual(after.pendingCount, 1)
        XCTAssertEqual(after.members.filter { $0.id == invitation.participantID }.map(\.acceptance), [.pending])
    }

    func testUIFixtureContributorRenamesThroughRealCallbackAndRestrictedActionsRejectWrites() async throws {
        let scope = try scope()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        let failedWrite = Gate<Bool>(), successfulWrite = Gate<Bool>()
        var renameCalls = 0
        let contributor = try XCTUnwrap(HomeDetailsUITestFixture.make(scope: scope, name: "Original", rename: { _ in
            renameCalls += 1
            let succeeded = try await (renameCalls == 1 ? failedWrite : successfulWrite).wait()
            if !succeeded { throw HomeMembershipError.membershipChanged }
        }, environment: ["SHOPPING_UI_TEST_STORE_PATH": path, "SHOPPING_UI_TEST_HOME_MEMBERS": "contributor"]))
        try await withGateTask(failedWrite, operation: { try await contributor.rename("Rejected draft") }) { failed in
            let beforeFailure = try await contributor.refresh()
            XCTAssertEqual(beforeFailure.homeName, "Original", "Fixture must await the real rename callback")
            failedWrite.finish(false)
            do { try await failed.value; XCTFail("Rename failure must propagate") }
            catch { XCTAssertEqual(error as? HomeMembershipError, .membershipChanged) }
        }
        let afterFailure = try await contributor.refresh()
        XCTAssertEqual(afterFailure.homeName, "Original")
        try await withGateTask(successfulWrite, operation: { try await contributor.rename("Updated") }) { successful in
            let beforeSuccess = try await contributor.refresh()
            XCTAssertEqual(beforeSuccess.homeName, "Original")
            successfulWrite.finish(true)
            try await successful.value
        }
        let afterSuccess = try await contributor.refresh()
        XCTAssertEqual(afterSuccess.homeName, "Updated")
        XCTAssertEqual(renameCalls, 2)
        do { _ = try await contributor.invite(false); XCTFail("Contributors cannot invite") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .ownerRequired) }
        var restrictedWrites = 0
        let restricted = try XCTUnwrap(HomeDetailsUITestFixture.make(scope: scope, name: "Read-only", rename: { _ in
            restrictedWrites += 1
        }, environment: ["SHOPPING_UI_TEST_STORE_PATH": path, "SHOPPING_UI_TEST_HOME_MEMBERS": "restricted"]))
        do { try await restricted.rename("Forbidden"); XCTFail("Restricted rename must be rejected") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .unsupportedAccess) }
        do { _ = try await restricted.invite(false); XCTFail("Restricted invite must be rejected") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .ownerRequired) }
        XCTAssertEqual(restrictedWrites, 0)
        let unchanged = try await restricted.refresh()
        XCTAssertEqual(unchanged.homeName, "Read-only")
        XCTAssertEqual(unchanged.pendingCount, 0)
    }
#endif

}
