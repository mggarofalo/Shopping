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

    func refresh(scope: ActiveHomeScope, journalURL: URL,
                 transport: any HomeMembershipTransport) async throws -> HomeMembershipSnapshot {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let intent = try journal.load(scope: scope)
            let snapshot = try await transport.refresh(scope: scope)
            try Self.validate(snapshot, scope: scope, share: intent?.share)
            if var intent, let member = try Self.member(intent.material.participantID, in: snapshot),
               member.acceptance == .pending || member.acceptance == .accepted {
                intent.phase = .applied
                try journal.update(intent)
            }
            return snapshot
        }
    }

    func invite(scope: ActiveHomeScope, journalURL: URL,
                transport: any HomeMembershipTransport) async throws -> HomeInvitationDelivery {
        try await serialized(scope: scope) {
            let journal = HomeInviteJournal(url: journalURL)
            let saved = try journal.load(scope: scope)
            let snapshot = try await transport.refresh(scope: scope)
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
            let snapshot = try await transport.refresh(scope: scope)
            let share = try Self.ownerShare(snapshot, scope: scope, share: intent?.share)
            if let intent, intent.material.participantID == participantID {
                return try await Self.observedDelivery(intent, snapshot: snapshot, journal: journal, transport: transport)
            }
            guard let member = try Self.member(participantID, in: snapshot) else { throw HomeMembershipError.invitationUnavailable }
            guard member.acceptance != .accepted else { throw HomeMembershipError.invitationAlreadyAccepted }
            guard member.acceptance == .pending else { throw HomeMembershipError.outcomeUncertain }
            let url = try await transport.invitationURL(participantID: participantID, scope: scope, share: share)
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

    private func serialized<Value: Sendable>(scope: ActiveHomeScope,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
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
        return HomeInvitationDelivery(id: saved.id, scope: saved.scope, participantID: saved.material.participantID, url: url)
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
