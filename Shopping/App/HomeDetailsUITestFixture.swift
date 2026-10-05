#if DEBUG
import Foundation

/// Explicit isolated UI fixtures exercise presentation only, never native membership.
@MainActor
final class HomeDetailsUITestFixture {
    static func make(scope: ActiveHomeScope, name: String,
                     rename: @escaping @MainActor (String) async throws -> Void,
                     leaveOverride: HomeDetailsLeaveActions? = nil,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> HomeDetailsActions? {
        guard let path = environment["SHOPPING_UI_TEST_STORE_PATH"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = environment["SHOPPING_UI_TEST_HOME_MEMBERS"],
              let access = HomeMembershipSnapshot.Access(rawValue: value) else { return nil }
        let fixture = HomeDetailsUITestFixture(scope: scope, name: name, access: access,
            storeURL: URL(fileURLWithPath: path))
        return HomeDetailsActions(
            refresh: {
                if environment["SHOPPING_UI_TEST_HOME_REFRESH_DELAY"] == "1" {
                    try await Task.sleep(for: .seconds(10))
                }
                return fixture.snapshot
            },
            pending: { fixture.pending },
            invite: { _ in
                if environment["SHOPPING_UI_TEST_HOME_INVITE_FAILURE"] == "1" {
                    throw HomeShareGraphValidator.Failure.ambiguousIdentity
                }
                return try fixture.invite()
            },
            resend: { try fixture.resend($0) },
            acknowledge: { delivery in
                guard delivery.scope == scope else { throw HomeMembershipError.scopeChanged }
                if fixture.pending?.id == delivery.id { fixture.pending = nil }
            },
            rename: { name in
                guard access != .restricted else { throw HomeMembershipError.unsupportedAccess }
                try await rename(name)
                fixture.name = name
            }, removals: HomeDetailsRemovalActions(
                prepare: { try fixture.prepareRemoval($0, participantID: $1) },
                confirm: { try fixture.confirmRemoval($0) }, retry: { fixture.snapshot }),
                leave: leaveOverride ?? HomeDetailsLeaveActions(prepare: { try fixture.prepareLeave() },
                    confirm: { try fixture.confirmLeave($0) }))
    }

    private let scope: ActiveHomeScope
    private let access: HomeMembershipSnapshot.Access
    private let storeURL: URL
    private var preparedLeave: HomeLeaveCommand?
    private var name: String
    private var members: [HomeMember]
    private var pending: HomeMembershipCoordinator.Pending?
    private var invitationNumber = 0
    private var removals: [HomeMembershipRemovalStatus] = []

    private init(scope: ActiveHomeScope, name: String, access: HomeMembershipSnapshot.Access, storeURL: URL) {
        self.scope = scope
        self.name = name
        self.access = access
        self.storeURL = storeURL
        var members = [HomeMember(id: "fixture-owner", name: "Morgan", role: .owner,
            acceptance: .accepted, isCurrentUser: access == .owner, canResend: false)]
        if access != .owner {
            members.append(HomeMember(id: "fixture-current", name: "Taylor",
                role: access == .restricted ? .restricted : .contributor,
                acceptance: .accepted, isCurrentUser: true, canResend: false))
        }
        members.append(HomeMember(id: "fixture-long-name",
            name: "Alexandra Penelope Montgomery-Wellington", role: .contributor,
            acceptance: .accepted, isCurrentUser: false, canResend: false))
        self.members = members
    }

    private var snapshot: HomeMembershipSnapshot {
        HomeMembershipSnapshot(scope: scope,
            share: HomeShareIdentity(recordName: "fixture-share", zoneName: "fixture-zone", zoneOwnerName: "fixture-owner"),
            homeName: name, access: access,
            currentParticipantID: access == .owner ? "fixture-owner" : "fixture-current",
            members: members, changeTag: "fixture-\(invitationNumber)", observedAt: Date(), source: .server, removals: removals)
    }

    private func prepareLeave() throws -> HomeLeaveCommand {
        guard access != .owner else { throw HomeMembershipError.unsupportedAccess }
        let command = HomeLeaveCommand(id: UUID(), origin: HomeNativeAccessIdentity(
            scope: HomeEffectScope(fixtureScope: scope), storeIdentifier: scope.graph.storeIdentifier,
            rootURI: scope.graph.rootURI,
            share: HomeEffectShare(recordName: "fixture-share", zoneName: "fixture-zone", zoneOwnerName: "fixture-owner")),
            storeURL: storeURL, participantID: "fixture-current", homeName: name,
            evidence: HomeLeaveEvidence(checkoutIDs: [], restoreIDs: [], unresolvedRestoreIDs: [], cartGenerations: []),
            confirmedAt: Date())
        try command.validate()
        preparedLeave = command
        return command
    }

    private func confirmLeave(_ command: HomeLeaveCommand) throws -> HomeLeaveStatus {
        guard access != .owner, preparedLeave == command else { throw HomeMembershipError.scopeChanged }
        preparedLeave = nil
        // Presentation-only simulation: no ledger write, membership mutation, or
        // native purge occurs, and this fixture never claims leave completion.
        return HomeLeaveStatus(command: command, submitted: true, completed: false)
    }

    private func prepareRemoval(_ purpose: HomeMembershipRemoval.Purpose,
                                participantID: String?) throws -> HomeMembershipRemovalConfirmation {
        guard access == .owner else { throw HomeMembershipError.ownerRequired }
        let ids: Set<String>
        switch purpose {
        case .cancelInvitation:
            guard let pending else { throw HomeMembershipError.invitationUnavailable }
            ids = [pending.participantID]
        case .removeMember:
            guard let participantID, members.contains(where: { $0.id == participantID && !$0.isCurrentUser && $0.role != .owner }) else {
                throw HomeMembershipError.invalidParticipant
            }
            ids = [participantID]
        case .stopSharing: ids = Set(members.filter { !$0.isCurrentUser && $0.role != .owner }.map(\.id))
        }
        let removal = HomeMembershipRemoval(id: UUID(), origin: scope, share: snapshot.share!,
            ownerParticipantID: "fixture-owner", participantIDs: ids,
            cancelledInvitationID: purpose == .cancelInvitation ? pending?.id : nil, purpose: purpose, confirmedAt: Date())
        try removal.validate()
        return HomeMembershipRemovalConfirmation(removal: removal, homeName: name,
            memberNames: members.filter { ids.contains($0.id) }.map(\.label))
    }

    private func confirmRemoval(_ confirmation: HomeMembershipRemovalConfirmation) throws -> HomeMembershipSnapshot {
        guard access == .owner, confirmation.removal.origin == scope else { throw HomeMembershipError.scopeChanged }
        try confirmation.removal.validate()
        members.removeAll { confirmation.removal.participantIDs.contains($0.id) }
        if let pending, confirmation.removal.participantIDs.contains(pending.participantID) { self.pending = nil }
        removals.append(HomeMembershipRemovalStatus(removal: confirmation.removal, absentObservedAt: Date()))
        return snapshot
    }

    private func invite() throws -> HomeInvitationDelivery {
        guard access == .owner else { throw HomeMembershipError.ownerRequired }
        if let pending { return delivery(id: pending.id, participantID: pending.participantID) }
        invitationNumber += 1
        let participantID = "fixture-invitation-\(invitationNumber)"
        let id = UUID()
        members.append(HomeMember(id: participantID, name: nil, role: .contributor,
            acceptance: .pending, isCurrentUser: false, canResend: true))
        pending = HomeMembershipCoordinator.Pending(id: id, participantID: participantID, phase: .applied)
        return delivery(id: id, participantID: participantID)
    }

    private func resend(_ participantID: String) throws -> HomeInvitationDelivery {
        guard access == .owner else { throw HomeMembershipError.ownerRequired }
        guard members.contains(where: { $0.id == participantID && $0.acceptance == .pending }) else {
            throw HomeMembershipError.invitationUnavailable
        }
        let id = pending.flatMap { $0.participantID == participantID ? $0.id : nil } ?? UUID()
        return delivery(id: id, participantID: participantID)
    }

    private func delivery(id: UUID, participantID: String) -> HomeInvitationDelivery {
        HomeInvitationDelivery(id: id, scope: scope, participantID: participantID,
            url: URL(string: "https://example.invalid/invitation/\(participantID)")!)
    }
}
// This copies a presentation identity only; it does not create account authority.
private extension HomeEffectScope {
    init(fixtureScope: ActiveHomeScope) {
        accountBinding = fixtureScope.accountBinding
        containerIdentifier = fixtureScope.containerIdentifier
        environment = fixtureScope.environment
        householdID = fixtureScope.graph.householdID
        listID = fixtureScope.graph.listID
    }
}
#endif
