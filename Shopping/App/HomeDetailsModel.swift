import Foundation
import SwiftUI

@MainActor
struct HomeDetailsActions {
    let refresh: () async throws -> HomeMembershipSnapshot
    let pending: () async throws -> HomeMembershipCoordinator.Pending?
    let invite: (_ retryPreparation: Bool) async throws -> HomeInvitationDelivery
    let resend: (String) async throws -> HomeInvitationDelivery
    let acknowledge: (HomeInvitationDelivery) async throws -> Void
    let rename: (String) async throws -> Void
    var removals: HomeDetailsRemovalActions? = nil
    var leave: HomeDetailsLeaveActions? = nil
}

@MainActor
struct HomeDetailsRemovalActions {
    let prepare: (HomeMembershipRemoval.Purpose, String?) async throws -> HomeMembershipRemovalConfirmation
    let confirm: (HomeMembershipRemovalConfirmation) async throws -> HomeMembershipSnapshot
    let retry: () async throws -> HomeMembershipSnapshot
}

@MainActor
struct HomeDetailsLeaveActions {
    let prepare: () async throws -> HomeLeaveCommand
    let confirm: (HomeLeaveCommand) async throws -> HomeLeaveStatus
}

/// UI state contains values only. Every action revalidates the captured home before
/// execution; a retired presentation cannot publish a link into its replacement.
@MainActor
final class HomeDetailsModel: ObservableObject {
    let scope: ActiveHomeScope
    private let actions: HomeDetailsActions
    @Published private(set) var snapshot: HomeMembershipSnapshot?
    @Published private(set) var pending: HomeMembershipCoordinator.Pending?
    @Published private(set) var busy = false
    @Published private(set) var isCurrent = false
    @Published private(set) var error: String?
    @Published private(set) var needsPreparationRetry = false
    @Published var delivery: HomeInvitationDelivery?
    @Published var removalConfirmation: HomeMembershipRemovalConfirmation?
    @Published var leaveConfirmation: HomeLeaveCommand?
    @Published private(set) var leaveStatus: HomeLeaveStatus?
    private var generation = 0
    private var active = true

    init(scope: ActiveHomeScope, actions: HomeDetailsActions) {
        self.scope = scope
        self.actions = actions
    }

    var canInvite: Bool { active && isCurrent && !busy && snapshot?.canInvite == true }
    var canRename: Bool { active && isCurrent && !busy && snapshot?.canEditName == true }
    var canManageMembers: Bool { canInvite && snapshot?.source == .server && actions.removals != nil }

    var canLeave: Bool {
        active && isCurrent && !busy && actions.leave != nil && leaveStatus == nil && acceptedParticipant != nil
    }

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
        busy = false
        delivery = nil
        removalConfirmation = nil
        leaveConfirmation = nil
    }

    func refresh() async {
        guard active, !busy else { return }
        generation += 1
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            let result = try await actions.refresh()
            let pending = try await actions.pending()
            guard active, generation == request else { return }
            guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
            snapshot = result
            self.pending = pending
            isCurrent = true
            error = nil
        } catch {
            guard active, generation == request else { return }
            isCurrent = false
            self.error = Self.message(error)
        }
    }

    func invite(retryPreparation: Bool = false) async {
        guard canInvite else { return }
        await deliver { try await self.actions.invite(retryPreparation) }
    }

    func resend(_ participantID: String) async {
        guard canInvite else { return }
        await deliver { try await self.actions.resend(participantID) }
    }

    func prepareLeave() async {
        guard canLeave, let actions = actions.leave else { return }
        generation += 1
        let request = generation
        busy = true
        leaveConfirmation = nil
        defer { if request == generation { busy = false } }
        do {
            let command = try await actions.prepare()
            guard active, generation == request else { return }
            try command.validate()
            guard matchesLeave(command) else { throw HomeMembershipError.scopeChanged }
            leaveConfirmation = command
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = Self.message(error)
        }
    }

    func confirmLeave(_ command: HomeLeaveCommand) async {
        guard canLeave, leaveConfirmation == command, matchesLeave(command),
              let actions = actions.leave else { return }
        // Consume this exact confirmation before the first suspension. A repeated
        // tap cannot submit it again, even if its native outcome is uncertain.
        leaveConfirmation = nil
        generation += 1
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            let status = try await actions.confirm(command)
            guard active, generation == request else { return }
            guard status.command == command, matchesLeave(command) else { throw HomeMembershipError.scopeChanged }
            leaveStatus = status
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = Self.message(error)
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
        generation += 1
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
        do {
            let confirmation = try await actions.prepare(purpose, participantID)
            guard active, generation == request else { return }
            guard confirmation.removal.origin == scope else { throw HomeMembershipError.scopeChanged }
            removalConfirmation = confirmation
            error = nil
        } catch {
            guard active, generation == request else { return }
            self.error = Self.message(error)
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
        generation += 1
        let request = generation
        busy = true
        defer { if request == generation { busy = false } }
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
            self.error = Self.message(error)
            // The durable intent may already exist even if iCloud did not finish.
            // Refresh exposes that retained state without repeating its mutation.
            do {
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

    private func deliver(_ operation: () async throws -> HomeInvitationDelivery) async {
        generation += 1
        let request = generation
        busy = true
        error = nil
        needsPreparationRetry = false
        do {
            let result = try await operation()
            guard active, generation == request else { return }
            guard result.scope == scope else { throw HomeMembershipError.scopeChanged }
            delivery = result
        } catch {
            guard active, generation == request else { return }
            self.error = Self.message(error)
            if case HomeSharingError.retryRequired = error { needsPreparationRetry = true }
        }
        guard active, generation == request else { return }
        busy = false
        // Do not clear a delivery or its operation error if this follow-up read fails.
        do {
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
            if self.error == nil { self.error = Self.message(error) }
        }
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
            self.error = Self.message(error)
        }
    }

    /// A failure leaves the editor and draft intact.
    func rename(_ name: String) async -> Bool {
        guard canRename else { return false }
        generation += 1
        let request = generation
        busy = true
        do {
            try await actions.rename(name)
            guard active, generation == request else { return false }
            busy = false
            await refresh()
            return true
        } catch {
            guard active, generation == request else { return false }
            busy = false
            self.error = Self.message(error)
            return false
        }
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? HomeMembershipError { return error.localizedDescription }
        if let error = error as? HomeSharingError { return error.localizedDescription }
        if let error = error as? ManagedHomeLeaveTransport.Failure { return error.localizedDescription }
        return "Couldn’t verify this home with iCloud. Your groceries and invitation have been retained. Check again when you’re connected."
    }
}
