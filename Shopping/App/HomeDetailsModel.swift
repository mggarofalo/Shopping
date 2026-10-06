import Foundation
import SwiftUI

/// UI state contains values only. Every action revalidates the captured home before
/// execution; a retired presentation cannot publish a link into its replacement.
@MainActor
final class HomeDetailsModel: ObservableObject {
    let scope: ActiveHomeScope
    private let actions: HomeDetailsActions
    @Published private(set) var snapshot: HomeMembershipSnapshot?
    @Published private(set) var pending: HomeMembershipCoordinator.Pending?
    enum Operation: Equatable {
        case renaming, inviting, resending(participantID: String)
        case preparingRemoval, removing, preparingLeave, leaving
        case preparingDeletion, deleting, checkingDeletion

        var label: String {
            switch self {
            case .renaming: return "Saving name…"
            case .inviting: return "Creating invitation…"
            case .resending: return "Preparing invitation…"
            case .preparingRemoval: return "Checking membership…"
            case .removing: return "Updating membership…"
            case .preparingLeave: return "Preparing to leave…"
            case .leaving: return "Leaving home…"
            case .preparingDeletion: return "Preparing to delete…"
            case .deleting: return "Deleting home…"
            case .checkingDeletion: return "Checking deletion…"
            }
        }
    }

    @Published private(set) var operation: Operation?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?
    var busy: Bool { operation != nil }
    @Published private(set) var isCurrent = false
    @Published private(set) var error: String?
    @Published private(set) var needsPreparationRetry = false
    @Published var delivery: HomeInvitationDelivery?
    @Published var removalConfirmation: HomeMembershipRemovalConfirmation?
    @Published var leaveConfirmation: HomeLeaveCommand?
    @Published private(set) var leaveStatus: HomeLeaveStatus?
    @Published var deletionConfirmation: HomeDeletionCommand?
    @Published private(set) var deletionStatus: HomeDeletionStatus?
    private var generation = 0
    private var active = true
    private var authorityRevoked = false
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshGeneration: Int?
    private var refreshRequested = false

    init(scope: ActiveHomeScope, actions: HomeDetailsActions) {
        self.scope = scope
        self.actions = actions
    }

    var canInvite: Bool { active && !authorityRevoked && !busy && snapshot?.canInvite == true }
    var canRename: Bool { active && !authorityRevoked && !busy && snapshot?.canEditName == true }
    var canManageMembers: Bool { canInvite && snapshot?.source == .server && actions.removals != nil }

    var canLeave: Bool {
        active && !authorityRevoked && !busy && actions.leave != nil && leaveStatus == nil && acceptedParticipant != nil
    }

    var canDelete: Bool {
        active && !authorityRevoked && !busy && snapshot?.access == .owner && actions.deletion != nil && deletionStatus == nil
    }
    var hasDeletionAction: Bool { actions.deletion != nil }

    private var acceptedParticipant: HomeMember? {
        guard let snapshot, snapshot.scope == scope, snapshot.source == .server,
              snapshot.access != .owner, snapshot.share != nil,
              let participantID = snapshot.currentParticipantID, !participantID.isEmpty else { return nil }
        let current = snapshot.members.filter { $0.isCurrentUser }
        guard current.count == 1, let member = current.first, member.id == participantID,
              snapshot.members.filter({ $0.id == participantID }).count == 1,
              member.role != .owner, member.acceptance == .accepted else { return nil }
        return member
    }

    func activate() { active = true }
    func retire() {
        active = false
        generation += 1
        isCurrent = false
        operation = nil
        isRefreshing = false
        refreshRequested = false
        delivery = nil
        removalConfirmation = nil
        leaveConfirmation = nil
        deletionConfirmation = nil
    }

    /// Concurrent appearance/import requests share one read. A command invalidates
    /// its publication generation without cancelling durable coordinator work.
    func refresh() async {
        guard active else { return }
        guard !busy else {
            refreshRequested = true
            return
        }
        if let refreshTask {
            if refreshGeneration != generation { refreshRequested = true }
            await refreshTask.value
            return
        }
        let request = generation
        let id = UUID()
        refreshID = id
        refreshGeneration = request
        isRefreshing = true
        refreshError = nil
        let task = Task { [self] in
            await refreshState(request: request)
            guard refreshID == id else { return }
            refreshTask = nil
            refreshID = nil
            refreshGeneration = nil
            isRefreshing = false
            if refreshRequested, active, !busy {
                refreshRequested = false
                await refresh()
            }
        }
        refreshTask = task
        await task.value
    }

    private func begin(_ operation: Operation) -> Int {
        generation += 1
        self.operation = operation
        error = nil
        return generation
    }

    private func finish(_ request: Int) {
        guard active, generation == request else { return }
        operation = nil
        if refreshRequested, refreshTask == nil {
            refreshRequested = false
            Task { await refresh() }
        }
    }

    private func recordRefreshFailure(_ failure: Error) {
        isCurrent = false
        refreshError = HomeSharingErrorPresentation.message(failure)
        if failure as? HomeMembershipError == .scopeChanged {
            authorityRevoked = true
        }
    }

    /// Durable recovery is useful even when membership cannot be fetched from iCloud.
    private func refreshState(request: Int) async {
        do {
            let pending = try await actions.pending()
            let preparation = try await actions.preparationNeedsRetry?()
            guard active, generation == request else { return }
            self.pending = pending
            if let preparation { needsPreparationRetry = preparation }
        } catch {
            guard active, generation == request else { return }
            recordRefreshFailure(error)
            HomeSharingErrorPresentation.record(error, operation: "Read invitation recovery")
            return
        }
        do {
            let result = try await actions.refresh()
            // Membership reconciliation may retire an already accepted invitation.
            let pending = try await actions.pending()
            guard active, generation == request else { return }
            guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
            snapshot = result
            self.pending = pending
            isCurrent = true
            authorityRevoked = false
            refreshError = nil
        } catch {
            guard active, generation == request else { return }
            recordRefreshFailure(error)
            HomeSharingErrorPresentation.record(error, operation: "Refresh members")
        }
    }

    func invite(retryPreparation: Bool = false) async {
        guard canInvite else { return }
        await deliver(operation: .inviting) { try await self.actions.invite(retryPreparation) }
    }

    func resend(_ participantID: String) async {
        guard canInvite else { return }
        await deliver(operation: .resending(participantID: participantID)) { try await self.actions.resend(participantID) }
    }

    func prepareLeave() async {
        guard canLeave, let actions = actions.leave else { return }
        let request = begin(.preparingLeave)
        leaveConfirmation = nil
        defer { finish(request) }
        do {
            let command = try await actions.prepare()
            guard active, generation == request else { return }
            try command.validate()
            guard matchesLeave(command) else { throw HomeMembershipError.scopeChanged }
            leaveConfirmation = command
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    func prepareDeletion() async {
        guard canDelete, let deletion = actions.deletion else { return }
        let request = begin(.preparingDeletion)
        defer { finish(request) }
        do {
            let command = try await deletion.prepare()
            guard active, generation == request else { return }
            guard command.scope == scope else { throw HomeDeletionError.scopeChanged }
            deletionConfirmation = command
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    func confirmDeletion(_ command: HomeDeletionCommand) async {
        guard canDelete, deletionConfirmation == command, command.scope == scope, let deletion = actions.deletion else { return }
        deletionConfirmation = nil
        let request = begin(.deleting)
        defer { finish(request) }
        do {
            let status = try await deletion.confirm(command)
            guard active, generation == request else { return }
            deletionStatus = status
            error = nil
        } catch {
            let operationError = error
            let status = try? await deletion.reconcile(command)
            guard active, generation == request else { return }
            deletionStatus = status ?? HomeDeletionStatus(command: command, submitted: false, completed: false)
            self.error = HomeSharingErrorPresentation.message(operationError)
        }
    }

    func retryDeletion() async {
        guard active, !busy, let status = deletionStatus, let deletion = actions.deletion else { return }
        let request = begin(.checkingDeletion)
        defer { finish(request) }
        do {
            let refreshed = try await deletion.reconcile(status.command)
            guard active, generation == request else { return }
            deletionStatus = refreshed
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    func confirmLeave(_ command: HomeLeaveCommand) async {
        guard canLeave, leaveConfirmation == command, matchesLeave(command),
              let actions = actions.leave else { return }
        // Consume this exact confirmation before the first suspension. A repeated
        // tap cannot submit it again, even if its native outcome is uncertain.
        leaveConfirmation = nil
        let request = begin(.leaving)
        defer { finish(request) }
        do {
            let status = try await actions.confirm(command)
            guard active, generation == request else { return }
            guard status.command == command, matchesLeave(command) else { throw HomeMembershipError.scopeChanged }
            leaveStatus = status
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    private func matchesLeave(_ command: HomeLeaveCommand) -> Bool {
        guard let member = acceptedParticipant, let share = snapshot?.share else { return false }
        let origin = command.origin
        return command.participantID == member.id
            && origin.scope.accountBinding == scope.accountBinding
            && origin.scope.containerIdentifier == scope.containerIdentifier
            && origin.scope.environment == scope.environment
            && origin.scope.householdID == scope.graph.householdID
            && origin.scope.listID == scope.graph.listID
            && origin.storeIdentifier == scope.graph.storeIdentifier
            && origin.rootURI == scope.graph.rootURI
            && origin.share.recordName == share.recordName
            && origin.share.zoneName == share.zoneName
            && origin.share.zoneOwnerName == share.zoneOwnerName
    }

    func prepareRemoval(_ purpose: HomeMembershipRemoval.Purpose, participantID: String? = nil) async {
        guard canManageMembers, let actions = actions.removals else { return }
        let request = begin(.preparingRemoval)
        defer { finish(request) }
        do {
            let confirmation = try await actions.prepare(purpose, participantID)
            guard active, generation == request else { return }
            guard confirmation.removal.origin == scope else { throw HomeMembershipError.scopeChanged }
            removalConfirmation = confirmation
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    func confirmRemoval(_ confirmation: HomeMembershipRemovalConfirmation) async {
        guard canManageMembers, removalConfirmation?.id == confirmation.id,
              confirmation.removal.origin == scope, let actions = actions.removals else { return }
        removalConfirmation = nil
        delivery = nil
        await updateRemoval { try await actions.confirm(confirmation) }
    }

    func retryRemovals() async {
        guard canManageMembers, let actions = actions.removals else { return }
        await updateRemoval { try await actions.retry() }
    }

    private func updateRemoval(_ operation: () async throws -> HomeMembershipSnapshot) async {
        let request = begin(.removing)
        defer { finish(request) }
        do {
            let result = try await operation()
            let pending = try await actions.pending()
            guard active, generation == request else { return }
            guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
            snapshot = result
            self.pending = pending
            isCurrent = true
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
            // The durable intent may already exist even if iCloud did not finish.
            // Refresh exposes that retained state without repeating its mutation.
            do {
                await refreshTask?.value
                guard active, generation == request else { return }
                let result = try await actions.refresh()
                let pending = try await actions.pending()
                guard active, generation == request else { return }
                guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
                snapshot = result
                self.pending = pending
                isCurrent = true
            } catch {
                guard active, generation == request else { return }
                isCurrent = false
            }
        }
    }

    private func deliver(operation: Operation, action: () async throws -> HomeInvitationDelivery) async {
        let request = begin(operation)
        defer { finish(request) }
        needsPreparationRetry = false
        do {
            let result = try await action()
            guard active, generation == request else { return }
            guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
            delivery = result
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
            HomeSharingErrorPresentation.record(error, operation: "Deliver invitation")
            if case HomeSharingError.retryRequired = error { needsPreparationRetry = true }
        }
        guard active, generation == request else { return }
        // Drain an older passive read before reconciling the command result.
        // Its generation cannot overwrite the command's presentation.
        await refreshTask?.value
        guard active, generation == request else { return }
        await refreshState(request: request)
    }

    func presented(_ delivery: HomeInvitationDelivery) async {
        guard active, delivery.scope == scope, self.delivery?.id == delivery.id else { return }
        let request = generation
        do {
            try await actions.acknowledge(delivery)
            guard active, generation == request else { return }
            if pending?.id == delivery.id { pending = nil }
        } catch {
            guard active, generation == request else { return }
            self.error = HomeSharingErrorPresentation.message(error)
        }
    }

    /// A failure leaves the editor and draft intact.
    func rename(_ name: String) async -> Bool {
        guard canRename else { return false }
        let request = begin(.renaming)
        defer { finish(request) }
        do {
            try await actions.rename(name)
            guard active, generation == request else { return false }
            if let old = snapshot {
                snapshot = HomeMembershipSnapshot(scope: old.scope, share: old.share,
                    homeName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    access: old.access, currentParticipantID: old.currentParticipantID,
                    members: old.members, changeTag: old.changeTag, observedAt: old.observedAt,
                    source: old.source, removals: old.removals)
            }
            return true
        } catch {
            guard active, generation == request else { return false }
            self.error = HomeSharingErrorPresentation.message(error)
            return false
        }
    }

}
