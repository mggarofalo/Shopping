import CloudKit
import CoreData
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
        var removalActions: HomeDetailsRemovalActions?
        var leaveActions: HomeDetailsLeaveActions?

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
            }, removals: removalActions, leave: leaveActions)
        }
    }

    func testRecoveryIsVisibleBeforeNetworkRefreshAndAfterReopeningOffline() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        actions.pending = .init(id: UUID(), participantID: "retained", phase: .submitted)
        actions.refreshOperation = { throw CKError(.networkUnavailable) }
        for _ in 0..<2 {
            let model = HomeDetailsModel(scope: scope, actions: actions.actions)
            await model.refresh()
            XCTAssertEqual(model.pending, actions.pending)
            XCTAssertFalse(model.isCurrent)
            XCTAssertFalse(model.canInvite)
            XCTAssertNil(model.snapshot)
            XCTAssertEqual(model.refreshError, "iCloud couldn’t be reached. Check your connection and try again.")
        }
        var recoveredActions = actions.actions
        recoveredActions.preparationNeedsRetry = { true }
        let preparing = HomeDetailsModel(scope: scope, actions: recoveredActions)
        await preparing.refresh()
        XCTAssertTrue(preparing.needsPreparationRetry)
    }

    func testInviteFailurePreservesGraphReasonWithoutInventingAnInvitation() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        actions.inviteOperation = { throw HomeShareGraphValidator.Failure.ambiguousIdentity }
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.invite()
        XCTAssertNil(model.pending)
        XCTAssertNil(model.delivery)
        XCTAssertEqual(model.error, HomeShareGraphValidator.Failure.ambiguousIdentity.localizedDescription)
        XCTAssertTrue(model.canInvite)
        XCTAssertFalse(model.busy)
    }

    func testSharingFailuresDistinguishConnectionAccountStorageAndUnknownErrors() {
        XCTAssertTrue(HomeSharingErrorPresentation.message(CKError(.notAuthenticated)).contains("Sign in"))
        XCTAssertTrue(HomeSharingErrorPresentation.message(CKError(.quotaExceeded)).contains("storage is full"))
        XCTAssertTrue(HomeSharingErrorPresentation.message(CKError(.invalidArguments)).contains("error 12"))
        let disk = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertTrue(HomeSharingErrorPresentation.message(disk).contains("saved sharing information"))
        XCTAssertFalse(HomeSharingErrorPresentation.message(disk).contains("invitation have been retained"))
    }

    private func scope() throws -> ActiveHomeScope {
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-details",
            environment: "Development", accountRecordName: "owner")
        return ActiveHomeScope(session: session, graph: HomeGraphIdentity(storeIdentifier: UUID().uuidString,
            rootURI: "x-coredata://isolated/Household/" + UUID().uuidString, householdID: UUID(), listID: UUID()))
    }

    private func leaveSnapshot(scope: ActiveHomeScope,
        access: HomeMembershipSnapshot.Access = .contributor,
        acceptance: HomeMember.Acceptance = .accepted) -> HomeMembershipSnapshot {
        snapshot(scope: scope, access: access, members: [HomeMember(id: "self", name: "You",
            role: access == .owner ? .owner : (access == .restricted ? .restricted : .contributor),
            acceptance: acceptance, isCurrentUser: true, canResend: false)])
    }

    private func leaveCommand(scope: ActiveHomeScope, origin: HomeNativeAccessIdentity? = nil,
        participantID: String = "self") throws -> HomeLeaveCommand {
        let session = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "owner")
        return HomeLeaveCommand(id: UUID(), origin: origin ?? HomeNativeAccessIdentity(
            scope: HomeEffectScope(session: session, householdID: scope.graph.householdID, listID: scope.graph.listID),
            storeIdentifier: scope.graph.storeIdentifier, rootURI: scope.graph.rootURI,
            share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "owner")),
            storeURL: URL(fileURLWithPath: "/tmp/" + UUID().uuidString + ".sqlite"),
            participantID: participantID, homeName: "Our home",
            evidence: HomeLeaveEvidence(checkoutIDs: [], restoreIDs: [], unresolvedRestoreIDs: [], cartGenerations: []),
            confirmedAt: Date())
    }

    func testAcceptedContributorAndReadOnlyMemberCanConfirmLeaveOnlyOnceWithoutClaimingCompletion() async throws {
        for access in [HomeMembershipSnapshot.Access.contributor, .restricted] {
            let scope = try scope()
            let command = try leaveCommand(scope: scope)
            let actions = Actions(value: leaveSnapshot(scope: scope, access: access))
            var prepared = 0, confirmed: [UUID] = []
            actions.leaveActions = HomeDetailsLeaveActions(prepare: {
                prepared += 1
                return command
            }, confirm: {
                confirmed.append($0.id)
                return HomeLeaveStatus(command: $0, submitted: true, completed: false)
            })
            let model = HomeDetailsModel(scope: scope, actions: actions.actions)
            await model.refresh()
            XCTAssertTrue(model.canLeave)
            await model.prepareLeave()
            XCTAssertEqual(prepared, 1)
            XCTAssertEqual(model.leaveConfirmation, command)
            XCTAssertTrue(confirmed.isEmpty, "Preparing disclosure does not authorize leaving")
            await model.confirmLeave(command)
            await model.confirmLeave(command)
            XCTAssertEqual(confirmed, [command.id])
            XCTAssertNil(model.leaveConfirmation)
            let status = try XCTUnwrap(model.leaveStatus)
            XCTAssertTrue(status.submitted)
            XCTAssertFalse(status.completed, "A pending result must not claim that native leave completed")
            XCTAssertTrue(status.requiresResolution)
            XCTAssertFalse(model.canLeave)
            XCTAssertFalse(model.busy)
            XCTAssertNil(model.error)
        }
    }

    func testOwnerAndUnacceptedParticipantCannotPrepareOrConfirmLeave() async throws {
        let scope = try scope()
        let command = try leaveCommand(scope: scope)
        for (access, acceptance) in [(HomeMembershipSnapshot.Access.owner, HomeMember.Acceptance.accepted),
                                     (.contributor, .pending), (.restricted, .unknown)] {
            let actions = Actions(value: leaveSnapshot(scope: scope, access: access, acceptance: acceptance))
            var calls = 0
            actions.leaveActions = HomeDetailsLeaveActions(prepare: { calls += 1; return command },
                confirm: { calls += 1; return HomeLeaveStatus(command: $0, submitted: true, completed: true) })
            let model = HomeDetailsModel(scope: scope, actions: actions.actions)
            await model.refresh()
            XCTAssertFalse(model.canLeave)
            await model.prepareLeave()
            model.leaveConfirmation = command
            await model.confirmLeave(command)
            XCTAssertEqual(calls, 0)
            XCTAssertNil(model.leaveStatus)
        }
    }

    func testCancelledAndReplacedLeaveConfirmationCannotAuthorizeOldCommand() async throws {
        let scope = try scope()
        let old = try leaveCommand(scope: scope), replacement = try leaveCommand(scope: scope)
        var next = old, confirmed: [UUID] = []
        let actions = Actions(value: leaveSnapshot(scope: scope))
        actions.leaveActions = HomeDetailsLeaveActions(prepare: { next }, confirm: {
            confirmed.append($0.id)
            return HomeLeaveStatus(command: $0, submitted: true, completed: true)
        })
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.prepareLeave()
        model.leaveConfirmation = nil
        await model.confirmLeave(old)
        XCTAssertTrue(confirmed.isEmpty)
        next = replacement
        await model.prepareLeave()
        await model.confirmLeave(old)
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertEqual(model.leaveConfirmation, replacement)
        await model.confirmLeave(replacement)
        XCTAssertEqual(confirmed, [replacement.id])
        XCTAssertEqual(model.leaveStatus?.completed, true)
    }

    func testLeavePreparationRejectsEveryAccountGraphShareAndParticipantDrift() async throws {
        let scope = try scope()
        let valid = try leaveCommand(scope: scope)
        let base = valid.origin
        func changed(session: ShopperSession? = nil, store: String? = nil, root: String? = nil,
            home: UUID? = nil, list: UUID? = nil, share: HomeEffectShare? = nil) throws -> HomeLeaveCommand {
            let session = try session ?? ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
                environment: scope.environment, accountRecordName: "owner")
            return try leaveCommand(scope: scope, origin: HomeNativeAccessIdentity(
                scope: HomeEffectScope(session: session, householdID: home ?? scope.graph.householdID,
                    listID: list ?? scope.graph.listID), storeIdentifier: store ?? base.storeIdentifier,
                rootURI: root ?? base.rootURI, share: share ?? base.share))
        }
        let account = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: scope.environment, accountRecordName: "other")
        let container = try ShopperSession.authenticated(containerIdentifier: "iCloud.other",
            environment: scope.environment, accountRecordName: "owner")
        let environment = try ShopperSession.authenticated(containerIdentifier: scope.containerIdentifier,
            environment: "Production", accountRecordName: "owner")
        let cases: [(String, HomeLeaveCommand)] = try [
            ("account", changed(session: account)), ("container", changed(session: container)),
            ("environment", changed(session: environment)), ("store", changed(store: "replacement")),
            ("root", changed(root: "x-coredata://replacement/Household/root")),
            ("home UUID", changed(home: UUID())), ("list UUID", changed(list: UUID())),
            ("share", changed(share: HomeEffectShare(recordName: "other", zoneName: "zone", zoneOwnerName: "owner"))),
            ("zone", changed(share: HomeEffectShare(recordName: "share", zoneName: "other", zoneOwnerName: "owner"))),
            ("zone owner", changed(share: HomeEffectShare(recordName: "share", zoneName: "zone", zoneOwnerName: "other"))),
            ("participant", leaveCommand(scope: scope, participantID: "other"))
        ]
        for (field, command) in cases {
            let actions = Actions(value: leaveSnapshot(scope: scope))
            var confirmations = 0
            actions.leaveActions = HomeDetailsLeaveActions(prepare: { command }, confirm: {
                confirmations += 1
                return HomeLeaveStatus(command: $0, submitted: true, completed: true)
            })
            let model = HomeDetailsModel(scope: scope, actions: actions.actions)
            await model.refresh()
            await model.prepareLeave()
            XCTAssertNil(model.leaveConfirmation, field)
            XCTAssertNotNil(model.error, field)
            XCTAssertFalse(model.busy, field)
            await model.confirmLeave(command)
            XCTAssertEqual(confirmations, 0, field)
        }
    }

    func testRetiredLeavePreparationCannotPresentConfirmation() async throws {
        let scope = try scope()
        let command = try leaveCommand(scope: scope)
        let gate = Gate<HomeLeaveCommand>()
        let actions = Actions(value: leaveSnapshot(scope: scope))
        actions.leaveActions = HomeDetailsLeaveActions(prepare: { try await gate.wait() },
            confirm: { HomeLeaveStatus(command: $0, submitted: true, completed: true) })
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        try await withGateTask(gate, operation: { await model.prepareLeave() }) { task in
            model.retire()
            gate.finish(command)
            try await task.value
            XCTAssertNil(model.leaveConfirmation)
            XCTAssertNil(model.leaveStatus)
            XCTAssertFalse(model.canLeave)
            XCTAssertFalse(model.busy)
        }
    }

    func testRetiredLeaveConfirmationIgnoresCompletionAndRepeatedTapWhileHeld() async throws {
        let scope = try scope()
        let command = try leaveCommand(scope: scope)
        let gate = Gate<HomeLeaveStatus>()
        let actions = Actions(value: leaveSnapshot(scope: scope))
        var confirmations = 0
        actions.leaveActions = HomeDetailsLeaveActions(prepare: { command }, confirm: { _ in
            confirmations += 1
            return try await gate.wait()
        })
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.prepareLeave()
        try await withGateTask(gate, operation: { await model.confirmLeave(command) }) { task in
            XCTAssertNil(model.leaveConfirmation)
            await model.confirmLeave(command)
            XCTAssertEqual(confirmations, 1)
            model.retire()
            gate.finish(HomeLeaveStatus(command: command, submitted: true, completed: true))
            try await task.value
            XCTAssertNil(model.leaveStatus)
            XCTAssertNil(model.leaveConfirmation)
            XCTAssertFalse(model.isCurrent)
            XCTAssertFalse(model.busy)
        }
    }

    func testRemovalPreparationHasNoEffectUntilMatchingConfirmationAndRetirementFencesResult() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: actions.value.share!,
            ownerParticipantID: "self", participantIDs: ["friend"], cancelledInvitationID: nil,
            purpose: .removeMember, confirmedAt: Date())
        let confirmation = HomeMembershipRemovalConfirmation(removal: removal, homeName: "Our home", memberNames: ["Friend"])
        let gate = Gate<HomeMembershipSnapshot>()
        var confirmations: [UUID] = []
        actions.removalActions = HomeDetailsRemovalActions(prepare: { _, _ in confirmation }, confirm: {
            confirmations.append($0.id)
            return try await gate.wait()
        }, retry: { actions.value })
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.prepareRemoval(.removeMember, participantID: "friend")
        XCTAssertEqual(model.removalConfirmation?.id, confirmation.id)
        XCTAssertTrue(confirmations.isEmpty)
        model.removalConfirmation = nil
        await model.confirmRemoval(confirmation)
        XCTAssertTrue(confirmations.isEmpty, "Dismissing confirmation must not authorize removal")
        await model.prepareRemoval(.removeMember, participantID: "friend")
        try await withGateTask(gate, operation: { await model.confirmRemoval(confirmation) }) { task in
            XCTAssertEqual(confirmations, [confirmation.id])
            XCTAssertNil(model.removalConfirmation)
            model.retire()
            gate.finish(actions.value)
            try await task.value
            XCTAssertFalse(model.isCurrent)
            XCTAssertFalse(model.canManageMembers)
            XCTAssertNil(model.removalConfirmation)
        }
    }

    func testRemovalFailureShowsRetainedRetryStateWithoutAutomaticSecondConfirmation() async throws {
        let scope = try scope()
        let actions = Actions(value: snapshot(scope: scope))
        let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: actions.value.share!,
            ownerParticipantID: "self", participantIDs: ["friend"], cancelledInvitationID: nil,
            purpose: .removeMember, confirmedAt: Date())
        let confirmation = HomeMembershipRemovalConfirmation(removal: removal, homeName: "Our home", memberNames: ["Friend"])
        var confirmations = 0, retries = 0
        actions.removalActions = HomeDetailsRemovalActions(prepare: { _, _ in confirmation }, confirm: { _ in
            confirmations += 1
            actions.value.removals = [HomeMembershipRemovalStatus(removal: removal, requiresRetry: true)]
            throw HomeMembershipError.outcomeUncertain
        }, retry: {
            retries += 1
            actions.value.removals = [HomeMembershipRemovalStatus(removal: removal, absentObservedAt: Date())]
            return actions.value
        })
        let model = HomeDetailsModel(scope: scope, actions: actions.actions)
        await model.refresh()
        await model.prepareRemoval(.removeMember, participantID: "friend")
        await model.confirmRemoval(confirmation)
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(retries, 0)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.snapshot?.removals.first?.requiresRetry ?? false)
        await model.retryRemovals()
        XCTAssertEqual(retries, 1)
        XCTAssertNotNil(model.snapshot?.removals.first?.absentObservedAt)
        XCTAssertNil(model.error)
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
            XCTAssertTrue(model.isRefreshing)
            XCTAssertFalse(model.busy)
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

    private struct FixedSession: ShopperSessionProviding {
        let session: ShopperSession
        func currentSession() throws -> ShopperSession { session }
    }

    func testBlockedRenameWriterShowsProgressAndKeepsMainActorResponsive() async throws {
        let persistence = try PersistenceController(inMemory: true)
        let needs = NeedService(persistence: persistence)
        _ = try needs.createHousehold(name: "Original")
        let graph = try XCTUnwrap(HomeDiscoveryService(persistence: persistence).discover().homes.first?.graph)
        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.home-details",
            environment: "Development", accountRecordName: "owner")
        let cart = PersonalCartService(persistence: persistence, sessionProvider: FixedSession(session: session))
        let home = ActiveHomeScope(session: session, graph: graph)
        let fake = Actions(value: snapshot(scope: home))
        let base = fake.actions
        let actions = HomeDetailsActions(refresh: base.refresh, pending: base.pending,
            invite: base.invite, resend: base.resend, acknowledge: base.acknowledge,
            rename: { name in
                try await Task.detached { try needs.renameHome(name: name, scope: home) }.value
            })
        let model = HomeDetailsModel(scope: home, actions: actions)
        await model.refresh()
        let entered = expectation(description: "Writer occupied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            persistence.writer.performAndWait {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let started = ContinuousClock.now
        let rename = Task { await model.rename("Updated") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(250))
        XCTAssertEqual(model.operation, .renaming)
        XCTAssertFalse(model.canRename)
        release.signal()
        let saved = await rename.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.snapshot?.homeName, "Updated")
        XCTAssertNil(model.operation)
        let homes = try HomeDiscoveryService(persistence: persistence).discover().homes
        XCTAssertEqual(homes.first?.name, "Updated")
        withExtendedLifetime(cart) {}
    }

    func testDelayedRefreshCoalescesAndKeepsCachedEditorsAvailable() async throws {
        let actions = Actions(value: snapshot(scope: try scope()))
        let model = HomeDetailsModel(scope: actions.value.scope, actions: actions.actions)
        await model.refresh()
        let gate = Gate<HomeMembershipSnapshot>()
        var refreshCount = 0
        actions.refreshOperation = {
            refreshCount += 1
            return try await gate.wait()
        }
        try await withGateTask(gate, operation: { await model.refresh() }) { first in
            XCTAssertTrue(model.isRefreshing)
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.canRename)
            XCTAssertTrue(model.canInvite)
            XCTAssertEqual(model.snapshot, actions.value)
            let secondStarted = expectation(description: "Second refresh requested")
            let second = Task {
                secondStarted.fulfill()
                await model.refresh()
            }
            await fulfillment(of: [secondStarted], timeout: 2)
            XCTAssertEqual(refreshCount, 1)
            gate.finish(actions.value)
            try await first.value
            await second.value
            XCTAssertEqual(refreshCount, 1)
            XCTAssertFalse(model.isRefreshing)
        }
    }

    func testOfflineRefreshRetainsPermissionsAndRenameDoesNotAwaitNetwork() async throws {
        let actions = Actions(value: snapshot(scope: try scope()))
        let model = HomeDetailsModel(scope: actions.value.scope, actions: actions.actions)
        await model.refresh()
        actions.refreshOperation = { throw CKError(.networkUnavailable) }
        await model.refresh()
        XCTAssertFalse(model.isCurrent)
        XCTAssertNotNil(model.refreshError)
        XCTAssertEqual(model.snapshot, actions.value)
        XCTAssertTrue(model.canRename)
        XCTAssertTrue(model.canInvite)
        let renamed = await model.rename("  New name  ")
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.snapshot?.homeName, "New name")
        XCTAssertNil(model.error)
    }

    func testRefreshStartedBeforeRenameCannotOverwriteCommittedNameOrPublishFailure() async throws {
        for fails in [false, true] {
            let actions = Actions(value: snapshot(scope: try scope()))
            let model = HomeDetailsModel(scope: actions.value.scope, actions: actions.actions)
            await model.refresh()
            let gate = Gate<HomeMembershipSnapshot>()
            actions.refreshOperation = { try await gate.wait() }
            try await withGateTask(gate, operation: { await model.refresh() }) { refresh in
                let renamed = await model.rename("New name")
                XCTAssertTrue(renamed, "Durable save finishes while the old network request is suspended")
                XCTAssertEqual(model.snapshot?.homeName, "New name")
                if fails { gate.cancel() } else { gate.finish(actions.value) }
                try await refresh.value
                XCTAssertEqual(model.snapshot?.homeName, "New name")
                XCTAssertNil(model.refreshError)
                XCTAssertTrue(model.canRename)
            }
        }
    }

    func testRefreshDuringCommandCannotClearProgressOrAllowSecondMutation() async throws {
        let actions = Actions(value: snapshot(scope: try scope()))
        let model = HomeDetailsModel(scope: actions.value.scope, actions: actions.actions)
        await model.refresh()
        let gate = Gate<HomeInvitationDelivery>()
        actions.inviteOperation = { try await gate.wait() }
        try await withGateTask(gate, operation: { await model.invite() }) { invitation in
            XCTAssertEqual(model.operation, .inviting)
            XCTAssertEqual(model.operation?.label, "Creating invitation…")
            await model.refresh()
            XCTAssertEqual(model.operation, .inviting)
            await model.invite()
            XCTAssertEqual(actions.invitationRetries.count, 1)
            gate.finish(actions.delivery)
            try await invitation.value
            XCTAssertNil(model.operation)
            XCTAssertTrue(model.canInvite)
        }
    }

    func testReactivationWhileOldRefreshIsDrainingStartsOneFreshRead() async throws {
        let actions = Actions(value: snapshot(scope: try scope()))
        let model = HomeDetailsModel(scope: actions.value.scope, actions: actions.actions)
        let gate = Gate<HomeMembershipSnapshot>()
        actions.refreshOperation = { try await gate.wait() }
        try await withGateTask(gate, operation: { await model.refresh() }) { old in
            model.retire()
            model.activate()
            actions.refreshOperation = nil
            let restarted = Task { await model.refresh() }
            await Task.yield()
            gate.finish(actions.value)
            try await old.value
            await restarted.value
            XCTAssertEqual(model.snapshot, actions.value)
            XCTAssertTrue(model.isCurrent)
            XCTAssertTrue(model.canRename)
            XCTAssertFalse(model.isRefreshing)
        }
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
        XCTAssertEqual(model.refreshError, HomeMembershipError.scopeChanged.localizedDescription)
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

    func testNamedInvitationFixtureRetainsIdentityAcrossRelaunchAndIsolatesStores() async throws {
        let scope = try scope()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Shopping.sqlite").path
        func make(_ storePath: String, role: String = "owner") throws -> HomeDetailsActions {
            try XCTUnwrap(HomeDetailsUITestFixture.make(scope: scope, name: "Original", rename: { _ in },
                environment: ["SHOPPING_UI_TEST_STORE_PATH": storePath, "SHOPPING_UI_TEST_HOME_MEMBERS": role]))
        }
        let actions = try make(path)
        let named = try XCTUnwrap(actions.namedInvitations)
        let draft = try await named.prepare("  Beka  ")
        XCTAssertEqual(draft.name, "Beka")
        XCTAssertTrue(draft.participantIDs.isEmpty)
        let reused = try await named.prepare("beka")
        XCTAssertEqual(reused.id, draft.id)
        let delivery = try await named.create(draft.id, false)
        XCTAssertEqual(delivery.url.host, "example.invalid")
        XCTAssertEqual(delivery.participantID, "fixture-invitation-1")
        let membership = try await actions.refresh()
        XCTAssertEqual(membership.pendingCount, 1)
        XCTAssertEqual(membership.acceptedOtherCount, 1)

        let restoredActions = try make(path)
        let restored = try XCTUnwrap(restoredActions.namedInvitations)
        let records = try await restored.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, draft.id)
        XCTAssertEqual(records.first?.participantID, delivery.participantID)
        XCTAssertNil(records.first?.lastHandoffAt, "Opening or dismissing the sheet cannot claim handoff")
        let resent = try await restored.create(draft.id, false)
        XCTAssertEqual(resent.url, delivery.url)
        try await restored.handoff(draft.id)
        let handedOff = try await restored.load()
        XCTAssertNotNil(handedOff.first?.lastHandoffAt)
        let afterHandoff = try await restoredActions.refresh()
        XCTAssertEqual(afterHandoff.pendingCount, 1, "Handoff is not acceptance")

        let other = try XCTUnwrap(make(directory.appendingPathComponent("Other.sqlite").path).namedInvitations)
        let isolated = try await other.load()
        XCTAssertTrue(isolated.isEmpty, "Even stores in one directory must have separate fixture state")
        let discarded = try await other.prepare("Draft to discard")
        try await other.discard(discarded.id)
        let discardedRecords = try await other.load()
        XCTAssertEqual(discardedRecords.first?.isTerminal, true)
        let confirmation = try await restored.cancel(draft.id)
        XCTAssertEqual(confirmation.memberNames, ["Beka"])
        let removals = try XCTUnwrap(restoredActions.removals)
        _ = try await removals.confirm(confirmation)
        let afterCancellation = try make(path)
        let finalRecords = try await XCTUnwrap(afterCancellation.namedInvitations).load()
        XCTAssertEqual(finalRecords.first?.isTerminal, true)
        let finalMembership = try await afterCancellation.refresh()
        XCTAssertEqual(finalMembership.pendingCount, 0)
        XCTAssertEqual(finalMembership.acceptedOtherCount, 1)

        let contributor = try XCTUnwrap(make(path, role: "contributor").namedInvitations)
        do { _ = try await contributor.prepare("Forbidden"); XCTFail("Only the owner can prepare an invitation") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .ownerRequired) }
        do { _ = try await contributor.create(draft.id, false); XCTFail("Only the owner can create an invitation") }
        catch { XCTAssertEqual(error as? HomeMembershipError, .ownerRequired) }
    }

    func testNamedInvitationFixtureFailureRetainsDraftAndRetryCreatesOnlyOneParticipant() async throws {
        let scope = try scope()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actions = try XCTUnwrap(HomeDetailsUITestFixture.make(scope: scope, name: "Original", rename: { _ in },
            environment: ["SHOPPING_UI_TEST_STORE_PATH": directory.appendingPathComponent("Shopping.sqlite").path,
                "SHOPPING_UI_TEST_HOME_MEMBERS": "owner", "SHOPPING_UI_TEST_HOME_INVITE_FAILURE": "1"]))
        let named = try XCTUnwrap(actions.namedInvitations)
        let draft = try await named.prepare("Beka")
        do { _ = try await named.create(draft.id, false); XCTFail("The fixture must expose the actual backend failure") }
        catch { XCTAssertEqual(error.localizedDescription, HomeShareGraphValidator.Failure.ambiguousIdentity.localizedDescription) }
        let failedRecords = try await named.load()
        XCTAssertEqual(failedRecords.map(\.id), [draft.id])
        XCTAssertTrue(failedRecords[0].participantIDs.isEmpty)
        let failedSnapshot = try await actions.refresh()
        XCTAssertEqual(failedSnapshot.pendingCount, 0)
        let delivery = try await named.create(draft.id, true)
        XCTAssertEqual(delivery.participantID, "fixture-invitation-1")
        let retriedSnapshot = try await actions.refresh()
        XCTAssertEqual(retriedSnapshot.pendingCount, 1)
        let retriedRecords = try await named.load()
        XCTAssertEqual(retriedRecords.map(\.id), [draft.id])
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
