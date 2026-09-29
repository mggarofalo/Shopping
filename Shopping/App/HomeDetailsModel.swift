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
    private var generation = 0
    private var active = true

    init(scope: ActiveHomeScope, actions: HomeDetailsActions) {
        self.scope = scope
        self.actions = actions
    }

    var canInvite: Bool { active && isCurrent && !busy && snapshot?.canInvite == true }
    var canRename: Bool { active && isCurrent && !busy && snapshot?.canEditName == true }

    func activate() { active = true }
    func retire() {
        active = false
        generation += 1
        isCurrent = false
        busy = false
        delivery = nil
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
        return "Couldn’t verify this home with iCloud. Your groceries and invitation have been retained. Check again when you’re connected."
    }
}
