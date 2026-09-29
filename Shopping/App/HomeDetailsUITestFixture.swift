#if DEBUG
import Foundation

/// Explicit isolated UI fixtures exercise presentation only, never native membership.
@MainActor
final class HomeDetailsUITestFixture {
    static func make(scope: ActiveHomeScope, name: String,
                     rename: @escaping @MainActor (String) async throws -> Void,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> HomeDetailsActions? {
        guard let path = environment["SHOPPING_UI_TEST_STORE_PATH"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = environment["SHOPPING_UI_TEST_HOME_MEMBERS"],
              let access = HomeMembershipSnapshot.Access(rawValue: value) else { return nil }
        let fixture = HomeDetailsUITestFixture(scope: scope, name: name, access: access)
        return HomeDetailsActions(
            refresh: { fixture.snapshot },
            pending: { fixture.pending },
            invite: { _ in try fixture.invite() },
            resend: { try fixture.resend($0) },
            acknowledge: { delivery in
                guard delivery.scope == scope else { throw HomeMembershipError.scopeChanged }
                if fixture.pending?.id == delivery.id { fixture.pending = nil }
            },
            rename: { name in
                guard access != .restricted else { throw HomeMembershipError.unsupportedAccess }
                try await rename(name)
                fixture.name = name
            })
    }

    private let scope: ActiveHomeScope
    private let access: HomeMembershipSnapshot.Access
    private var name: String
    private var members: [HomeMember]
    private var pending: HomeMembershipCoordinator.Pending?
    private var invitationNumber = 0

    private init(scope: ActiveHomeScope, name: String, access: HomeMembershipSnapshot.Access) {
        self.scope = scope
        self.name = name
        self.access = access
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
            members: members, changeTag: "fixture-\(invitationNumber)", observedAt: Date(), source: .server)
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
#endif
