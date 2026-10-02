import Foundation

/// A value-only boundary for home entry screens. It carries identities and display
/// facts, never managed objects or archived invitation capabilities.
struct HomeEntrySnapshot: Equatable {
    enum Store: Equatable {
        case opening
        case failed
        case local(hasHome: Bool, discoveryComplete: Bool)
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
        let presentation: HomePresentationName

        var id: HomeGraphIdentity { candidate.graph }
        var name: String { candidate.name }
        var access: HomeCandidate.Access { candidate.access }
    }

    struct Invitation: Identifiable, Equatable {
        let id: UUID
        let identity: HomeInvitationIdentity
        let displayName: String?
        let accountBinding: String?
        let state: HomeInvitationInbox.State
        let acceptanceAttempted: Bool
        let participantPending: Bool
        let dismissalRequested: Bool
        let openRequested: Bool

        init(_ entry: HomeInvitationInbox.Entry) {
            id = entry.id
            identity = entry.identity
            displayName = entry.displayName
            accountBinding = entry.session?.accountBinding
            state = entry.state
            acceptanceAttempted = entry.acceptanceAttempted
            participantPending = entry.participantPending
            dismissalRequested = entry.dismissalRequested
            openRequested = entry.openRequested
        }
    }

    enum JoinPresentation: Equatable {
        case none
        case active(Invitation)
        case deferred(Invitation)
    }

    enum RetainedLocalCopyState: Equatable {
        case unavailable
        case available
        case copying
        case copied
    }

    let root: Root
    let isLocalStore: Bool
    let homes: [Home]
    let currentHomeName: String?
    let retainedLocalHomeName: String?
    let retainedLocalPresentation: HomePresentationName?
    let isShowingRetainedLocalHome: Bool
    let retainedLocalCopyState: RetainedLocalCopyState
    let invitations: [Invitation]
    let hasPendingInvitation: Bool
    let hasVerifiedInvitationAccount: Bool
    let invitationProblem: String?
    let joinError: String?
    let importProblems: [UUID: String]
    let isCreatingHome: Bool
    let isResolvingFirstAccount: Bool
    let homeDiscoveryFailed: Bool

    var currentHomeDisplayName: String? {
        if isShowingRetainedLocalHome { return retainedLocalPresentation?.title ?? retainedLocalHomeName }
        return homes.first(where: \.isSelected)?.presentation.title ?? currentHomeName
    }

    var joinPresentation: JoinPresentation {
        if let invitation = invitations.first(where: { $0.openRequested }) { return .active(invitation) }
        if let invitation = invitations.first(where: {
            if case .ready = $0.state { return true }
            return false
        }) { return .deferred(invitation) }
        return .none
    }

    init(store: Store, readiness: ActiveHomeCoordinator.Readiness,
         discovery: ActiveHomeCoordinator.DiscoveryState, homes: [HomeCandidate],
         currentHomeName: String?, retainedLocalHomeName: String?, isShowingRetainedLocalHome: Bool,
         retainedLocalCopyState: RetainedLocalCopyState = .unavailable,
         invitations: [HomeInvitationInbox.Entry], hasPendingInvitation: Bool,
         hasVerifiedInvitationAccount: Bool, invitationProblem: String?, importProblems: [UUID: String],
         isCreatingHome: Bool, homeDiscoveryFailed: Bool,
         isResolvingFirstAccount: Bool = false, joinError: String? = nil,
         retainedLocalScope: PersonalCartScopeSnapshot? = nil) {
        let active = readiness.activeScope
        if case .local = store { isLocalStore = true }
        else { isLocalStore = false }
        var sources = homes.map {
            HomePresentationSource(scope: PersonalCartScopeSnapshot(householdID: $0.graph.householdID,
                listID: $0.graph.listID), name: $0.name, role: Self.presentationRole($0.access))
        }
        if let retainedLocalScope, let retainedLocalHomeName {
            sources.append(HomePresentationSource(scope: retainedLocalScope,
                name: retainedLocalHomeName, role: .local))
        }
        let presentations = HomePresentationNames.resolve(sources)
        self.homes = homes.map {
            let scope = PersonalCartScopeSnapshot(householdID: $0.graph.householdID, listID: $0.graph.listID)
            return Home(candidate: $0, isSelected: $0.graph == active?.graph,
                presentation: presentations[scope] ?? HomePresentationName(name: $0.name, context: nil))
        }
        self.currentHomeName = currentHomeName
        self.retainedLocalHomeName = retainedLocalHomeName
        self.retainedLocalPresentation = retainedLocalScope.flatMap { presentations[$0] }
        self.isShowingRetainedLocalHome = isShowingRetainedLocalHome
        self.retainedLocalCopyState = retainedLocalCopyState
        self.invitations = invitations.map(Invitation.init)
        self.hasPendingInvitation = hasPendingInvitation
        self.hasVerifiedInvitationAccount = hasVerifiedInvitationAccount
        self.invitationProblem = invitationProblem
        self.joinError = joinError
        self.importProblems = importProblems.filter { id, _ in invitations.contains { $0.id == id } }
        self.isCreatingHome = isCreatingHome
        self.isResolvingFirstAccount = isResolvingFirstAccount
        self.homeDiscoveryFailed = homeDiscoveryFailed

        switch store {
        case .opening: root = .opening
        case .failed: root = .failed
        case .local(let hasHome, let discoveryComplete):
            root = hasHome ? .localHome : (discoveryComplete && !isResolvingFirstAccount
                ? .noHomes : .waitingForHomes)
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

    private static func presentationRole(_ access: HomeCandidate.Access) -> HomePresentationSource.Role {
        switch access {
        case .owner: .owner
        case .contributor: .member
        case .restricted: .readOnly
        case .unresolved: .unknown
        }
    }
}

private extension ActiveHomeCoordinator.Readiness {
    var activeScope: ActiveHomeScope? {
        if case .ready(let scope) = self { return scope }
        return nil
    }
}
