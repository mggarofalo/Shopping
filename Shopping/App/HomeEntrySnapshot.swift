import Foundation

/// A value-only boundary for home entry screens. It carries identities and display
/// facts, never managed objects or archived invitation capabilities.
struct HomeEntrySnapshot: Equatable {
    enum Store: Equatable {
        case opening
        case failed
        case local(hasHome: Bool)
        case account
    }

    enum Root: Equatable {
        case opening
        case failed
        case localHome
        case accountUnavailable
        case waitingForHomes
        case noHomes
        case chooseHome
        case selectedHomeUnavailable
        case activeHome(ActiveHomeScope)
    }

    struct Home: Identifiable, Equatable {
        let candidate: HomeCandidate
        let isSelected: Bool

        var id: HomeGraphIdentity { candidate.graph }
        var name: String { candidate.name }
        var access: HomeCandidate.Access { candidate.access }
    }

    struct Invitation: Identifiable, Equatable {
        let id: UUID
        let identity: HomeInvitationIdentity
        let accountBinding: String?
        let state: HomeInvitationInbox.State
        let acceptanceAttempted: Bool
        let participantPending: Bool
        let dismissalRequested: Bool

        init(_ entry: HomeInvitationInbox.Entry) {
            id = entry.id
            identity = entry.identity
            accountBinding = entry.session?.accountBinding
            state = entry.state
            acceptanceAttempted = entry.acceptanceAttempted
            participantPending = entry.participantPending
            dismissalRequested = entry.dismissalRequested
        }
    }

    let root: Root
    let homes: [Home]
    let currentHomeName: String?
    let retainedLocalHomeName: String?
    let isShowingRetainedLocalHome: Bool
    let invitations: [Invitation]
    let hasPendingInvitation: Bool
    let hasVerifiedInvitationAccount: Bool
    let invitationProblem: String?
    let importProblems: [UUID: String]
    let isCreatingHome: Bool
    let homeDiscoveryFailed: Bool

    init(store: Store, readiness: ActiveHomeCoordinator.Readiness,
         discovery: ActiveHomeCoordinator.DiscoveryState, homes: [HomeCandidate],
         currentHomeName: String?, retainedLocalHomeName: String?, isShowingRetainedLocalHome: Bool,
         invitations: [HomeInvitationInbox.Entry], hasPendingInvitation: Bool,
         hasVerifiedInvitationAccount: Bool, invitationProblem: String?, importProblems: [UUID: String],
         isCreatingHome: Bool, homeDiscoveryFailed: Bool) {
        let active = readiness.activeScope
        self.homes = homes.map { Home(candidate: $0, isSelected: $0.graph == active?.graph) }
        self.currentHomeName = currentHomeName
        self.retainedLocalHomeName = retainedLocalHomeName
        self.isShowingRetainedLocalHome = isShowingRetainedLocalHome
        self.invitations = invitations.map(Invitation.init)
        self.hasPendingInvitation = hasPendingInvitation
        self.hasVerifiedInvitationAccount = hasVerifiedInvitationAccount
        self.invitationProblem = invitationProblem
        self.importProblems = importProblems.filter { id, _ in invitations.contains { $0.id == id } }
        self.isCreatingHome = isCreatingHome
        self.homeDiscoveryFailed = homeDiscoveryFailed

        switch store {
        case .opening: root = .opening
        case .failed: root = .failed
        case .local(let hasHome): root = hasHome ? .localHome : .noHomes
        case .account:
            switch readiness {
            case .accountUnavailable: root = .accountUnavailable
            case .selectedHomeUnavailable: root = .selectedHomeUnavailable
            case .ready(let scope): root = .activeHome(scope)
            case .choiceRequired: root = .chooseHome
            case .waitingForImport:
                if homeDiscoveryFailed || discovery != .complete || hasPendingInvitation {
                    root = .waitingForHomes
                } else { root = homes.isEmpty ? .noHomes : .chooseHome }
            }
        }
    }
}

private extension ActiveHomeCoordinator.Readiness {
    var activeScope: ActiveHomeScope? {
        if case .ready(let scope) = self { return scope }
        return nil
    }
}
