import Foundation

/// One app-owned coordinator serializes all membership operations for each full scope.
/// Unstructured tasks deliberately outlive cancelled UI waiters and hold their queue slot
/// until native completion; actor reentrancy never starts an overlapping scope operation.
actor HomeMembershipCoordinator {
    struct Pending: Equatable, Sendable {
        let id: UUID
        let participantID: String
        let phase: HomeInviteJournal.Phase
    }

    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var tails: [ActiveHomeScope: Tail] = [:]
    private(set) var activeRequestCount = 0

    func refresh(scope: ActiveHomeScope, journalURL: URL,
                 transport: any HomeMembershipTransport) async throws -> HomeMembershipSnapshot {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let snapshot = try await Self.refreshMembership(scope: scope, journal: journal, transport: transport)
            let intent = try journal.load(scope: scope)
            try Self.validate(snapshot, scope: scope, share: intent?.share)
            if var intent {
                let member = try Self.member(intent.material.participantID, in: snapshot)
                if member?.acceptance == .accepted || (member == nil && intent.phase == .applied) {
                    // Acceptance or observed removal completes local delivery recovery.
                    intent.phase = .applied
                    try journal.update(intent)
                    try journal.acknowledge(id: intent.id, participantID: intent.material.participantID, scope: scope)
                } else if member?.acceptance == .pending {
                    intent.phase = .applied
                    try journal.update(intent)
                }
            }
            return snapshot
        }
    }

    func invite(scope: ActiveHomeScope, journalURL: URL,
                transport: any HomeMembershipTransport) async throws -> HomeInvitationDelivery {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let saved = try journal.load(scope: scope)
            let snapshot = try await Self.refreshMembership(scope: scope, journal: journal, transport: transport)
            if let saved, try journal.isSuppressed(saved.material.participantID, scope: scope) {
                throw HomeMembershipError.invitationCancelled
            }
            let share = try Self.ownerShare(snapshot, scope: scope, share: saved?.share)
            let intent: HomeInviteJournal.Intent
            if let saved { intent = saved }
            else {
                let material = try await transport.makeInvitationParticipant(scope: scope)
                intent = try journal.begin(scope: scope, share: share, material: material, baseChangeTag: snapshot.changeTag)
            }
            return try await Self.perform(intent, observed: snapshot, journal: journal, transport: transport)
        }
    }

    func resend(participantID: String, scope: ActiveHomeScope, journalURL: URL,
                transport: any HomeMembershipTransport) async throws -> HomeInvitationDelivery {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let intent = try journal.load(scope: scope)
            let snapshot = try await Self.refreshMembership(scope: scope, journal: journal, transport: transport)
            let share = try Self.ownerShare(snapshot, scope: scope, share: intent?.share)
            guard try !journal.isSuppressed(participantID, scope: scope) else { throw HomeMembershipError.invitationCancelled }
            if let intent, intent.material.participantID == participantID {
                return try await Self.observedDelivery(intent, snapshot: snapshot, journal: journal, transport: transport)
            }
            guard let member = try Self.member(participantID, in: snapshot) else { throw HomeMembershipError.invitationUnavailable }
            guard member.acceptance != .accepted else { throw HomeMembershipError.invitationAlreadyAccepted }
            guard member.acceptance == .pending else { throw HomeMembershipError.outcomeUncertain }
            let url = try await transport.invitationURL(participantID: participantID, scope: scope, share: share)
            guard try !journal.isSuppressed(participantID, scope: scope) else { throw HomeMembershipError.invitationCancelled }
            return HomeInvitationDelivery(id: UUID(), scope: scope, participantID: participantID, url: url)
        }
    }

    func acknowledge(_ delivery: HomeInvitationDelivery, journalURL: URL) async throws {
        try await serialized(scope: delivery.scope) {
            try HomeInviteJournal(url: journalURL).acknowledge(id: delivery.id,
                participantID: delivery.participantID, scope: delivery.scope)
        }
    }

    func pending(scope: ActiveHomeScope, journalURL: URL) async throws -> Pending? {
        try await serialized(scope: scope) {
            try HomeInviteJournal(url: journalURL).load(scope: scope).map {
                Pending(id: $0.id, participantID: $0.material.participantID, phase: $0.phase)
            }
        }
    }

    func prepareRemoval(purpose: HomeMembershipRemoval.Purpose, participantID: String? = nil,
        scope: ActiveHomeScope, journalURL: URL, transport: any HomeMembershipTransport) async throws -> HomeMembershipRemovalConfirmation {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let snapshot = try await Self.refreshMembership(scope: scope, journal: journal, transport: transport)
            let share = try Self.ownerShare(snapshot, scope: scope, share: nil)
            let targets: Set<String>
            let cancelledID: UUID?
            switch purpose {
            case .cancelInvitation:
                guard let pending = try journal.load(scope: scope) else { throw HomeMembershipError.invitationUnavailable }
                guard pending.share == share else { throw HomeMembershipError.membershipChanged }
                targets = [pending.material.participantID]
                cancelledID = pending.id
            case .removeMember:
                guard let participantID, snapshot.members.contains(where: { $0.id == participantID && !$0.isCurrentUser && $0.role != .owner }) else {
                    throw HomeMembershipError.invalidParticipant
                }
                targets = [participantID]
                cancelledID = nil
            case .stopSharing:
                targets = Set(snapshot.members.filter { !$0.isCurrentUser && $0.role != .owner }.map(\.id))
                cancelledID = nil
            }
            guard !targets.isEmpty else { throw HomeMembershipError.noMembersToRemove }
            let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: share,
                ownerParticipantID: snapshot.currentParticipantID!, participantIDs: targets,
                cancelledInvitationID: cancelledID, purpose: purpose, confirmedAt: Date())
            try removal.validate()
            return HomeMembershipRemovalConfirmation(removal: removal, homeName: snapshot.homeName,
                memberNames: snapshot.members.filter { targets.contains($0.id) }.map(\.label))
        }
    }

    func confirmRemoval(_ confirmation: HomeMembershipRemovalConfirmation, scope: ActiveHomeScope,
        journalURL: URL, transport: any HomeMembershipTransport) async throws -> HomeMembershipSnapshot {
        let removal = confirmation.removal
        try removal.validate()
        guard removal.matches(scope: scope, share: removal.share) else { throw HomeMembershipError.scopeChanged }
        // Record cancellation immediately, even while an earlier native write holds
        // the mutation queue. Its late callback must never deliver this capability.
        try await transport.retainRemoval(removal, scope: scope)
        let journal = HomeInviteJournal(url: journalURL)
        try journal.importRemovals([removal], scope: scope, share: removal.share)
        return try await serialized(scope: scope) {
            try await Self.refreshMembership(scope: scope, journal: journal, transport: transport, retryRemovals: true)
        }
    }

    func retryRemovals(scope: ActiveHomeScope, journalURL: URL,
        transport: any HomeMembershipTransport) async throws -> HomeMembershipSnapshot {
        try await serialized(scope: scope) {
            try await Self.refreshMembership(scope: scope, journal: HomeInviteJournal(url: journalURL),
                transport: transport, retryRemovals: true)
        }
    }

    private func serialized<Value: Sendable>(scope: ActiveHomeScope,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }
        let previous = tails[scope]?.task
        let id = UUID()
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tails[scope] = Tail(id: id, task: Task { _ = try? await task.value })
        defer { if tails[scope]?.id == id { tails.removeValue(forKey: scope) } }
        return try await task.value
    }

    private static func perform(_ saved: HomeInviteJournal.Intent, observed: HomeMembershipSnapshot,
                                journal: HomeInviteJournal, transport: any HomeMembershipTransport) async throws -> HomeInvitationDelivery {
        guard try !journal.isSuppressed(saved.material.participantID, scope: saved.scope) else { throw HomeMembershipError.invitationCancelled }
        if try member(saved.material.participantID, in: observed) != nil || saved.phase != .prepared {
            return try await observedDelivery(saved, snapshot: observed, journal: journal, transport: transport)
        }
        var submitted = saved
        submitted.baseChangeTag = observed.changeTag
        submitted.phase = .submitted
        try journal.update(submitted)
        let result: HomeMembershipSnapshot
        do { result = try await transport.addInvitation(saved.material, expected: observed) }
        catch let notSubmitted as HomeMembershipNotSubmitted {
            submitted.phase = .prepared
            try journal.update(submitted)
            throw notSubmitted.reason
        } catch {
            // Any native callback error can follow a successful server write. An absent
            // participant in a later fetch does not authorize re-adding that participant.
            let reconciled = try await transport.refresh(scope: saved.scope)
            _ = try ownerShare(reconciled, scope: saved.scope, share: saved.share)
            return try await observedDelivery(submitted, snapshot: reconciled, journal: journal, transport: transport)
        }
        _ = try ownerShare(result, scope: saved.scope, share: saved.share)
        return try await observedDelivery(submitted, snapshot: result, journal: journal, transport: transport)
    }

    private static func observedDelivery(_ saved: HomeInviteJournal.Intent, snapshot: HomeMembershipSnapshot,
        journal: HomeInviteJournal, transport: any HomeMembershipTransport) async throws -> HomeInvitationDelivery {
        _ = try ownerShare(snapshot, scope: saved.scope, share: saved.share)
        guard let member = try member(saved.material.participantID, in: snapshot) else {
            if saved.phase == .applied {
                try journal.acknowledge(id: saved.id, participantID: saved.material.participantID, scope: saved.scope)
                throw HomeMembershipError.invitationUnavailable
            }
            throw HomeMembershipError.outcomeUncertain
        }
        guard member.acceptance == .pending || member.acceptance == .accepted else { throw HomeMembershipError.outcomeUncertain }
        var applied = saved
        applied.phase = .applied
        try journal.update(applied)
        if member.acceptance == .accepted {
            try journal.acknowledge(id: saved.id, participantID: saved.material.participantID, scope: saved.scope)
            throw HomeMembershipError.invitationAlreadyAccepted
        }
        let url = try await transport.invitationURL(participantID: saved.material.participantID,
            scope: saved.scope, share: saved.share)
        guard try !journal.isSuppressed(saved.material.participantID, scope: saved.scope) else { throw HomeMembershipError.invitationCancelled }
        return HomeInvitationDelivery(id: saved.id, scope: saved.scope, participantID: saved.material.participantID, url: url)
    }

    private static func refreshMembership(scope: ActiveHomeScope, journal: HomeInviteJournal,
        transport: any HomeMembershipTransport, retryRemovals: Bool = false) async throws -> HomeMembershipSnapshot {
        var snapshot = try await transport.refresh(scope: scope)
        try validate(snapshot, scope: scope, share: try journal.load(scope: scope)?.share)
        guard snapshot.access == .owner, let share = snapshot.share else { return snapshot }
        _ = try ownerShare(snapshot, scope: scope, share: share)
        let retained = try await transport.retainedRemovals(scope: scope, share: share)
        try journal.importRemovals(retained, scope: scope, share: share)
        try journal.observed(snapshot)
        let statuses = try journal.removals(scope: scope)
        let eligible = statuses.filter { $0.absentObservedAt == nil && (!$0.requiresRetry || retryRemovals) }
        let present = Set(snapshot.members.filter { !$0.isCurrentUser && $0.role != .owner }.map(\.id))
        let targets = eligible.reduce(into: Set<String>()) { $0.formUnion($1.removal.participantIDs) }.intersection(present)
        if !targets.isEmpty {
            try journal.markRemovalAttempt(participantIDs: targets, scope: scope)
            do {
                snapshot = try await transport.removeParticipants(targets, expected: snapshot)
                _ = try ownerShare(snapshot, scope: scope, share: share)
                try journal.observed(snapshot)
                guard targets.isDisjoint(with: snapshot.members.map(\.id)) else { throw HomeMembershipError.outcomeUncertain }
            } catch {
                let original = error
                // Lost completion may follow a successful removal. Absence is an
                // observation, not permission to discard retained cancellation data.
                let fresh = try await transport.refresh(scope: scope)
                _ = try ownerShare(fresh, scope: scope, share: share)
                try journal.observed(fresh)
                guard targets.isDisjoint(with: fresh.members.map(\.id)) else {
                    throw (original as? HomeMembershipNotSubmitted)?.reason ?? original
                }
                snapshot = fresh
            }
        }
        snapshot.removals = try journal.removals(scope: scope)
        return snapshot
    }

    private static func validate(_ snapshot: HomeMembershipSnapshot, scope: ActiveHomeScope,
                                 share: HomeShareIdentity?) throws {
        guard snapshot.scope == scope else { throw HomeMembershipError.scopeChanged }
        if let share, snapshot.share != share { throw HomeMembershipError.membershipChanged }
    }

    private static func ownerShare(_ snapshot: HomeMembershipSnapshot, scope: ActiveHomeScope,
                                   share: HomeShareIdentity?) throws -> HomeShareIdentity {
        try validate(snapshot, scope: scope, share: share)
        guard snapshot.source == .server, let actualShare = snapshot.share else { throw HomeMembershipError.shareUnavailable }
        guard snapshot.access == .owner, let currentID = snapshot.currentParticipantID,
              let current = try member(currentID, in: snapshot), current.role == .owner,
              current.isCurrentUser, current.acceptance == .accepted else { throw HomeMembershipError.ownerRequired }
        return actualShare
    }

    private static func member(_ id: String, in snapshot: HomeMembershipSnapshot) throws -> HomeMember? {
        let members = snapshot.members.filter { $0.id == id }
        guard members.count <= 1 else { throw HomeMembershipError.invalidParticipant }
        return members.first
    }
}
