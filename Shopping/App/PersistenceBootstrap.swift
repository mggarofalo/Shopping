import Combine
import CoreData
import CryptoKit
import Foundation
import SwiftUI

struct PersistenceSelection: Equatable, Sendable {
    let householdID: UUID?
    let listID: UUID?
    var homeScope: ActiveHomeScope? = nil
}

struct SharingStatusPresentation: Equatable {
    let symbol: String
    let title: String
    let details: String
}

private struct SharingStatusPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue = SharingStatusPresentation(
        symbol: "internaldrive", title: "Saved on this device",
        details: "Saved on this device. iCloud setup has not been completed."
    )
}

private struct SharingStatusEnvironmentKey: EnvironmentKey {
    static let defaultValue = "Saved on this device. iCloud setup has not been completed."
}

private struct PersistencePresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: PersistenceBootstrap.Presentation? = nil
}

private struct NeedServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: NeedService? = nil
}

private struct PersistenceSelectionEnvironmentKey: EnvironmentKey {
    static let defaultValue = PersistenceSelection(householdID: nil, listID: nil)
}

extension EnvironmentValues {
    var sharingStatusPresentation: SharingStatusPresentation {
        get { self[SharingStatusPresentationEnvironmentKey.self] }
        set { self[SharingStatusPresentationEnvironmentKey.self] = newValue }
    }
    var sharingStatusDescription: String {
        get { self[SharingStatusEnvironmentKey.self] }
        set { self[SharingStatusEnvironmentKey.self] = newValue }
    }
    var persistencePresentation: PersistenceBootstrap.Presentation? {
        get { self[PersistencePresentationEnvironmentKey.self] }
        set { self[PersistencePresentationEnvironmentKey.self] = newValue }
    }
    var needService: NeedService? {
        get { self[NeedServiceEnvironmentKey.self] }
        set { self[NeedServiceEnvironmentKey.self] = newValue }
    }

    var persistenceSelection: PersistenceSelection {
        get { self[PersistenceSelectionEnvironmentKey.self] }
        set { self[PersistenceSelectionEnvironmentKey.self] = newValue }
    }
}

@MainActor
final class PersistenceBootstrap: ObservableObject {
    private struct PreparedStore: @unchecked Sendable {
        let configuration: PersistenceConfiguration
        let persistence: PersistenceController
        let service: NeedService
        let selection: (householdID: UUID, listID: UUID)?
        let personalCartService: PersonalCartService?
        let resumeError: String?
        let homeDiscovery: HomeDiscovery
    }
    private struct RetiringStore: @unchecked Sendable {
        let persistence: PersistenceController
    }
    private static let performanceFixtureVersion = 2
    private static let retainedUITestStoreLimit = 12
    private static let retainedUITestHistoryTokenLimit = 24

    final class Presentation {
        let id = UUID()
        let commandAuthority = UICommandAuthority()
        var isActive: Bool { commandAuthority.isActive }
        func retire() { commandAuthority.retire() }
    }

    @MainActor struct ReadyState {
        let presentation = Presentation()
        let persistence: PersistenceController
        let service: NeedService
        let householdID: UUID?
        let listID: UUID?
        var homeScope: ActiveHomeScope? = nil
        var homeGeneration: UInt64 = 0
        var personalCart: PersonalCartPresentation? = nil
        var personalCartService: PersonalCartService? = nil

        init(persistence: PersistenceController, service: NeedService, householdID: UUID?, listID: UUID?,
             homeScope: ActiveHomeScope? = nil, homeGeneration: UInt64 = 0,
             personalCartService: PersonalCartService? = nil) {
            self.persistence = persistence
            self.service = service.scoped(to: presentation.commandAuthority)
            self.householdID = householdID
            self.listID = listID
            self.homeScope = homeScope
            self.homeGeneration = homeGeneration
            self.personalCartService = personalCartService?.scoped(to: presentation.commandAuthority)
            if let service = self.personalCartService, let householdID, let listID {
                personalCart = PersonalCartPresentation(service: service, householdID: householdID, listID: listID)
            }
        }
    }

    enum State {
        case loading
        case ready(ReadyState)
        case failed(Error)
    }

    private struct Transition {
        let id = UUID()
        let previous: ReadyState?
        let action: () -> Void
    }

    private enum AccountPresentationChange {
        case unchanged
        case reopen
        case unavailable(Error)
    }

    @Published private(set) var loadingTransitionID: UUID?
    @Published private(set) var cloudStatus = CloudSyncStatus()
    private let cloudMonitor = CloudSyncEventMonitor()
    private var transition: Transition?
    private var mountedPresentations: Set<UUID> = []
    private let defaults: UserDefaults
    let homeCoordinator: ActiveHomeCoordinator
    let invitations: HomeInvitationController?
    let editorDrafts: HomeEditorDraftStore
    private let homeShareProvisioner = HomeShareProvisioner()
    private let homeMembershipCoordinator = HomeMembershipCoordinator()
#if DEBUG
    private var homeDetailsFixtures: [ActiveHomeScope: HomeDetailsActions] = [:]
#endif
    private let makeAccountProvider: ((URL) throws -> ShopperSessionProvider)?
    private let accountStoreDirectory: (() throws -> URL)?
    private let participantStoreForHomeChoice: (PersistenceController) -> NSPersistentStore?
    private let invitationShareIdentity: @MainActor @Sendable (PersistenceController, ShopperSession, HomeGraphIdentity) async throws -> HomeShareIdentity?
    private let makeHomeLeaveTransport: @Sendable (PersonalCartService) -> ManagedHomeLeaveTransport
    @Published private(set) var homeLeaveStatuses: [HomeLeaveStatus] = []
    @Published private(set) var homeLeaveStatusError: String?
    @Published private(set) var isCheckingHomeLeaves = false
    @Published private(set) var homeLeaveResumingID: UUID?
    @Published private(set) var homeDeletionStatuses: [HomeDeletionStatus] = []
    @Published private(set) var homeDeletionStatusError: String?
    @Published private(set) var isDeletingHome = false
    private var homeDeletionRefreshID: UUID?
    private var homeLeaveRefreshID: UUID?
    private let makeHomeRejoinVerifier: @Sendable (PersonalCartService) -> any HomeRejoinVerifying
    private var invitationActivations: [UUID: (entry: HomeInvitationInbox.Entry, authority: UICommandAuthority, presentationID: UUID)] = [:]
    private(set) var autoOpeningInvitationID: UUID?
    private var autoOpenFailures: Set<UUID> = []
    private var autoConnectionAttemptedFor: Set<UUID> = []
    private var automaticJoinConnectionTasks: [UUID: Task<Void, Never>] = [:]
    private var joiningPresentationID: UUID?
    private struct LocalJoinOrigin: Equatable {
        let invitationID: UUID
        let storeIdentifier: String
        let householdID: UUID
        let listID: UUID
    }
    private var localJoinOrigin: LocalJoinOrigin?
    private var localReturnAfterDismiss: LocalJoinOrigin?
    @Published private(set) var joinError: String?
    private var invitationDiscoveryReservations: [UUID: UUID] = [:]
    private let activateAccountStore: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration
    @Published private(set) var state: State = .loading
    @Published private(set) var pendingShareAssociationCount = 0
    @Published private(set) var isCreatingHome = false
    @Published private(set) var shareAssociationError: Error?
    @Published private(set) var homeSetupError: Error?
    @Published private(set) var cartResumeError: Error?
    @Published private(set) var homeDiscoveryError: Error?
    @Published private(set) var isCheckingSharingStatus = false
    @Published private(set) var sharingStatusCheckMessage: String?
    private enum SharingCheckProblem {
        case failed, timedOut, alreadyRunning
        var message: String {
            switch self {
            case .failed: return "Couldn’t check status. Try again."
            case .timedOut: return "The check took too long. Try again."
            case .alreadyRunning: return "The previous check is still finishing. Try again shortly."
            }
        }
    }
    @Published private var sharingCheckProblem: SharingCheckProblem?
    var sharingStatusCheckProblem: String? { sharingCheckProblem?.message }
    @Published private var sharingWork: HomeSharingWorkSnapshot?
    @Published private var sharingWorkNeedsAttention = false
    private var sharingWorkScope: ActiveHomeScope?
    private var sharingWorkPresentationID: UUID?
    private var sharingCheckID: UUID?
    private let sharingCheck: HomeSharingStatusCheck<HomeSharingWorkSnapshot?>
    private let readSharingWork: @Sendable (PersonalCartService, ActiveHomeScope) async throws -> HomeSharingWorkSnapshot
    private let discoverHomes: @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery
    private var homeObservation: AnyCancellable?
    private var invitationObservation: AnyCancellable?
    private var associationCountKnown = false
    private let configuration: () throws -> PersistenceConfiguration
    private var preloadedPreviewEnvironment: ShoppingPreviewEnvironment?
    private var remoteObserver: NSObjectProtocol?
    private var associationObserver: NSObjectProtocol?
    private var historyConsumer: PersistentHistoryConsumer?
    private var associationWorker: ManagedShareAssociationWorker?
    private var generation = 0
    private var personalMode = false
    private var accountProvider: ShopperSessionProvider?
    private var accountObserver: NSObjectProtocol?
    private var personalConfiguration: PersistenceConfiguration?
    private var activeAccountBinding: String?
    private var accountLoadInProgress = false
    private var pendingRetirement: ReadyState?
    private var personalService: PersonalCartService?
    private var homeAccessRefreshID: UUID?
    private var deviceLocalHome: DeviceLocalHome?
    private var retainedLocalConfiguration: PersistenceConfiguration?
    private var localHomeName: String?
    private var localDiscoveryComplete = false
    @Published private(set) var isResolvingFirstAccount = false
    private let autoResolveFreshAccount: Bool
    private let autoJoinInvitations: Bool
    private var restoringLocalRoute = false
    private var preferredAdoptedHome: (householdID: UUID, listID: UUID)?
    @Published private(set) var retainedLocalHomeName: String?
    @Published private(set) var isShowingRetainedLocalHome = false
    @Published private(set) var retainedLocalCopyState: HomeEntrySnapshot.RetainedLocalCopyState = .unavailable
    private var retainedConversionSelectionIntent: UUID?
    private var retainedConversionChoiceGeneration: UInt64?
    private var retainedConversionResumingID: UUID?

    struct InvitationSetupChoice {
        fileprivate let proposal: HomeAdoptionJournal.Proposal
        fileprivate let presentationID: UUID?
        fileprivate let generation: Int
        var currentHomeName: String? { proposal.sourceURL == nil ? nil : proposal.homeName }
        var canAdopt: Bool { proposal.canCopy }
    }

    var requiresHomeAccountSetup: Bool { !personalMode || personalConfiguration == nil }

    var currentHomeName: String? {
        guard case .ready(let ready) = state else { return nil }
        if personalMode, ready.householdID == nil { return retainedLocalHomeName }
        if let scope = ready.homeScope {
            return homeCoordinator.homes.first { $0.graph == scope.graph }?.name
        }
        return ready.householdID == nil ? nil : localHomeName
    }

    /// One read-only presentation value for home entry. All persistence and
    /// invitation work stays with the existing command owners.
    var homeEntry: HomeEntrySnapshot {
        let store: HomeEntrySnapshot.Store
        switch state {
        case .loading: store = .opening
        case .failed: store = .failed
        case .ready(let ready):
            store = personalMode ? .account : .local(hasHome: ready.householdID != nil,
                discoveryComplete: localDiscoveryComplete)
        }
        var visibleInvitations = invitations?.entries ?? []
        if let id = joiningPresentationID,
           !visibleInvitations.contains(where: { $0.id == id }),
           let held = invitations?.allEntries.first(where: {
               $0.id == id && $0.openRequested && !$0.activationResolved && $0.state != .dismissed
           }),
           !hasVerifiedDifferentAccount(for: held) {
            // Store retirement temporarily removes a bound entry from the
            // controller's verified-session filter. This is presentation only;
            // every invitation command still validates its original authority.
            visibleInvitations.append(held)
        }
        // A retained source belongs to this device. Its copy command still belongs
        // to the account that approved it, so another account can only open it.
        let presentedCopyState: HomeEntrySnapshot.RetainedLocalCopyState
        if let deviceLocalHome, case .ready(let current) = accountProvider?.state,
           current != deviceLocalHome.session {
            presentedCopyState = .unavailable
        } else { presentedCopyState = retainedLocalCopyState }
        return HomeEntrySnapshot(store: store, readiness: homeCoordinator.readiness,
            discovery: homeCoordinator.discoveryState, homes: homeCoordinator.homes,
            currentHomeName: currentHomeName, retainedLocalHomeName: retainedLocalHomeName,
            isShowingRetainedLocalHome: isShowingRetainedLocalHome,
            retainedLocalCopyState: presentedCopyState,
            invitations: visibleInvitations, hasPendingInvitation: invitations?.hasPendingActivation ?? false,
            hasVerifiedInvitationAccount: invitations?.hasVerifiedAccount ?? false,
            invitationProblem: invitations?.problem, importProblems: invitations?.importProblems ?? [:],
            isCreatingHome: isCreatingHome, homeDiscoveryFailed: homeDiscoveryError != nil,
            isResolvingFirstAccount: isResolvingFirstAccount, joinError: joinError)
    }

    private func hasVerifiedDifferentAccount(for entry: HomeInvitationInbox.Entry) -> Bool {
        guard let bound = entry.session, case .ready(let verified) = accountProvider?.state else { return false }
        return bound != verified
    }

    var homeEntryCommands: HomeEntryCommands { HomeEntryCommands(bootstrap: self) }
#if DEBUG
    private var personalFixture = false
    private var personalNoticeFixture = false
    private var personalRevokedFixture = false
#endif
    private static let personalModeKey = "shopping.personalCart.enabled"
    private static let pendingImportKey = "shopping.personalCart.pendingImport"
    private static let retainedLocalKey = "shopping.homeAdoption.showRetainedLocal"

    init(
        configuration: @escaping () throws -> PersistenceConfiguration = { try .applicationLocal() },
        preloadedPreviewEnvironment: ShoppingPreviewEnvironment? = nil,
        defaults: UserDefaults = .standard,
        invitations: HomeInvitationController? = nil,
        autoResolveFreshAccount: Bool = true,
        autoJoinInvitations: Bool = true,
        makeAccountProvider: ((URL) throws -> ShopperSessionProvider)? = nil,
        accountStoreDirectory: (() throws -> URL)? = nil,
        participantStoreForHomeChoice: @escaping (PersistenceController) -> NSPersistentStore? = { $0.store(for: .participantShared) },
        invitationShareIdentity: @escaping @MainActor @Sendable (PersistenceController, ShopperSession, HomeGraphIdentity) async throws -> HomeShareIdentity? = {
            try await ManagedHomeInvitationTransport(persistence: $0, session: $1).shareIdentity(for: $2)
        },
        makeHomeLeaveTransport: @escaping @Sendable (PersonalCartService) -> ManagedHomeLeaveTransport = { ManagedHomeLeaveTransport(cart: $0, persistence: $0.persistence) },
        makeHomeRejoinVerifier: @escaping @Sendable (PersonalCartService) -> any HomeRejoinVerifying = { ManagedHomeRejoinVerifier(cart: $0) },
        sharingStatusDeadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(10)) },
        readSharingWork: @escaping @Sendable (PersonalCartService, ActiveHomeScope) async throws -> HomeSharingWorkSnapshot = { service, scope in
            try await Task.detached(priority: .utility) {
                try service.sharingWorkSnapshot(householdID: scope.graph.householdID, listID: scope.graph.listID)
            }.value
        },
        discoverHomes: @escaping @Sendable (HomeDiscoveryService) async throws -> HomeDiscovery = { discovery in
            try await Task.detached(priority: .utility) { try discovery.discover() }.value
        },
        activateAccountStore: @escaping @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration = { try PersistenceBootstrap.productionAccountActivation(source: $0, session: $1, base: $2, importLegacy: $3) }
    ) {
        self.sharingCheck = HomeSharingStatusCheck(waitForDeadline: sharingStatusDeadline)
        self.readSharingWork = readSharingWork
        self.discoverHomes = discoverHomes
        self.configuration = configuration
        self.preloadedPreviewEnvironment = preloadedPreviewEnvironment
        self.defaults = defaults
        self.invitations = invitations
        self.autoResolveFreshAccount = autoResolveFreshAccount
        self.autoJoinInvitations = autoJoinInvitations
        self.homeCoordinator = ActiveHomeCoordinator(defaults: defaults)
        self.editorDrafts = HomeEditorDraftStore(defaults: defaults)
        self.makeAccountProvider = makeAccountProvider
        self.accountStoreDirectory = accountStoreDirectory
        self.participantStoreForHomeChoice = participantStoreForHomeChoice
        self.invitationShareIdentity = invitationShareIdentity
        self.makeHomeLeaveTransport = makeHomeLeaveTransport
        self.makeHomeRejoinVerifier = makeHomeRejoinVerifier
        self.activateAccountStore = activateAccountStore
        homeObservation = homeCoordinator.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        invitationObservation = invitations?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        cloudMonitor.onChange = { [weak self] in self?.cloudStatus = $0 }
        invitations?.onChoiceInvalidated = { [weak self] identity in
            guard let self else { return }
            for activation in self.invitationActivations.values where activation.entry.identity == identity {
                activation.authority.retire()
            }
            for entry in self.invitations?.allEntries ?? [] where entry.identity == identity {
                self.autoOpenFailures.remove(entry.id)
            }
        }
        invitations?.onChange = { [weak self] in
            guard let self else { return }
            for activation in self.invitationActivations.values {
                if self.invitations?.allEntries.contains(activation.entry) != true { activation.authority.retire() }
            }
            if let activeID = self.autoOpeningInvitationID,
               let latest = self.invitations?.entries.last(where: {
                   $0.openRequested && !$0.activationResolved
               }), latest.id != activeID {
                self.invitationActivations[activeID]?.authority.retire()
            }
            self.homeCoordinator.setInvitationPending(self.invitations?.hasPendingActivation == true)
            self.objectWillChange.send()
            self.scheduleAutomaticJoinConnection()
            self.scheduleAutomaticInvitationOpen()
        }
    }

    nonisolated private static func productionAccountDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ShoppingAccounts", isDirectory: true)
    }

    nonisolated private static func productionAccountActivation(
        source: URL?, session: ShopperSession, base: URL, importLegacy: Bool
    ) throws -> PersistenceConfiguration {
        try PersonalCartActivation.activate(sourceURL: source, session: session,
            baseDirectory: base, importLegacy: importLegacy)
    }

    nonisolated private static func productionAccountProvider(_ base: URL) throws -> ShopperSessionProvider {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "ShoppingCloudKitContainerIdentifier") as? String,
              let environment = Bundle.main.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String else {
            throw ShopperSessionError.invalidConfiguration
        }
        return try ShopperSessionProvider(containerIdentifier: identifier, environment: environment,
            cacheDirectory: base.appendingPathComponent("Bindings", isDirectory: true))
    }

    var sharingStatusDescription: String {
        sharingStatusPresentation.details
    }

    var sharingStatusPresentation: SharingStatusPresentation { homeSharingStatus.summary }

    var homeSharingStatus: HomeSharingStatus {
        let account: HomeSharingStatus.Account
        let currentSession = try? accountProvider?.currentSession()
        let matchesAttachedAccount = activeAccountBinding != nil && currentSession?.accountBinding == activeAccountBinding
        if !personalMode { account = .localOnly }
        else {
            switch accountProvider?.state {
            case .ready:
                account = activeAccountBinding != nil && !matchesAttachedAccount ? .changed : .verified
            case .cached:
                account = activeAccountBinding != nil && !matchesAttachedAccount ? .changed : .cached
            case .accountChanged: account = .changed
            default: account = .unavailable
            }
        }
        // Provider invalidation is synchronous; its UI notification is queued.
        // Never label the previous account's observations as the new account's
        // during that gap, even though the retained store has not detached yet.
        let canShowAttachedObservations = personalMode && matchesAttachedAccount
        let home: HomeSharingStatus.Home
        if personalMode && !canShowAttachedObservations { home = .unresolved }
        else {
            switch homeCoordinator.readiness {
            case .accountUnavailable: home = .unresolved
            case .waitingForImport: home = .waitingForImport
            case .choiceRequired: home = .choiceRequired
            case .selectedHomeUnavailable: home = .unavailable
            case .ready(let scope):
                switch homeCoordinator.homes.first(where: { $0.graph == scope.graph })?.access {
                case .owner: home = .availableOwner
                case .contributor: home = .availableContributor
                case .restricted: home = .readOnly
                default: home = .unresolved
                }
            }
        }
        var input = HomeSharingStatus.Input(account: account, home: home,
            invitation: canShowAttachedObservations ? sharingInvitationStatus : .none)
        if canShowAttachedObservations, case .ready(let ready) = state {
            if let store = ready.persistence.store(for: .ownerPrivate) {
                input.ownedStore = cloudStatus.snapshot(forStores: [store.identifier])
            }
            if let store = ready.persistence.store(for: .participantShared) {
                input.sharedStore = cloudStatus.snapshot(forStores: [store.identifier])
            }
            if sharingWorkScope == ready.homeScope, sharingWorkPresentationID == ready.presentation.id,
               let work = sharingWork, work.scope.accountBinding == currentSession?.accountBinding {
                input.work = .init(pendingCheckout: work.pendingCheckoutCount, pendingUndo: work.pendingUndoCount,
                    retained: work.heldCount, isIncomplete: work.isIncomplete)
            }
            input.ownerAssociationCount = associationCountKnown ? pendingShareAssociationCount : nil
            input.associationNeedsAttention = shareAssociationError != nil
            input.localCheckNeedsAttention = cartResumeError != nil || homeDiscoveryError != nil || sharingWorkNeedsAttention
            input.leavePendingCount = homeLeaveStatuses.filter(\.requiresResolution).count
        }
        return HomeSharingStatus(input: input)
    }

    private var sharingInvitationStatus: HomeSharingStatus.Invitation {
        guard let invitations else { return .none }
        if invitations.problem != nil || !invitations.importProblems.isEmpty { return .attention }
        let entries = invitations.entries
        if entries.contains(where: { if case .failed = $0.state { return true }; return false }) { return .attention }
        if entries.contains(where: { if case .joining = $0.state { return true }; return false }) { return .joining }
        if entries.contains(where: { if case .loading = $0.state { return true }; return false }) { return .loading }
        if entries.contains(where: { if case .ready = $0.state { return true }; return false }) { return .ready }
        return entries.isEmpty ? .none : .joining
    }

    /// A timed-out or cancelled callback can still be draining after its UI wait ends.
    var hasOutstandingSharingStatusCheck: Bool { sharingCheck.isRunning }

    /// Screen appearance reads only the existing local graph. It does not retry
    /// native commands or reload grocery projections.
    func refreshSharingStatus() async { await performSharingStatusCheck(retry: false) }

    /// A user-requested check uses the normal account/access/recovery services.
    /// It never schedules a CloudKit export, resets a store, or waits for a peer.
    func checkSharingStatus() async { await performSharingStatusCheck(retry: true) }

    private func performSharingStatusCheck(retry: Bool) async {
        guard !isCheckingSharingStatus else { return }
        guard !sharingCheck.isRunning else {
            sharingCheckProblem = .alreadyRunning
            sharingStatusCheckMessage = "The previous check is still finishing. Saved data is retained; you can return to your home and try again later."
            return
        }
        let id = UUID(), requestedGeneration = generation
        let capturedService = personalService
        let capturedProvider = accountProvider
        let capturedSession = try? capturedProvider?.currentSession()
        let ready: ReadyState?
        if case .ready(let value) = state { ready = value } else { ready = nil }
        let scope = ready?.homeScope
        sharingCheckID = id
        isCheckingSharingStatus = true
        sharingStatusCheckMessage = nil
        sharingCheckProblem = nil
        let outcome = await sharingCheck.run { [weak self] in
            guard let self else { throw CancellationError() }
            if retry {
                if let capturedProvider { await capturedProvider.refresh() }
                try Task.checkCancellation()
                guard self.sharingCheckID == id, self.generation == requestedGeneration,
                      self.accountProvider === capturedProvider else { throw CancellationError() }
                self.configureInvitations()
                self.invitations?.checkAgain()
                if let capturedService, self.personalService === capturedService {
                    await self.refreshHomeAccessAndReplay()
                    try Task.checkCancellation()
                }
                await self.refreshShareAssociations()
                try Task.checkCancellation()
            }
            guard self.sharingCheckID == id, self.generation == requestedGeneration,
                  self.personalService === capturedService,
                  self.accountProvider === capturedProvider,
                  (try? capturedProvider?.currentSession()) == capturedSession else { throw CancellationError() }
            guard let capturedService, let scope, let ready else { return nil }
            guard self.isCurrentSharingScope(ready, scope: scope) else { throw CancellationError() }
            return try await self.readSharingWork(capturedService, scope)
        }
        guard sharingCheckID == id, generation == requestedGeneration else { return }
        isCheckingSharingStatus = false
        sharingCheckID = nil
        guard personalService === capturedService, accountProvider === capturedProvider,
              (try? capturedProvider?.currentSession()) == capturedSession,
              ready.map({ $0.presentation.isActive }) ?? true else { return }
        switch outcome {
        case .value(let work):
            if let ready, let scope {
                guard isCurrentSharingScope(ready, scope: scope),
                      work?.scope == capturedSession.map({ HomeEffectScope(session: $0,
                        householdID: scope.graph.householdID, listID: scope.graph.listID) }) else { return }
                sharingWork = work
                sharingWorkScope = scope
                sharingWorkPresentationID = ready.presentation.id
            }
            sharingWorkNeedsAttention = false
            sharingStatusCheckMessage = retry
                ? "Available observations were checked. This does not confirm delivery to another device."
                : "Saved work was checked on this device. iCloud activity is shown from existing observations."
        case .failed:
            sharingCheckProblem = .failed
            sharingWork = nil
            sharingWorkNeedsAttention = true
            sharingStatusCheckMessage = "Some status information could not be checked. Saved data is retained. Try again later."
        case .timedOut:
            sharingCheckProblem = .timedOut
            sharingWork = nil
            sharingStatusCheckMessage = "The check is taking longer than expected. Saved data is retained; you can return to your home and check again later."
        case .cancelled: break
        case .alreadyRunning:
            sharingCheckProblem = .alreadyRunning
            sharingStatusCheckMessage = "A previous check is still finishing. Try again later."
        }
    }

    private func isCurrentSharingScope(_ ready: ReadyState, scope: ActiveHomeScope) -> Bool {
        guard ready.presentation.isActive, case .ready(let current) = state else { return false }
        return current.presentation.id == ready.presentation.id && current.homeScope == scope
            && homeCoordinator.isCurrent(scope: scope, generation: ready.homeGeneration)
    }

    private func clearSharingStatusPresentation() {
        sharingCheck.invalidate()
        sharingCheckID = nil
        isCheckingSharingStatus = false
        sharingStatusCheckMessage = nil
        sharingCheckProblem = nil
        sharingWork = nil
        sharingWorkScope = nil
        sharingWorkPresentationID = nil
        sharingWorkNeedsAttention = false
    }

    static func application(processInfo: ProcessInfo = .processInfo) -> PersistenceBootstrap {
        if let fixtureName = processInfo.environment["SHOPPING_PERFORMANCE_FIXTURE"],
           let fixture = ShoppingPreviewCase(rawValue: fixtureName),
           fixture == .performance || fixture == .stress {
            do {
                let storeURL = try performanceStoreURL(
                    for: fixture,
                    runID: processInfo.environment["SHOPPING_PERFORMANCE_RUN_ID"]
                )
                if processInfo.environment["SHOPPING_PERFORMANCE_RESET"] == "1" {
                    removeSQLiteStore(at: storeURL)
                }
                if FileManager.default.fileExists(atPath: storeURL.path) {
                    return PersistenceBootstrap(configuration: { .local(storeURL: storeURL) })
                }
                let environment = try ShoppingPreviewFixtures.make(fixture, storeURL: storeURL)
                return PersistenceBootstrap(
                    configuration: { .local(storeURL: storeURL) },
                    preloadedPreviewEnvironment: environment
                )
            } catch {
                return PersistenceBootstrap(configuration: { throw error })
            }
        }
#if DEBUG
        if processInfo.environment["SHOPPING_UI_TEST_PERSISTENCE_FAILURE"] == "1" {
            let error = NSError(
                domain: "ShoppingUITest",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The saved household grocery store could not be opened. Its data was left unchanged so you can retry safely."
                ]
            )
            return PersistenceBootstrap(configuration: { throw error })
        }
#endif
        if let path = processInfo.environment["SHOPPING_UI_TEST_STORE_PATH"] {
            do {
                let storeURL = try uiTestStoreURL(for: path)
                let identity = SHA256.hash(data: Data(storeURL.standardizedFileURL.path.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let suite = "Shopping.UITestBootstrap." + identity
                guard let fixtureDefaults = UserDefaults(suiteName: suite) else {
                    throw CocoaError(.fileReadUnknown)
                }
                if processInfo.environment["SHOPPING_UI_TEST_FIXTURE"] != nil {
                    fixtureDefaults.removePersistentDomain(forName: suite)
                }
#if DEBUG
                let unavailableSetup = processInfo.environment["SHOPPING_UI_TEST_SETUP_UNAVAILABLE"] == "1"
                let activeHomesFixture = processInfo.environment["SHOPPING_UI_TEST_ACTIVE_HOMES"] == "1"
                let homeAdoptionFixture = processInfo.environment["SHOPPING_UI_TEST_HOME_ADOPTION"] == "1"
                let acceptedInvitationFixture = activeHomesFixture
                    && processInfo.environment["SHOPPING_UI_TEST_ACCEPTED_INVITATION"] == "1"
#else
                let unavailableSetup = false
                let activeHomesFixture = false
                let homeAdoptionFixture = false
                let acceptedInvitationFixture = false
#endif
                let providerFactory: (URL) throws -> ShopperSessionProvider = { base in
                    if unavailableSetup { throw ShopperSessionError.temporarilyUnavailable }
                    let available = activeHomesFixture || homeAdoptionFixture
                    return try ShopperSessionProvider(containerIdentifier: "iCloud.test.shopping-homes", environment: "Development",
                        cacheDirectory: base.appendingPathComponent("Bindings"),
                        lookup: .init(status: { available ? .available : .noAccount },
                            recordName: { "isolated-home-test-account" }),
                        notifications: NotificationCenter())
                }
                let accountDirectory: () throws -> URL = {
                    storeURL.deletingLastPathComponent()
                        .appendingPathComponent(storeURL.lastPathComponent + "-accounts", isDirectory: true)
                }
                let activate: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration = { source, session, base, approved in
                    if activeHomesFixture { return .local(storeURL: storeURL) }
                    if homeAdoptionFixture {
                        guard source == nil, !approved else { throw HomeAdoptionJournal.Failure.copyUnavailable }
                        return .local(storeURL: base.appendingPathComponent("Account.sqlite"))
                    }
                    return .local(storeURL: base.appendingPathComponent("Account.sqlite"))
                }
#if DEBUG
                let rootGoneLeaveFixture = HomeLeaveRootGoneUITestBackend.isEnabled(processInfo.environment)
#endif
                let participantStoreLookup: (PersistenceController) -> NSPersistentStore? = { persistence in
#if DEBUG
                    if rootGoneLeaveFixture || acceptedInvitationFixture { return persistence.primaryStore }
#endif
                    return persistence.store(for: .participantShared)
                }
                let shareLookup: @MainActor @Sendable (PersistenceController, ShopperSession, HomeGraphIdentity) async throws -> HomeShareIdentity? = { persistence, session, graph in
#if DEBUG
                    if rootGoneLeaveFixture { return HomeLeaveRootGoneUITestBackend.share }
#endif
                    return try await ManagedHomeInvitationTransport(persistence: persistence, session: session).shareIdentity(for: graph)
                }
                let leaveTransportFactory: @Sendable (PersonalCartService) -> ManagedHomeLeaveTransport = { cart in
#if DEBUG
                    if rootGoneLeaveFixture {
                        return ManagedHomeLeaveTransport(cart: cart, persistence: cart.persistence,
                            backend: HomeLeaveRootGoneUITestBackend(cart: cart))
                    }
#endif
                    return ManagedHomeLeaveTransport(cart: cart, persistence: cart.persistence)
                }
                var fixtureInvitations: HomeInvitationController?
#if DEBUG
                var fixtureInbox: HomeInvitationInbox?
                if activeHomesFixture || homeAdoptionFixture {
                    let inboxURL = storeURL.deletingLastPathComponent()
                        .appendingPathComponent(storeURL.lastPathComponent + "-invitations/inbox.json")
                    let inbox = try HomeInvitationInbox(url: inboxURL,
                        containerIdentifier: "iCloud.test.shopping-homes", environment: "Development")
                    fixtureInbox = inbox
                    if (homeAdoptionFixture || processInfo.environment["SHOPPING_UI_TEST_PENDING_INVITATION"] == "1"),
                       processInfo.environment["SHOPPING_UI_TEST_FIXTURE"] != nil {
                        try inbox.enqueue(identity: HomeInvitationIdentity(containerIdentifier: "iCloud.test.shopping-homes",
                            environment: "Development", share: HomeShareIdentity(recordName: "fixture-share",
                                zoneName: "fixture-zone", zoneOwnerName: "fixture-owner")), metadataArchive: Data([1]))
                    }
                    fixtureInvitations = HomeInvitationController(inbox: inbox)
                }
#endif
                if let fixtureName = processInfo.environment["SHOPPING_UI_TEST_FIXTURE"],
                   let fixture = ShoppingPreviewCase(rawValue: fixtureName) {
                    let environment = try ShoppingPreviewFixtures.make(fixture, storeURL: storeURL)
#if DEBUG
                    if activeHomesFixture && (processInfo.environment["SHOPPING_UI_TEST_SECOND_HOME"] == "1"
                        || acceptedInvitationFixture) {
                        _ = try environment.service.createHousehold(name: "Second home")
                    }
                    if acceptedInvitationFixture,
                       processInfo.environment["SHOPPING_UI_TEST_FIXTURE"] != nil,
                       let inbox = fixtureInbox {
                        let invited = try HomeDiscoveryService(persistence: environment.persistence).discover().homes
                            .first { $0.name == "Second home" }
                        guard let invited, let sharedStoreIdentifier = environment.persistence.primaryStore?.identifier else {
                            throw HomeInvitationInbox.Error.invalidState
                        }
                        let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.shopping-homes",
                            environment: "Development", accountRecordName: "isolated-home-test-account")
                        let entry = try inbox.enqueue(identity: HomeInvitationIdentity(
                            containerIdentifier: session.containerIdentifier, environment: session.environment,
                            share: HomeShareIdentity(recordName: "fixture-share", zoneName: "fixture-zone",
                                zoneOwnerName: "fixture-owner")), metadataArchive: Data([1]),
                            displayName: invited.name)
                        try inbox.setSession(session)
                        let acceptance = try inbox.beginAcceptance(id: entry.id,
                            sharedStoreIdentifier: sharedStoreIdentifier)
                        try inbox.finishAcceptance(acceptance)
                        let imported = try inbox.beginImportResolution(id: entry.id,
                            sharedStoreIdentifier: sharedStoreIdentifier)
                        try inbox.markReady(imported, graph: invited.graph)
                        fixtureInvitations = HomeInvitationController(inbox: inbox)
                    }
#endif
                    let bootstrap = PersistenceBootstrap(
                        configuration: { .local(storeURL: storeURL) },
                        preloadedPreviewEnvironment: environment,
                        defaults: fixtureDefaults, invitations: fixtureInvitations, makeAccountProvider: providerFactory,
                        accountStoreDirectory: accountDirectory, participantStoreForHomeChoice: participantStoreLookup,
                        invitationShareIdentity: shareLookup, makeHomeLeaveTransport: leaveTransportFactory,
                        makeHomeRejoinVerifier: { service in
#if DEBUG
                            if acceptedInvitationFixture { return UITestHomeRejoinVerifier() }
#endif
                            return ManagedHomeRejoinVerifier(cart: service)
                        },
                        activateAccountStore: activate
                    )
#if DEBUG
                    if activeHomesFixture {
                        bootstrap.personalMode = true
                        bootstrap.preloadedPreviewEnvironment = nil
                        if processInfo.environment["SHOPPING_UI_TEST_PENDING_HOME_CREATION"] == "1",
                           let store = environment.persistence.primaryStore {
                            let session = try ShopperSession.authenticated(containerIdentifier: "iCloud.test.shopping-homes",
                                environment: "Development", accountRecordName: "isolated-home-test-account")
                            let pending = HomeCreationCommand(id: UUID(), session: session, storeIdentifier: store.identifier,
                                householdID: environment.ids.householdID, listID: environment.ids.listID, name: "Preview household")
                            try JSONEncoder().encode(pending).write(
                                to: HomeCreationJournal.location(storeURL: storeURL, session: session), options: .atomic)
                        }
                    }
                    if homeAdoptionFixture {
                        bootstrap.localHomeName = "Preview household"
                    }
                    bootstrap.personalFixture = !activeHomesFixture && !homeAdoptionFixture && processInfo.environment["SHOPPING_UI_TEST_PERSONAL_CART"] == "1"
                    bootstrap.personalNoticeFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_NOTICE"] == "1"
                    bootstrap.personalRevokedFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_REVOKED"] == "1"
#endif
                    return bootstrap
                }
                let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: storeURL) },
                    defaults: fixtureDefaults, invitations: fixtureInvitations, makeAccountProvider: providerFactory,
                    accountStoreDirectory: accountDirectory, participantStoreForHomeChoice: participantStoreLookup,
                        invitationShareIdentity: shareLookup, makeHomeLeaveTransport: leaveTransportFactory,
                        activateAccountStore: activate)
                if unavailableSetup || activeHomesFixture || homeAdoptionFixture {
                    bootstrap.personalMode = activeHomesFixture || fixtureDefaults.bool(forKey: personalModeKey)
                }
#if DEBUG
                bootstrap.personalFixture = !activeHomesFixture && !homeAdoptionFixture && processInfo.environment["SHOPPING_UI_TEST_PERSONAL_CART"] == "1"
#endif
                return bootstrap
            } catch {
                return PersistenceBootstrap(configuration: { throw error })
            }
        }
        let bootstrap = PersistenceBootstrap(invitations: .shared)
        bootstrap.personalMode = UserDefaults.standard.bool(forKey: personalModeKey)
        return bootstrap
    }

    static func uiTestStoreURL(
        for path: String,
        applicationSupportDirectory: URL? = nil
    ) throws -> URL {
        let requestedURL = URL(fileURLWithPath: path)
        if path.hasPrefix("/"), FileManager.default.isWritableFile(
            atPath: requestedURL.deletingLastPathComponent().path
        ) {
            return requestedURL
        }
        let fileName = requestedURL.lastPathComponent
        let supportDirectory = try applicationSupportDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportDirectory.appendingPathComponent("UITestStores", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneUITestStores(in: directory, keeping: fileName)
        return directory.appendingPathComponent(fileName)
    }

    private static func pruneUITestStores(in directory: URL, keeping currentStoreName: String) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let storeGroups = Dictionary(grouping: contents.compactMap { url -> (String, URL)? in
            guard let storeName = sqliteStoreName(for: url.lastPathComponent) else { return nil }
            return (storeName, url)
        }, by: \.0)
        let inactiveGroups = storeGroups.keys.filter { $0 != currentStoreName }.sorted { left, right in
            latestModificationDate(in: storeGroups[left] ?? []) > latestModificationDate(in: storeGroups[right] ?? [])
        }
        for storeName in inactiveGroups.dropFirst(max(0, retainedUITestStoreLimit - 1)) {
            for entry in storeGroups[storeName] ?? [] {
                try? fileManager.removeItem(at: entry.1)
            }
        }

        let historyTokens = contents.filter { $0.lastPathComponent.hasPrefix("history-") }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
        for token in historyTokens.dropFirst(retainedUITestHistoryTokenLimit) {
            try? fileManager.removeItem(at: token)
        }
    }

    private static func sqliteStoreName(for fileName: String) -> String? {
        guard let range = fileName.range(of: ".sqlite") else { return nil }
        return String(fileName[..<range.upperBound])
    }

    private static func latestModificationDate(in entries: [(String, URL)]) -> Date {
        entries.map { modificationDate(of: $0.1) }.max() ?? .distantPast
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func performanceStoreURL(
        for fixture: ShoppingPreviewCase,
        runID: String?
    ) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("PerformanceFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let normalizedRunID = runID?.lowercased().filter { character in
            character.isLetter || character.isNumber || character == "-"
        }
        let effectiveRunID = normalizedRunID.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let storeName = [
            "shopping",
            fixture.rawValue,
            "v\(performanceFixtureVersion)",
            effectiveRunID
        ].joined(separator: "-")
        return directory.appendingPathComponent("\(storeName).sqlite")
    }

    private static func removeSQLiteStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    deinit {
        if let accountObserver { accountProvider?.removeSessionObserver(accountObserver) }
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
    }

    nonisolated private static func readDeviceLocalHome(base: URL) throws -> DeviceLocalHome? {
        if let selected = try DeviceLocalHomeSelectionJournal(baseDirectory: base).read() {
            return .selected(selected)
        }
        if let adopted = try HomeAdoptionJournal(baseDirectory: base).retainedLocalRecord() {
            return .adopted(adopted)
        }
        return nil
    }

    nonisolated private static func validateDeviceLocalHome(_ home: DeviceLocalHome, base: URL) throws {
        switch home {
        case .adopted(let record):
            try HomeAdoptionJournal(baseDirectory: base).validateRetainedSource(record)
        case .selected(let source):
            guard try DeviceLocalHomeSelectionJournal(baseDirectory: base).read() == source else {
                throw HomeAdoptionJournal.Failure.sourceChanged
            }
        }
    }

    nonisolated private static func conversion(for home: DeviceLocalHome, base: URL)
        throws -> RetainedHomeConversion? {
        let journal = RetainedHomeConversionJournal(baseDirectory: base, session: home.session)
        switch home {
        case .adopted(let record): return try journal.read(session: record.session, retainedRecordID: record.id)
        case .selected(let source):
            guard let id = source.conversionID else { return nil }
            return try journal.read(session: source.session, id: id)
        }
    }

    nonisolated private static func currentDeviceLocalName(_ home: DeviceLocalHome) throws -> String {
        guard let sourceURL = home.sourceURL, let storeIdentifier = home.storeIdentifier,
              let householdID = home.householdID, let listID = home.listID else { return home.homeName }
        let persistence = try PersistenceController(storeURL: sourceURL)
        defer {
            persistence.writer.performAndWait { persistence.writer.reset() }
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try? persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let exactRoot: String?
        if case .selected(let selection) = home { exactRoot = selection.graph.rootURI }
        else { exactRoot = nil }
        return try HomeDiscoveryService(persistence: persistence).discover().homes.first(where: {
            $0.graph.storeIdentifier == storeIdentifier && $0.graph.householdID == householdID
                && $0.graph.listID == listID
                && (exactRoot == nil || $0.graph.rootURI == exactRoot)
        })?.name ?? home.homeName
    }

    func start() {
        guard case .loading = state, transition == nil, !restoringLocalRoute else { return }
        if !personalMode, defaults.bool(forKey: Self.retainedLocalKey), deviceLocalHome == nil {
            restoringLocalRoute = true
            let requestedGeneration = generation
            Task {
                defer { restoringLocalRoute = false }
                do {
                    let base = try await resolvedAccountDirectory()
                    let record = try await Task.detached(priority: .userInitiated) {
                        let record = try Self.readDeviceLocalHome(base: base)
                        if let record { try Self.validateDeviceLocalHome(record, base: base) }
                        return record
                    }.value
                    guard generation == requestedGeneration, transition == nil else { return }
                    guard let record else {
                        // A completed local deletion removes the retained route,
                        // while the old adoption journal remains immutable.
                        defaults.set(false, forKey: Self.retainedLocalKey)
                        deviceLocalHome = nil
                        retainedLocalConfiguration = nil
                        retainedLocalHomeName = nil
                        retainedLocalCopyState = .unavailable
                        isShowingRetainedLocalHome = false
                        if let invitations { await invitations.prepare() }
                        guard generation == requestedGeneration, transition == nil else { return }
                        load()
                        return
                    }
                    deviceLocalHome = record
                    retainedLocalHomeName = try await Task.detached(priority: .userInitiated) {
                        try Self.currentDeviceLocalName(record)
                    }.value
                    let conversion = try await Task.detached(priority: .userInitiated) {
                        let command = try Self.conversion(for: record, base: base)
                        let journal = RetainedHomeConversionJournal(baseDirectory: base, session: record.session)
                        return try command.map { ($0, try journal.wasDestinationDeleted($0)) }
                    }.value
                    retainedLocalCopyState = conversion?.0.copied == true && conversion?.1 == false
                        ? .copied : .available
                    retainedLocalConfiguration = .local(storeURL: record.sourceURL)
                    isShowingRetainedLocalHome = true
                    if let invitations { await invitations.prepare() }
                    guard generation == requestedGeneration, transition == nil else { return }
                    load()
                } catch {
                    if generation == requestedGeneration { state = .failed(error) }
                }
            }
            return
        }
        guard let invitations else {
            if personalMode { activatePersonalCarts(importLegacy: false) } else { load() }
            return
        }
        let requestedGeneration = generation
        Task {
            await invitations.prepare()
            guard generation == requestedGeneration, case .loading = state, transition == nil else { return }
            if personalMode { activatePersonalCarts(importLegacy: false) } else { load() }
        }
    }

    func retry() {
        if personalMode { activatePersonalCarts(importLegacy: false) }
        else if defaults.bool(forKey: Self.retainedLocalKey), deviceLocalHome == nil {
            beginTransition { [weak self] in self?.start() }
        } else { beginTransition { [weak self] in self?.load() } }
    }

    func isPresentationMounted(_ id: UUID) -> Bool { mountedPresentations.contains(id) }

    func presentationDidAppear(_ id: UUID) { mountedPresentations.insert(id) }

    func presentationDidDisappear(_ id: UUID) {
        mountedPresentations.remove(id)
        if let transition, transition.previous?.presentation.id == id {
            loadingTransitionID = transition.id
        }
    }

    // Called only by the loading view's task, after the retired ready hierarchy disappears.
    func runLoadingTransition() async {
        guard let transition else { start(); return }
        guard loadingTransitionID == transition.id,
              transition.previous.map({ !mountedPresentations.contains($0.presentation.id) }) ?? true else { return }
        self.transition = nil
        do {
            try await detachStores(transition.previous)
            pendingRetirement = nil
            transition.action()
        } catch {
            accountLoadInProgress = false
            state = .failed(error)
        }
    }

    private func beginTransition(_ action: @escaping () -> Void) {
        guard transition == nil else { return }
        let previous: ReadyState?
        if case .ready(let ready) = state { previous = ready } else { previous = pendingRetirement }
        pendingRetirement = previous
        previous?.presentation.retire()
        clearHomeLeavePresentation()
        clearSharingStatusPresentation()
        if let active = invitations?.entries.first(where: { $0.openRequested }) {
            joiningPresentationID = active.id
        }
        invitations?.configure(session: nil)
        homeCoordinator.bind(nil)
        generation += 1
        let next = Transition(previous: previous, action: action)
        transition = next
        loadingTransitionID = previous.map { mountedPresentations.contains($0.presentation.id) } == true ? nil : next.id
        state = .loading
    }

    func retireAndFail(_ error: Error) {
        beginTransition { [weak self] in self?.state = .failed(error) }
    }

    func applicationDidEnterForeground() {
        guard case .ready = state, transition == nil else { return }
        Task { await refreshHomeDeletionStatuses() }
        if let accountProvider {
            Task {
                await accountProvider.refresh()
                configureInvitations()
                Task { await refreshHomeLeaveStatuses() }
                await refreshHomeAccessAndReplay()
            }
        } else { resumePendingCart() }
        invitations?.checkAgain()
        if case .ready(let ready) = state { ready.personalCart?.refresh() }
        consumeHistory()
        Task { try? await refreshHomes() }
        retryShareAssociations()
    }

    /// Existing personal-cart entry point uses the same durable, account-bound approval.
    func activatePersonalCarts(importLegacy: Bool) {
        guard !accountLoadInProgress, transition == nil else { return }
        homeSetupError = nil
        if !personalMode, case .ready = state, !isShowingRetainedLocalHome {
            Task {
                do {
                    let choice = try await prepareInvitationSetup()
                    try await confirmInvitationSetup(choice, copyLocal: importLegacy)
                } catch { homeSetupError = error }
            }
            return
        }
        accountLoadInProgress = true
        beginTransition { [weak self] in self?.openPersonalStore() }
    }

    private func resolvedAccountDirectory() async throws -> URL {
        if let accountStoreDirectory { return try accountStoreDirectory() }
        return try await Task.detached(priority: .userInitiated) {
            try Self.productionAccountDirectory()
        }.value
    }

    private func resolvedAccountProvider(base: URL) async throws -> ShopperSessionProvider {
        if let accountProvider { return accountProvider }
        let provider: ShopperSessionProvider
        if let makeAccountProvider { provider = try makeAccountProvider(base) }
        else {
            provider = try await Task.detached(priority: .userInitiated) {
                try Self.productionAccountProvider(base)
            }.value
        }
        // Concurrent read-only preparation may have installed the provider while construction ran.
        if let accountProvider { return accountProvider }
        accountProvider = provider
        accountObserver = provider.observeSessionChanges { [weak self] in
            Task { @MainActor in self?.accountStateChanged() }
        }
        return provider
    }

    private func verifiedSession(_ provider: ShopperSessionProvider) throws -> ShopperSession {
        guard case .ready(let session) = provider.state else { throw ShopperSessionError.setupRequired }
        return session
    }

    func prepareInvitationSetup() async throws -> InvitationSetupChoice {
        guard !accountLoadInProgress, transition == nil else { throw HomeAdoptionJournal.Failure.staleProposal }
        let capturedGeneration = generation
        let ready: ReadyState?
        if case .ready(let value) = state { ready = value } else { ready = nil }
        var source = !personalMode ? ready?.persistence.configuration.stores.first?.url : nil
        if source != nil, let ready {
            let store = RetiringStore(persistence: ready.persistence)
            let empty = try await Task.detached(priority: .userInitiated) {
                try store.persistence.writer.performAndWait {
                    for entity in store.persistence.container.managedObjectModel.entities {
                        guard let name = entity.name, !entity.isAbstract else { continue }
                        let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                        request.fetchLimit = 1
                        if try store.persistence.writer.count(for: request) > 0 { return false }
                    }
                    return true
                }
            }.value
            if empty { source = nil }
        }
        let name = currentHomeName ?? "This device’s home"
        let base = try await resolvedAccountDirectory()
        let provider = try await resolvedAccountProvider(base: base)
        await provider.refresh()
        let session = try verifiedSession(provider)
        let householdID = ready?.householdID
        let listID = ready?.listID
        let sourceURL = source
        let proposal = try await Task.detached(priority: .userInitiated) {
            try HomeAdoptionJournal(baseDirectory: base).prepare(sourceURL: sourceURL, session: session,
                householdID: householdID, listID: listID, homeName: name)
        }.value
        guard generation == capturedGeneration, transition == nil,
              try verifiedSession(provider) == session,
              ready?.presentation.isActive != false else { throw HomeAdoptionJournal.Failure.staleProposal }
        configureInvitations()
        return InvitationSetupChoice(proposal: proposal, presentationID: ready?.presentation.id,
            generation: capturedGeneration)
    }

    func confirmInvitationSetup(_ choice: InvitationSetupChoice, copyLocal: Bool,
                                joiningInvitationID: UUID? = nil) async throws {
        guard !accountLoadInProgress, transition == nil, generation == choice.generation,
              let provider = accountProvider,
              try verifiedSession(provider) == choice.proposal.session else { throw ShopperSessionError.accountChanged }
        if let id = choice.presentationID {
            guard case .ready(let ready) = state, ready.presentation.id == id,
                  ready.presentation.isActive else { throw HomeAdoptionJournal.Failure.staleProposal }
        }
        accountLoadInProgress = true
        do {
            let base = try await resolvedAccountDirectory()
            let proposal = choice.proposal
            if proposal.sourceURL != nil {
                _ = try await Task.detached(priority: .userInitiated) {
                    try HomeAdoptionJournal(baseDirectory: base).approve(proposal, action: copyLocal ? .copy : .keepLocal)
                }.value
            } else if copyLocal { throw HomeAdoptionJournal.Failure.copyUnavailable }
            guard generation == choice.generation, transition == nil,
                  try verifiedSession(provider) == proposal.session else { throw ShopperSessionError.accountChanged }
            if let joiningInvitationID {
                guard invitations?.allEntries.contains(where: {
                    $0.id == joiningInvitationID && $0.openRequested && !$0.activationResolved
                        && ($0.session == nil || $0.session == proposal.session)
                }) == true else { throw HomeAdoptionJournal.Failure.staleProposal }
            }
            // Intent is durable before the UI retires or the restart preference changes.
            personalMode = true
            defaults.set(true, forKey: Self.personalModeKey)
            beginTransition { [weak self] in self?.openPersonalStore(expectedSession: proposal.session) }
        } catch {
            accountLoadInProgress = false
            throw error
        }
    }

    /// Joining keeps legacy groceries on this device under the existing durable
    /// adoption journal. A separate migration remains an explicit later action.
    func connectForJoiningKeepingLocalHome(invitationID: UUID? = nil) async throws {
        guard requiresHomeAccountSetup else { return }
        if let invitationID {
            guard invitations?.allEntries.contains(where: { $0.id == invitationID && $0.openRequested }) == true
                else { throw HomeAdoptionJournal.Failure.staleProposal }
        }
        if case .ready(let ready) = state, !personalMode, ready.householdID != nil {
            let capturedGeneration = generation
            let base = try await resolvedAccountDirectory()
            let provider = try await resolvedAccountProvider(base: base)
            await provider.refresh()
            let session = try verifiedSession(provider)
            let selected = try await selectedLocalSource(ready, session: session)
            let prior = try await Task.detached(priority: .userInitiated) {
                try HomeAdoptionJournal(baseDirectory: base).verifiedRecord()
            }.value
            guard generation == capturedGeneration, transition == nil, ready.presentation.isActive,
                  try verifiedSession(provider) == session,
                  invitationID == nil || invitations?.allEntries.contains(where: {
                      $0.id == invitationID && $0.openRequested && !$0.activationResolved
                  }) == true else { throw HomeAdoptionJournal.Failure.staleProposal }
            if let prior, prior.session != session || prior.householdID != selected.graph.householdID
                || prior.listID != selected.graph.listID
                || prior.sourceURL?.standardizedFileURL != selected.sourceURL.standardizedFileURL
                || prior.proposal.sourceStoreIdentifier != selected.graph.storeIdentifier {
                // Old adoption evidence cannot approve a new selected graph.
                try await Task.detached(priority: .userInitiated) {
                    try DeviceLocalHomeSelectionJournal(baseDirectory: base).select(selected)
                }.value
                guard generation == capturedGeneration, transition == nil, ready.presentation.isActive,
                      try verifiedSession(provider) == session,
                      invitationID == nil || invitations?.allEntries.contains(where: {
                          $0.id == invitationID && $0.openRequested && !$0.activationResolved
                              && ($0.session == nil || $0.session == session)
                      }) == true else { throw HomeAdoptionJournal.Failure.staleProposal }
                deviceLocalHome = .selected(selected)
                retainedLocalHomeName = selected.homeName
                accountLoadInProgress = true
                personalMode = true
                defaults.set(true, forKey: Self.personalModeKey)
                beginTransition { [weak self] in self?.openPersonalStore(expectedSession: session) }
                return
            }
        }
        let choice = try await prepareInvitationSetup()
        try await confirmInvitationSetup(choice, copyLocal: false, joiningInvitationID: invitationID)
    }

    private func openPersonalStore(expectedSession: ShopperSession? = nil) {
        Task {
            defer {
                accountLoadInProgress = false
                scheduleLocalReturnAfterDismiss()
            }
            do {
                let base = try await resolvedAccountDirectory()
                let provider = try await resolvedAccountProvider(base: base)
                await provider.refresh()
                let session = try provider.currentSession()
                if let expectedSession {
                    guard try verifiedSession(provider) == expectedSession else { throw ShopperSessionError.accountChanged }
                }
                let activate = activateAccountStore
                let legacyPendingSource = defaults.string(forKey: Self.pendingImportKey).map { URL(fileURLWithPath: $0) }
                let journalRecord = try await Task.detached(priority: .userInitiated) {
                    try HomeAdoptionJournal(baseDirectory: base).record(session: session)
                }.value
                if let legacyPendingSource, journalRecord == nil {
                    // Older versions persisted only a path, with no approved account identity.
                    // Reopen it intact so the user can approve the newly verified account.
                    try await Task.detached(priority: .userInitiated) {
                        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                            at: legacyPendingSource, options: [NSReadOnlyPersistentStoreOption: true])
                        guard let identifier = metadata[NSStoreUUIDKey] as? String, UUID(uuidString: identifier) != nil else {
                            throw HomeAdoptionJournal.Failure.sourceChanged
                        }
                    }.value
                    guard try provider.currentSession() == session else { throw ShopperSessionError.accountChanged }
                    personalMode = false
                    defaults.set(false, forKey: Self.personalModeKey)
                    personalConfiguration = nil
                    retainedLocalConfiguration = .local(storeURL: legacyPendingSource)
                    load()
                    return
                }
                let (activated, deviceLocalRecord, deviceLocalName) = try await Task.detached(priority: .userInitiated) {
                    let journal = HomeAdoptionJournal(baseDirectory: base)
                    // A legacy path alone is not permission to import into the current account.
                    if let record = try journal.record(session: session), !record.verified {
                        guard case .ready(let verified) = provider.state, verified == session else {
                            throw ShopperSessionError.setupRequired
                        }
                    }
                    let activated = try journal.activate(session: session, using: activate)
                    // Account activation and device-local presentation have
                    // different authority. A verified kept source stays visible
                    // after switching accounts without authorizing an account copy.
                    let local = try Self.readDeviceLocalHome(base: base)
                    return (activated, local, try local.map(Self.currentDeviceLocalName))
                }.value
                guard try provider.currentSession() == session else { throw ShopperSessionError.accountChanged }
                personalConfiguration = activated.configuration
                deviceLocalHome = deviceLocalRecord
                retainedLocalHomeName = deviceLocalName
                if let retained = deviceLocalRecord {
                    let saved = try await Task.detached(priority: .userInitiated) {
                        let journal = RetainedHomeConversionJournal(baseDirectory: base, session: retained.session)
                        let command = try Self.conversion(for: retained, base: base)
                        return try command.map { ($0, try journal.wasDestinationDeleted($0)) }
                    }.value
                    retainedLocalCopyState = saved?.0.copied == true
                        ? (saved?.1 == true ? .available : .copied)
                        : saved == nil ? .available : .copying
                } else { retainedLocalCopyState = .unavailable }
                retainedLocalConfiguration = nil
                isShowingRetainedLocalHome = false
                defaults.set(false, forKey: Self.retainedLocalKey)
                if let householdID = activated.preferredHouseholdID, let listID = activated.preferredListID {
                    preferredAdoptedHome = (householdID, listID)
                } else { preferredAdoptedHome = nil }
                activeAccountBinding = session.accountBinding
                personalMode = true
                defaults.set(true, forKey: Self.personalModeKey)
                defaults.removeObject(forKey: Self.pendingImportKey)
                load()
            } catch { state = .failed(error) }
        }
    }

    func openRetainedLocalHome(expectedSelectionGeneration: UInt64? = nil,
                               expectedPresentationID: UUID? = nil) async throws {
        guard !accountLoadInProgress, transition == nil, let record = deviceLocalHome,
              let source = record.sourceURL else { throw HomeAdoptionJournal.Failure.staleProposal }
        let capturedGeneration = generation
        if let expectedSelectionGeneration {
            guard homeCoordinator.generation == expectedSelectionGeneration,
                  homeCoordinator.activeScope == nil else { throw HomeAdoptionJournal.Failure.staleProposal }
        }
        if let expectedPresentationID {
            guard case .ready(let ready) = state,
                  ready.presentation.id == expectedPresentationID else { throw HomeAdoptionJournal.Failure.staleProposal }
        }
        if let session = try? accountProvider?.currentSession() {
            try await deferAutomaticInvitationOpens(for: session)
        }
        let base = try await resolvedAccountDirectory()
        try await Task.detached(priority: .userInitiated) {
            try Self.validateDeviceLocalHome(record, base: base)
        }.value
        let savedConversion = try await Task.detached(priority: .userInitiated) {
            let journal = RetainedHomeConversionJournal(baseDirectory: base, session: record.session)
            let command = try Self.conversion(for: record, base: base)
            return try command.map { ($0, try journal.wasDestinationDeleted($0)) }
        }.value
        guard generation == capturedGeneration, transition == nil,
              expectedSelectionGeneration == nil || homeCoordinator.generation == expectedSelectionGeneration,
              expectedSelectionGeneration == nil || homeCoordinator.activeScope == nil else {
            throw HomeAdoptionJournal.Failure.staleProposal
        }
        if let expectedPresentationID {
            guard case .ready(let ready) = state,
                  ready.presentation.id == expectedPresentationID else { throw HomeAdoptionJournal.Failure.staleProposal }
        }
        retainedLocalConfiguration = .local(storeURL: source)
        personalConfiguration = nil
        preferredAdoptedHome = nil
        retainedConversionSelectionIntent = nil
        retainedConversionChoiceGeneration = nil
        personalMode = false
        isShowingRetainedLocalHome = true
        retainedLocalCopyState = savedConversion?.0.copied == true && savedConversion?.1 == false
            ? .copied : .available
        defaults.set(true, forKey: Self.retainedLocalKey)
        defaults.set(false, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.load() }
    }

    func connectBackToAccount() async throws {
        guard !accountLoadInProgress, transition == nil, isShowingRetainedLocalHome,
              deviceLocalHome != nil else { throw HomeAdoptionJournal.Failure.staleProposal }
        let capturedGeneration = generation
        let base = try await resolvedAccountDirectory()
        let provider = try await resolvedAccountProvider(base: base)
        await provider.refresh()
        let session = try verifiedSession(provider)
        guard generation == capturedGeneration, transition == nil, !accountLoadInProgress,
              isShowingRetainedLocalHome else { throw ShopperSessionError.accountChanged }
        accountLoadInProgress = true
        personalMode = true
        defaults.set(true, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.openPersonalStore(expectedSession: session) }
    }

    // MARK: Retained local conversion

    /// Replays a pending deletion of the retained source even while another
    /// account store is mounted. Only the exact journaled source graph is opened.
    func retainedLocalDeletionStatuses(reconcile: Bool) async throws -> [HomeDeletionStatus] {
        guard let record = deviceLocalHome,
              let sourceURL = record.sourceURL,
              let sourceStoreID = record.storeIdentifier,
              let householdID = record.householdID, let listID = record.listID else { return [] }
        if case .ready(let ready) = state,
           ready.persistence.primaryStore?.url?.standardizedFileURL == sourceURL.standardizedFileURL {
            return [] // The mounted local deletion service already owns this store.
        }
        let capturedGeneration = generation
        let base = try await resolvedAccountDirectory()
        let retained = record
        let statuses = try await Task.detached(priority: .userInitiated) {
            let journal = LocalHomeDeletionJournal(storeURL: sourceURL)
            let matches: (HomeDeletionStatus) -> Bool = {
                $0.command.graph.storeIdentifier == sourceStoreID
                    && $0.command.graph.householdID == householdID
                    && $0.command.graph.listID == listID
            }
            let initial = try journal.statuses().filter(matches)
            guard reconcile, initial.contains(where: { !$0.completed }) else { return initial }
            try Self.validateDeviceLocalHome(retained, base: base)
            let persistence = try PersistenceController(storeURL: sourceURL)
            defer {
                persistence.writer.performAndWait { persistence.writer.reset() }
                for store in persistence.container.persistentStoreCoordinator.persistentStores {
                    try? persistence.container.persistentStoreCoordinator.remove(store)
                }
            }
            guard persistence.primaryStore?.identifier == sourceStoreID else {
                throw HomeAdoptionJournal.Failure.sourceChanged
            }
            let service = HomeDeletionService(persistence: persistence)
            for status in initial where !status.completed {
                _ = try await service.reconcile(status.command)
            }
            return try await service.statuses().filter(matches)
        }.value
        guard generation == capturedGeneration, deviceLocalHome == record else { return [] }
        return statuses
    }

    /// Deletion supplies proof from the private ledger. Persist only completed
    /// exact destination tombstones so local Settings may offer a new copy.
    func recordCompletedRetainedHomeDeletions(_ statuses: [HomeDeletionStatus]) async {
        guard let retained = deviceLocalHome, let provider = accountProvider,
              let session = try? verifiedSession(provider), session == retained.session,
              let base = try? await resolvedAccountDirectory() else { return }
        let completed = statuses.filter { status in
            guard status.completed, let scope = status.command.scope else { return false }
            return scope.accountBinding == session.accountBinding
                && scope.containerIdentifier == session.containerIdentifier
                && scope.environment == session.environment
        }
        guard !completed.isEmpty else { return }
        do {
            let latest = try await Task.detached(priority: .userInitiated) {
                let journal = RetainedHomeConversionJournal(baseDirectory: base, session: session)
                for status in completed {
                    try status.command.validate()
                    let graph = status.command.graph
                    try journal.noteCompletedDeletion(session: session,
                        storeIdentifier: graph.storeIdentifier,
                        householdID: graph.householdID, listID: graph.listID)
                }
                return try Self.conversion(for: retained, base: base)
            }.value
            if let latest {
                let journal = RetainedHomeConversionJournal(baseDirectory: base, session: session)
                let deleted = try await Task.detached(priority: .userInitiated) {
                    try journal.wasDestinationDeleted(latest)
                }.value
                retainedLocalCopyState = deleted ? .available : latest.copied ? .copied : .copying
            }
        } catch { homeSetupError = error }
    }

    /// An explicit copy of the selected local graph, independent of any old
    /// account-adoption decision for another graph in the same SQLite store.
    func useICloudForRetainedLocalHome() async throws {
        guard isShowingRetainedLocalHome, let home = deviceLocalHome else {
            throw HomeAdoptionJournal.Failure.staleProposal
        }
        if retainedLocalCopyState == .copied {
            let base = try await resolvedAccountDirectory()
            let provider = try await resolvedAccountProvider(base: base)
            await provider.refresh()
            guard try verifiedSession(provider) == home.session else { throw ShopperSessionError.accountChanged }
            try await connectBackToAccount()
            return
        }
        try await copySelectedLocalHome(expectedHome: home)
    }

    func useICloudForLocalHome() async throws {
        guard !isShowingRetainedLocalHome else { throw HomeAdoptionJournal.Failure.staleProposal }
        try await copySelectedLocalHome(expectedHome: nil)
    }

    private func selectedLocalSource(_ ready: ReadyState, session: ShopperSession)
        async throws -> DeviceLocalHomeSelection {
        guard let householdID = ready.householdID, let listID = ready.listID,
              let store = ready.persistence.store(for: .local), let sourceURL = store.url,
              let storeIdentifier = store.identifier else { throw HomeAdoptionJournal.Failure.staleProposal }
        let source = RetiringStore(persistence: ready.persistence)
        let home = try await Task.detached(priority: .userInitiated) {
            let discovery = try HomeDiscoveryService(persistence: source.persistence).discover()
            guard let home = discovery.homes.first(where: {
                $0.graph.storeIdentifier == storeIdentifier && $0.graph.householdID == householdID
                    && $0.graph.listID == listID
            }) else { throw RetainedHomeConversionJournal.Failure.sourceChanged }
            return home
        }.value
        return DeviceLocalHomeSelection(sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
            graph: home.graph,
            homeName: home.name, session: session, conversionID: nil)
    }

    private func copySelectedLocalHome(expectedHome: DeviceLocalHome?) async throws {
        guard !accountLoadInProgress, transition == nil,
              case .ready(let ready) = state, ready.presentation.isActive,
              let householdID = ready.householdID, let listID = ready.listID,
              let storeIdentifier = ready.persistence.store(for: .local)?.identifier,
              expectedHome == nil || deviceLocalHome == expectedHome,
              expectedHome == nil || (expectedHome?.householdID == householdID
                  && expectedHome?.listID == listID && expectedHome?.storeIdentifier == storeIdentifier) else {
            throw HomeAdoptionJournal.Failure.staleProposal
        }
        let capturedGeneration = generation
        let base = try await resolvedAccountDirectory()
        let provider = try await resolvedAccountProvider(base: base)
        await provider.refresh()
        let session = try verifiedSession(provider)
        if let expectedHome { guard session == expectedHome.session else { throw ShopperSessionError.accountChanged } }
        let source = RetiringStore(persistence: ready.persistence)
        let selectedSource = try await selectedLocalSource(ready, session: session)
        let graph = selectedSource.graph
        let proposed = try await Task.detached(priority: .userInitiated) {
            let service = RetainedHomeConversionService(persistence: source.persistence)
            if case .adopted(let record) = expectedHome {
                try HomeAdoptionJournal(baseDirectory: base).validateRetainedSource(record)
                return try service.capture(record: record, session: session)
            }
            return try service.captureLocal(graph: graph, session: session)
        }.value
        guard generation == capturedGeneration, transition == nil, ready.presentation.isActive,
              try verifiedSession(provider) == session else { throw HomeAdoptionJournal.Failure.staleProposal }
        let command = try await Task.detached(priority: .userInitiated) {
            try RetainedHomeConversionJournal(baseDirectory: base, session: session).begin(proposed)
        }.value
        guard generation == capturedGeneration, transition == nil,
              ready.presentation.isActive, try verifiedSession(provider) == session else {
            throw HomeAdoptionJournal.Failure.staleProposal
        }
        if case .adopted = expectedHome {
            // The verified adoption record remains the source of this local route.
        } else {
            var selected = selectedSource
            selected.conversionID = command.id
            try await Task.detached(priority: .userInitiated) {
                try DeviceLocalHomeSelectionJournal(baseDirectory: base).select(selected)
            }.value
            guard generation == capturedGeneration, transition == nil,
                  ready.presentation.isActive, try verifiedSession(provider) == session else {
                throw HomeAdoptionJournal.Failure.staleProposal
            }
            deviceLocalHome = .selected(selected)
            retainedLocalHomeName = selected.homeName
        }
        homeSetupError = nil
        retainedLocalCopyState = command.copied ? .copied : .copying
        retainedConversionSelectionIntent = command.copied ? nil : command.id
        retainedConversionChoiceGeneration = nil
        accountLoadInProgress = true
        personalMode = true
        defaults.set(true, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.openPersonalStore(expectedSession: session) }
    }

    private func resumeRetainedLocalConversion(_ retained: DeviceLocalHome,
                                               in persistence: PersistenceController) async {
        guard let provider = accountProvider, let session = try? verifiedSession(provider),
              session == retained.session else { return }
        let base: URL
        do { base = try await resolvedAccountDirectory() }
        catch { homeSetupError = error; return }
        let journal = RetainedHomeConversionJournal(baseDirectory: base, session: session)
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try Self.conversion(for: retained, base: base)
            }.value
            guard let pending = saved else {
                retainedLocalCopyState = .available
                return
            }
            guard pending.retainedRecordID == retained.adoptionRecordID,
                  pending.sourceURL == retained.sourceURL,
                  pending.sourceStoreIdentifier == retained.storeIdentifier,
                  pending.sourceGraph.householdID == retained.householdID,
                  pending.sourceGraph.listID == retained.listID else {
                throw RetainedHomeConversionJournal.Failure.sourceChanged
            }
            let destinationDeleted = try await Task.detached(priority: .userInitiated) {
                try journal.wasDestinationDeleted(pending)
            }.value
            if destinationDeleted {
                retainedLocalCopyState = .available
                return
            }
            if pending.copied {
                retainedLocalCopyState = .copied
                return
            }
            guard retainedConversionResumingID == nil,
                  case .ready(let ready) = state, ready.persistence === persistence,
                  ready.presentation.isActive,
                  let store = persistence.primaryStore, let storeIdentifier = store.identifier,
                  persistence.role(of: store) == .ownerPrivate
                    || (!persistence.configuration.isManaged && persistence.role(of: store) == .local) else { return }
            retainedConversionResumingID = pending.id
            defer { retainedConversionResumingID = nil }
            retainedLocalCopyState = .copying
            let choiceGeneration = retainedConversionChoiceGeneration
            let capturedPresentationID = ready.presentation.id
            let target = RetiringStore(persistence: persistence)
            let bound = try await Task.detached(priority: .userInitiated) {
                try Self.validateDeviceLocalHome(retained, base: base)
                let bound = try journal.bind(pending, to: storeIdentifier)
                try RetainedHomeConversionService(persistence: target.persistence).apply(bound)
                try journal.markCopied(bound)
                return bound
            }.value
            retainedLocalCopyState = .copied
            homeSetupError = nil
            guard case .ready(let current) = state,
                  current.presentation.id == capturedPresentationID,
                  current.presentation.isActive,
                  try provider.currentSession() == session else { return }
            do {
                try await refreshHomes()
                if retainedConversionSelectionIntent == bound.id,
                   choiceGeneration != nil,
                   homeCoordinator.generation == choiceGeneration,
                   let copied = homeCoordinator.homes.first(where: {
                       $0.graph.householdID == bound.graph.householdID
                           && $0.graph.listID == bound.graph.listID && $0.access == .owner
                           && $0.graph.storeIdentifier == storeIdentifier
                   }) {
                    try await selectHome(copied.graph)
                }
            } catch {
                // The atomic copy is complete; normal home discovery can recover its row.
            }
            retainedConversionSelectionIntent = nil
            retainedConversionChoiceGeneration = nil
        } catch {
            retainedLocalCopyState = .available
            retainedConversionSelectionIntent = nil
            retainedConversionChoiceGeneration = nil
            homeSetupError = error
        }
    }

    private func accountStateChanged() {
        objectWillChange.send()
        guard personalMode, let accountProvider, !accountLoadInProgress else { return }
        switch accountPresentationChange(using: accountProvider) {
        case .unchanged: break
        case .reopen: activatePersonalCarts(importLegacy: false)
        case .unavailable(let error): retireAndFail(error)
        }
    }

    // Account resolution decides authority; the foreground coordinator owns
    // presentation retirement and asynchronous store opening.
    private func accountPresentationChange(using provider: ShopperSessionProvider) -> AccountPresentationChange {
        // CloudKit reports account-status changes before a replacement identity
        // is known. Retire first, then perform one coalesced verified reopen.
        // An invalidated cached identity never authorizes that reopen.
        if case .accountChanged = provider.state { return .reopen }
        do {
            let session = try provider.currentSession()
            return session.accountBinding == activeAccountBinding ? .unchanged : .reopen
        } catch {
            return .unavailable(error)
        }
    }

    private func detachStores(_ previous: ReadyState?) async throws {
        generation += 1
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver); self.remoteObserver = nil }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver); self.associationObserver = nil }
        historyConsumer = nil
        associationWorker = nil
        homeAccessRefreshID = nil
        personalService = nil
        pendingShareAssociationCount = 0
        associationCountKnown = false
        shareAssociationError = nil
        cartResumeError = nil
        homeDiscoveryError = nil
        homeSetupError = nil
        clearSharingStatusPresentation()
        clearHomeLeavePresentation()
        cloudMonitor.reset()
        if let ready = previous {
            ready.persistence.container.viewContext.reset()
            let retiring = RetiringStore(persistence: ready.persistence)
            try await Task.detached(priority: .utility) {
                let writer = retiring.persistence.writer
                writer.performAndWait { writer.reset() }
                let coordinator = retiring.persistence.container.persistentStoreCoordinator
                for store in coordinator.persistentStores { try coordinator.remove(store) }
            }.value
        }
        activeAccountBinding = nil
    }

    private func load() {
        guard preloadedPreviewEnvironment == nil else { finishLoad(prepared: nil); return }
        let requestedGeneration = generation
        let configuration = self.configuration
        let personalConfiguration = personalMode ? self.personalConfiguration : retainedLocalConfiguration
        let accountProvider = self.accountProvider
        let personalMode = self.personalMode
        let deviceLocalHome = self.deviceLocalHome
        let session = personalMode ? (try? accountProvider?.currentSession()) : nil
        homeCoordinator.bind(session)
        configureInvitations()
        let discoveryRequest = homeCoordinator.beginDiscovery()
        Task {
            do {
                if !personalMode, let deviceLocalHome {
                    let base = try await resolvedAccountDirectory()
                    try await Task.detached(priority: .userInitiated) {
                        try Self.validateDeviceLocalHome(deviceLocalHome, base: base)
                    }.value
                    guard generation == requestedGeneration else { return }
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let resolved = try personalConfiguration ?? configuration()
                    let persistence = try PersistenceController(configuration: resolved)
                    let service = NeedService(persistence: persistence)
                    var discovery = try HomeDiscoveryService(persistence: persistence).discover()
                    var selection = discovery.homes.count == 1 && !discovery.hasIncompleteRoots
                        ? discovery.homes.first.map { (householdID: $0.graph.householdID, listID: $0.graph.listID) } : nil
                    if !personalMode, let deviceLocalHome,
                       let home = discovery.homes.first(where: {
                           $0.graph.householdID == deviceLocalHome.householdID
                               && $0.graph.listID == deviceLocalHome.listID
                       }) {
                        selection = (home.graph.householdID, home.graph.listID)
                    }
                    var cartService: PersonalCartService?
                    let resumeError: String? = nil
                    if personalMode, let accountProvider {
                        let cart = PersonalCartService(persistence: persistence, sessionProvider: accountProvider)
                        try cart.captureLegacyReview()
                        cartService = cart
                        discovery = try HomeDiscoveryService(persistence: persistence).discover()
                    }
                    return PreparedStore(configuration: resolved, persistence: persistence,
                        service: service, selection: selection, personalCartService: cartService,
                        resumeError: resumeError, homeDiscovery: discovery)
                }.value
                guard generation == requestedGeneration else { return }
                if personalMode, try accountProvider?.currentSession() != session {
                    throw ShopperSessionError.accountChanged
                }
                if let discoveryRequest {
                    guard homeCoordinator.reconcile(prepared.homeDiscovery, request: discoveryRequest) else { return }
                    if homeCoordinator.activeScope == nil, homeCoordinator.readiness != .selectedHomeUnavailable,
                       let preferred = preferredAdoptedHome,
                       let home = prepared.homeDiscovery.homes.first(where: {
                           $0.graph.householdID == preferred.householdID && $0.graph.listID == preferred.listID
                       }) {
                        try homeCoordinator.select(home.graph)
                    }
                    preferredAdoptedHome = nil
                }
                finishLoad(prepared: prepared)
            } catch {
                guard generation == requestedGeneration else { return }
                state = .failed(error)
            }
        }
    }

    private func finishLoad(prepared: PreparedStore?) {
        do {
            let resolvedConfiguration: PersistenceConfiguration
            let persistence: PersistenceController
            let service: NeedService
            var selection: (householdID: UUID, listID: UUID)?
            let isFreshPreview = preloadedPreviewEnvironment != nil
            if let preview = preloadedPreviewEnvironment {
                resolvedConfiguration = preview.persistence.configuration
                persistence = preview.persistence
                service = preview.service
                selection = (preview.ids.householdID, preview.ids.listID)
                preloadedPreviewEnvironment = nil
            } else if let prepared {
                resolvedConfiguration = prepared.configuration
                persistence = prepared.persistence
                service = prepared.service
                if personalMode {
                    selection = homeCoordinator.activeScope.map { ($0.graph.householdID, $0.graph.listID) }
                } else { selection = prepared.selection }
                localHomeName = prepared.homeDiscovery.homes.first {
                    $0.graph.householdID == selection?.householdID && $0.graph.listID == selection?.listID
                }?.name
                localDiscoveryComplete = !prepared.homeDiscovery.hasIncompleteRoots
                personalService = prepared.personalCartService
                if let resumeError = prepared.resumeError {
                    cartResumeError = NSError(domain: "ShoppingCartResume", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: resumeError])
                }
            } else {
                preconditionFailure("A non-preview store must be prepared off the main actor")
            }
#if DEBUG
            if personalFixture {
                personalService = PersonalCartService(persistence: persistence,
                    sessionProvider: try PersonalCartFixtureSessionProvider())
                try personalService?.captureLegacyReview()
                if personalNoticeFixture, isFreshPreview, let selection, let owner = personalService {
                    let request = Need.fetchRequest()
                    request.predicate = NSPredicate(format: "item.name == %@", "Granola")
                    if let need = try persistence.container.viewContext.fetch(request).first {
                        try owner.cart(needID: need.id, householdID: selection.householdID, listID: selection.listID)
                        let other = PersonalCartService(persistence: persistence,
                            sessionProvider: try PersonalCartFixtureSessionProvider(shopper: "other-preview-shopper"))
                        try other.cart(needID: need.id, householdID: selection.householdID, listID: selection.listID)
                        let token = try other.prepareCheckout(tokens: other.entries(householdID: selection.householdID,
                            listID: selection.listID).map(\.token))
                        _ = try other.checkout(token)
                        personalService = PersonalCartService(persistence: persistence,
                            sessionProvider: try PersonalCartFixtureSessionProvider())
                    }
                }
                if personalRevokedFixture, isFreshPreview, let selected = selection, let owner = personalService {
                    let context = persistence.container.viewContext
                    let request = Need.fetchRequest()
                    request.predicate = NSPredicate(format: "item.name == %@", "Granola")
                    if let need = try context.fetch(request).first, let household = need.list?.household {
                        try owner.cart(needID: need.id, householdID: selected.householdID, listID: selected.listID)
                        context.delete(household)
                        try context.save()
                        selection = nil
                    }
                }
            }
#endif
            if prepared == nil, personalMode, let accountProvider {
                let cartService = PersonalCartService(persistence: persistence, sessionProvider: accountProvider)
                try cartService.captureLegacyReview()
                personalService = cartService

            }
            if Self.consumesPersistentHistory(for: resolvedConfiguration) {
                let checkpointDirectory = (resolvedConfiguration.stores.first?.url?.deletingLastPathComponent())
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShoppingHistory")
                historyConsumer = PersistentHistoryConsumer(
                    persistence: persistence,
                    checkpoints: FileHistoryCheckpointStore(directory: checkpointDirectory)
                )
                installRemoteObserver(for: persistence)
            } else {
                historyConsumer = nil
                if let remoteObserver {
                    NotificationCenter.default.removeObserver(remoteObserver)
                    self.remoteObserver = nil
                }
            }
            cloudMonitor.attach(to: persistence.container)
            if let journal = persistence.shareAssociationJournal {
                associationWorker = ManagedShareAssociationWorker(persistence: persistence, journal: journal)
            }
            installAssociationObserver(for: persistence)
            let resolveFirstAccount = autoResolveFreshAccount && !personalMode && !isShowingRetainedLocalHome
                && selection == nil && localDiscoveryComplete && prepared != nil
                && persistence.primaryStore?.type == NSSQLiteStoreType
            isResolvingFirstAccount = resolveFirstAccount
            state = .ready(ReadyState(
                persistence: persistence,
                service: service,
                householdID: selection?.householdID,
                listID: selection?.listID,
                homeScope: homeCoordinator.activeScope,
                homeGeneration: homeCoordinator.generation,
                personalCartService: personalService
            ))
            if retainedConversionSelectionIntent != nil {
                retainedConversionChoiceGeneration = homeCoordinator.generation
            }
            configureInvitations()
            if personalMode, let retained = deviceLocalHome {
                Task { await resumeRetainedLocalConversion(retained, in: persistence) }
            }
            scheduleAutomaticJoinConnection()
            scheduleLocalReturnAfterDismiss()
            if resolveFirstAccount, case .ready(let ready) = state {
                Task { await resolveFirstAccountIfAvailable(ready) }
            }
            resumePendingCart()
            consumeHistory()
            retryShareAssociations()
        } catch {
            state = .failed(error)
        }
    }

    private func resolveFirstAccountIfAvailable(_ ready: ReadyState) async {
        let capturedGeneration = generation
        do {
            let service = ready.service
            let empty = try await Task.detached(priority: .utility) {
                try service.isPersistentStoreEmpty()
            }.value
            guard generation == capturedGeneration, ready.presentation.isActive,
                  case .ready(let current) = state, current.presentation.id == ready.presentation.id else { return }
            guard empty else {
                isResolvingFirstAccount = false
                scheduleAutomaticJoinConnection()
                return
            }
            let choice = try await prepareInvitationSetup()
            try await confirmInvitationSetup(choice, copyLocal: false)
        } catch {
            guard generation == capturedGeneration, ready.presentation.isActive else { return }
            // An unavailable account leaves explicit local creation usable.
            isResolvingFirstAccount = false
            if invitations?.hasPendingActivation == true { joinError = error.localizedDescription }
            scheduleAutomaticJoinConnection()
        }
    }

    private func installRemoteObserver(for persistence: PersistenceController) {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.consumeHistory() }
        }
    }

    static func consumesPersistentHistory(for configuration: PersistenceConfiguration) -> Bool {
        configuration.isManaged
    }

    private func installAssociationObserver(for persistence: PersistenceController) {
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
        associationObserver = NotificationCenter.default.addObserver(
            forName: PersistenceController.pendingShareAssociation,
            object: persistence,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.retryShareAssociations() }
        }
    }

    private func consumeHistory() {
        guard let historyConsumer else { return }
        let requestedGeneration = generation
        Task {
            do {
                let imported = try await historyConsumer.consumeSummary()
                guard generation == requestedGeneration else { return }
                if case .ready(let ready) = state {
                    ready.persistence.homeNativeAccess.applyImportedHistory(imported)
                }
                try await refreshHomes()
                if imported.requiresAccessRefresh { resumePendingCart(recheckIfRunning: true) }
                if case .ready(let ready) = state { ready.personalCart?.refresh() }
            } catch {
                guard generation == requestedGeneration else { return }
                retireAndFail(error)
            }
        }
    }

    func refreshHomes() async throws {
        guard case .ready(let ready) = state,
              invitationDiscoveryReservations[ready.presentation.id] == nil,
              let request = homeCoordinator.beginDiscovery() else { return }
        let requestedGeneration = generation
        let discovery = HomeDiscoveryService(persistence: ready.persistence)
        let snapshot: HomeDiscovery
        do { snapshot = try await discoverHomes(discovery) }
        catch {
            guard generation == requestedGeneration, ready.presentation.isActive,
                  invitationDiscoveryReservations[ready.presentation.id] == nil,
                  homeCoordinator.isCurrent(request),
                  (try? accountProvider?.currentSession()) == request.sessionForValidation else { return }
            homeDiscoveryError = error
            throw error
        }
        guard generation == requestedGeneration, ready.presentation.isActive,
              invitationDiscoveryReservations[ready.presentation.id] == nil,
              homeCoordinator.isCurrent(request),
              try accountProvider?.currentSession() == request.sessionForValidation else { return }
        homeDiscoveryError = nil
        if homeCoordinator.reconcile(snapshot, request: request) { applyHomeSelection(to: ready) }
        configureInvitations()
    }

    private func configureInvitations() {
        guard let invitations else { return }
        var verifiedSession: ShopperSession?
        if case .ready(let session) = accountProvider?.state { verifiedSession = session }
        if let session = verifiedSession, case .ready(let ready) = state,
           ready.persistence.personalCartInitialBinding == session.accountBinding,
           let store = ready.persistence.store(for: .participantShared) {
            invitations.configure(session: session, sharedStoreIdentifier: store.identifier,
                transport: ManagedHomeInvitationTransport(persistence: ready.persistence, session: session, cart: personalService))
        } else { invitations.configure(session: verifiedSession) }
        homeCoordinator.setInvitationPending(invitations.hasPendingActivation)
        scheduleAutomaticJoinConnection()
        scheduleAutomaticInvitationOpen()
    }

    private func scheduleAutomaticJoinConnection() {
        guard autoJoinInvitations, !personalMode, !isResolvingFirstAccount, !accountLoadInProgress,
              transition == nil,
              case .ready(let ready) = state, ready.presentation.isActive,
              let entry = invitations?.entries.first(where: {
                  $0.openRequested && !autoConnectionAttemptedFor.contains($0.id)
              }) else { return }
        autoConnectionAttemptedFor.insert(entry.id)
        captureLocalJoinOrigin(entry.id, ready: ready)
        automaticJoinConnectionTasks[entry.id] = Task {
            defer { automaticJoinConnectionTasks.removeValue(forKey: entry.id) }
            do {
                try await connectForJoiningKeepingLocalHome(invitationID: entry.id)
                joinError = nil
            } catch {
                if invitations?.allEntries.first(where: { $0.id == entry.id })?.openRequested == true {
                    joinError = error.localizedDescription
                }
            }
        }
    }

    /// Lets recovery tests await the actual invitation connection they held.
    func automaticJoinConnectionTask(for id: UUID) -> Task<Void, Never>? {
        automaticJoinConnectionTasks[id]
    }

    private func captureLocalJoinOrigin(_ id: UUID, ready: ReadyState) {
        guard !personalMode, let householdID = ready.householdID, let listID = ready.listID,
              let store = ready.persistence.primaryStore else { return }
        localJoinOrigin = LocalJoinOrigin(invitationID: id, storeIdentifier: store.identifier,
            householdID: householdID, listID: listID)
    }

    private func scheduleLocalReturnAfterDismiss() {
        guard let origin = localReturnAfterDismiss, personalMode, !accountLoadInProgress,
              transition == nil, case .ready(let ready) = state, ready.presentation.isActive,
              ready.householdID == nil, ready.homeScope == nil, homeCoordinator.activeScope == nil,
              let record = deviceLocalHome,
              record.storeIdentifier == origin.storeIdentifier,
              record.householdID == origin.householdID, record.listID == origin.listID,
              case .ready(let session) = accountProvider?.state, session == record.session,
              invitations?.allEntries.contains(where: {
                  $0.id != origin.invitationID && $0.openRequested && !$0.activationResolved
                      && ($0.session == nil || $0.session == session)
              }) != true else { return }
        let selectionGeneration = homeCoordinator.generation
        let presentationID = ready.presentation.id
        localReturnAfterDismiss = nil
        Task {
            do {
                try await openRetainedLocalHome(expectedSelectionGeneration: selectionGeneration,
                    expectedPresentationID: presentationID)
            } catch HomeAdoptionJournal.Failure.staleProposal {
                // A newer selection or store presentation owns navigation now.
            } catch { homeSetupError = error }
        }
    }

    private func scheduleAutomaticInvitationOpen() {
        guard autoJoinInvitations, autoOpeningInvitationID == nil, personalMode,
              case .ready(let ready) = state, ready.presentation.isActive,
              let invitations, let session = try? accountProvider?.currentSession() else { return }
        guard let entry = invitations.entries.last(where: {
            $0.openRequested && !$0.activationResolved && $0.session == session
        }), !autoOpenFailures.contains(entry.id), case .ready(let graph) = entry.state,
              homeCoordinator.homes.contains(where: { $0.graph == graph }) else { return }
        let selectionGeneration = homeCoordinator.generation
        autoOpeningInvitationID = entry.id
        Task {
            defer {
                autoOpeningInvitationID = nil
                scheduleAutomaticInvitationOpen()
            }
            do {
                // One accepted invitation owns automatic navigation. Earlier
                // accepted homes remain available through a deliberate Open.
                try await deferAutomaticInvitationOpens(for: session, except: entry.id)
                guard homeCoordinator.generation == selectionGeneration else {
                    throw HomeInvitationInbox.Error.invalidState
                }
                try await activateInvitedHome(entryID: entry.id, graph: graph,
                    expectedSelectionGeneration: selectionGeneration)
                joinError = nil
            } catch {
                if invitations.allEntries.first(where: { $0.id == entry.id })?.openRequested == true,
                   homeCoordinator.generation == selectionGeneration {
                    autoOpenFailures.insert(entry.id)
                    joinError = error.localizedDescription
                }
            }
        }
    }

    private func deferAutomaticInvitationOpens(for session: ShopperSession, except preservedID: UUID? = nil)
        async throws {
        guard let invitations else { return }
        for entry in invitations.allEntries where entry.openRequested && !entry.activationResolved
            && entry.session == session && entry.id != preservedID {
            try await invitations.deferOpen(entry.id, expectedSession: session)
        }
    }

    func joinInvitation(_ id: UUID) async throws {
        guard let invitations, let entry = invitations.entries.first(where: { $0.id == id }) else {
            throw HomeInvitationInbox.Error.invalidState
        }
        joinError = nil
        let wasFailed: Bool
        if case .failed = entry.state { wasFailed = true }
        else { wasFailed = false }
        let needsConnection = requiresHomeAccountSetup
        if needsConnection {
            autoConnectionAttemptedFor.insert(id)
            if case .ready(let ready) = state { captureLocalJoinOrigin(id, ready: ready) }
        }
        if wasFailed { try await invitations.retryAndWait(id) }
        else { try await invitations.requestOpen(id) }
        if needsConnection {
            try await connectForJoiningKeepingLocalHome(invitationID: id)
        }
        autoOpenFailures.remove(id)
        scheduleAutomaticInvitationOpen()
    }

    func dismissJoin(_ id: UUID) async throws {
        guard let invitations, let entry = invitations.allEntries.first(where: { $0.id == id }) else {
            throw HomeInvitationInbox.Error.invalidState
        }
        try await invitations.deferOpen(id, expectedSession: entry.session)
        joinError = nil
        if localJoinOrigin?.invitationID == id {
            localReturnAfterDismiss = localJoinOrigin
            scheduleLocalReturnAfterDismiss()
        }
    }

    func selectHome(_ graph: HomeGraphIdentity) async throws {
        guard case .ready(let ready) = state, ready.presentation.isActive,
              let session = try accountProvider?.currentSession() else { throw ShopperSessionError.setupRequired }
        let capturedGeneration = generation
        let pendingEntries = invitations?.allEntries.filter {
            !$0.activationResolved && ($0.session == nil || $0.session == session)
                && ($0.state != .dismissed || $0.acceptanceAttempted)
        } ?? []
        let alreadySelected = homeCoordinator.activeScope?.graph == graph
        let pendingChoice = NSError(domain: "ShoppingHomeChoice", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Finish loading and choosing this home in Home invitations before opening it."])
        if !alreadySelected {
            guard !pendingEntries.contains(where: { $0.state == .ready(graph) }) else { throw pendingChoice }
            if !pendingEntries.isEmpty,
               graph.storeIdentifier == participantStoreForHomeChoice(ready.persistence)?.identifier {
                guard let identity = try await invitationShareIdentity(ready.persistence, session, graph) else {
                    throw pendingChoice
                }
                guard generation == capturedGeneration, ready.presentation.isActive,
                      try accountProvider?.currentSession() == session else { throw ShopperSessionError.accountChanged }
                // Import notifications can precede the inbox's exact-share resolution.
                // A different, previously joined share must remain independently selectable.
                let currentPending = invitations?.allEntries.filter {
                    !$0.activationResolved && ($0.session == nil || $0.session == session)
                        && ($0.state != .dismissed || $0.acceptanceAttempted)
                } ?? []
                guard !currentPending.contains(where: { $0.identity.share == identity || $0.state == .ready(graph) }) else {
                    throw pendingChoice
                }
            }
            try await deferAutomaticInvitationOpens(for: session)
            guard generation == capturedGeneration, ready.presentation.isActive,
                  try accountProvider?.currentSession() == session else { throw ShopperSessionError.accountChanged }
        }
        try homeCoordinator.select(graph)
        applyHomeSelection(to: ready)
    }

    func activateInvitedHome(entryID: UUID, graph: HomeGraphIdentity,
                             expectedSelectionGeneration: UInt64? = nil) async throws {
        let (ready, invitationController) = try validateInvitationChoice(entryID, graph: graph)
        guard !invitationActivations.values.contains(where: { $0.presentationID == ready.presentation.id }),
              let cart = ready.personalCartService,
              let entry = invitationController.allEntries.first(where: { $0.id == entryID }),
              let session = entry.session else { throw HomeInvitationInbox.Error.busy }
        let choiceAuthority = UICommandAuthority()
        invitationActivations[entryID] = (entry, choiceAuthority, ready.presentation.id)
        defer {
            if invitationActivations[entryID]?.presentationID == ready.presentation.id {
                invitationActivations.removeValue(forKey: entryID)
            }
            choiceAuthority.retire()
        }
        let capturedGeneration = generation
        let share = HomeEffectShare(recordName: entry.identity.share.recordName, zoneName: entry.identity.share.zoneName,
            zoneOwnerName: entry.identity.share.zoneOwnerName)
        let identity = HomeNativeAccessIdentity(scope: HomeEffectScope(session: session,
            householdID: graph.householdID, listID: graph.listID), storeIdentifier: graph.storeIdentifier,
            rootURI: graph.rootURI, share: share)
        let verifier = makeHomeRejoinVerifier(cart)
        let reservationID = UUID()
        var reservedDiscovery = false
        func releaseDiscovery() async {
            guard reservedDiscovery, invitationDiscoveryReservations[ready.presentation.id] == reservationID else { return }
            invitationDiscoveryReservations.removeValue(forKey: ready.presentation.id)
            guard generation == capturedGeneration, (try? accountProvider?.currentSession()) == session else { return }
            // Replay observations suppressed during selection. A failed observation belongs
            // to homeDiscoveryError; it must not replace the explicit Open result.
            do { try await refreshHomes() } catch { }
        }
        do {
            try await ready.persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: share)) { @MainActor in
                @MainActor func validateChoice() throws {
                    try choiceAuthority.validate()
                    let (current, _) = try self.validateInvitationChoice(entryID, graph: graph)
                    guard self.generation == capturedGeneration, current.presentation.id == ready.presentation.id,
                          expectedSelectionGeneration == nil
                              || self.homeCoordinator.generation == expectedSelectionGeneration,
                          invitationController.allEntries.first(where: { $0.id == entryID }) == entry else {
                        throw HomeInvitationInbox.Error.invalidState
                    }
                }
                try validateChoice()
                let command = try await Task.detached(priority: .utility) {
                    try cart.captureHomeRejoin(entryID: entryID, identity: identity, verifier: verifier)
                }.value
                try validateChoice()
                try await verifier.refresh(identity)
                try validateChoice()
                try await Task.detached(priority: .userInitiated) {
                    try cart.commitHomeRejoin(command, verifier: verifier, choiceAuthority: choiceAuthority)
                }.value
                try validateChoice()
                // Native verification remains observable. Reserve only the final committed
                // discovery and selection so ordinary refresh cannot supersede its request.
                self.invitationDiscoveryReservations[ready.presentation.id] = reservationID
                reservedDiscovery = true
                guard let request = self.homeCoordinator.beginDiscovery() else { throw HomeInvitationInbox.Error.invalidState }
                let discovery = try await self.discoverHomes(HomeDiscoveryService(persistence: ready.persistence))
                try validateChoice()
                guard self.homeCoordinator.reconcile(discovery, request: request) else { throw HomeInvitationInbox.Error.invalidState }
                try self.homeCoordinator.select(graph, renewingAuthority: true)
                self.applyHomeSelection(to: ready)
                try await invitationController.resolveActivation(entryID)
            }
        } catch {
            await releaseDiscovery()
            throw error
        }
        await releaseDiscovery()
    }

    func keepCurrentHome(entryID: UUID) async throws {
        guard invitationActivations[entryID] == nil else { throw HomeInvitationInbox.Error.busy }
        let (ready, invitationController) = try validateInvitationChoice(entryID, graph: nil)
        let capturedGeneration = generation
        let returnToLocal = homeCoordinator.activeScope == nil && deviceLocalHome != nil
        if homeCoordinator.activeScope == nil { homeCoordinator.deferSelection() }
        try await invitationController.resolveActivation(entryID)
        if returnToLocal {
            guard generation == capturedGeneration, ready.presentation.isActive else { throw ShopperSessionError.accountChanged }
            try await openRetainedLocalHome()
        }
    }

    private func validateInvitationChoice(_ entryID: UUID, graph: HomeGraphIdentity?) throws
        -> (ReadyState, HomeInvitationController) {
        guard personalMode, case .ready(let ready) = state, ready.presentation.isActive,
              let provider = accountProvider, let invitations,
              let entry = invitations.allEntries.first(where: { $0.id == entryID }),
              !entry.activationResolved,
              !invitations.hasPendingChoiceChange(for: entry.identity),
              entry.session == (try verifiedSession(provider)),
              case .ready(let invited) = entry.state,
              graph == nil || graph == invited,
              invited.storeIdentifier == entry.sharedStoreIdentifier,
              homeCoordinator.homes.contains(where: { $0.graph == invited }),
              ready.persistence.personalCartInitialBinding == entry.session?.accountBinding,
              participantStoreForHomeChoice(ready.persistence)?.identifier == entry.sharedStoreIdentifier else {
            throw HomeInvitationInbox.Error.invalidState
        }
        return (ready, invitations)
    }

    struct CreatedHome {
        let command: HomeCreationCommand
        let journalURL: URL
        let householdID: UUID
        let listID: UUID
        let selected: Bool
    }

    /// Ordinary first use is explicit. The local path uses a separate exact-ID
    /// journal and never represents an unauthenticated store as account owned.
    func createFirstHome() async throws {
        let entry = homeEntry
        guard entry.root == .noHomes else {
            throw NeedServiceError.scopeChanged
        }
        if personalMode {
            guard !entry.hasPendingInvitation else { throw NeedServiceError.scopeChanged }
            let created = try await createHome(name: "My Home")
            if created.selected { try await acknowledgeHomeCreation(created) }
            return
        }
        guard !entry.invitations.contains(where: { $0.openRequested }) else {
            throw NeedServiceError.scopeChanged
        }
        try await createFirstLocalHome()
    }

    private func createFirstLocalHome() async throws {
        guard !isCreatingHome, !isShowingRetainedLocalHome,
              case .ready(let ready) = state, ready.presentation.isActive,
              ready.householdID == nil, let store = ready.persistence.primaryStore,
              ready.persistence.role(of: store) == .local,
              let storeURL = store.url, let storeIdentifier = store.identifier else {
            throw NeedServiceError.scopeChanged
        }
        let capturedGeneration = generation
        isCreatingHome = true
        defer { isCreatingHome = false }
        _ = try await HomeDeletionService(persistence: ready.persistence).statuses()
        guard generation == capturedGeneration, ready.presentation.isActive else { throw NeedServiceError.scopeChanged }
        let journal = LocalHomeCreationJournal(storeURL: storeURL)
        let command = try await Task.detached(priority: .userInitiated) {
            try journal.begin(name: "My Home", storeIdentifier: storeIdentifier)
        }.value
        let service = ready.service
        _ = try await Task.detached(priority: .userInitiated) {
            try service.createLocalHousehold(command: command)
        }.value
        // The save is durable. A later presentation change cannot make this a
        // retryable creation failure or select a home in a different store.
        guard generation == capturedGeneration, ready.presentation.isActive else { return }
        let discovery = HomeDiscoveryService(persistence: ready.persistence)
        let snapshot = try await Task.detached(priority: .utility) { try discovery.discover() }.value
        guard generation == capturedGeneration, ready.presentation.isActive,
              let home = snapshot.homes.first(where: {
                  $0.graph.storeIdentifier == storeIdentifier
                      && $0.graph.householdID == command.householdID
                      && $0.graph.listID == command.listID
              }) else { return }
        localHomeName = home.name
        localDiscoveryComplete = !snapshot.hasIncompleteRoots
        ready.presentation.retire()
        state = .ready(ReadyState(persistence: ready.persistence, service: ready.service,
            householdID: command.householdID, listID: command.listID,
            personalCartService: personalService))
        do {
            try await Task.detached(priority: .utility) { try journal.acknowledge(command) }.value
        } catch { homeSetupError = error }
    }

    /// The local Settings screen passes its original presentation, so saving a
    /// name after selection or store changes cannot rename the replacement home.
    func renameLocalHome(name: String, presentedBy presentationID: UUID) async throws {
        guard !isDeletingHome, case .ready(let ready) = state,
              ready.presentation.id == presentationID, ready.presentation.isActive,
              !ready.persistence.personalCartsEnabled,
              let householdID = ready.householdID, let listID = ready.listID,
              let store = ready.persistence.primaryStore,
              let storeIdentifier = store.identifier,
              ready.persistence.role(of: store) == .local else { throw NeedServiceError.scopeChanged }
        let capturedGeneration = generation
        let discovery = HomeDiscoveryService(persistence: ready.persistence)
        let snapshot = try await Task.detached(priority: .utility) { try discovery.discover() }.value
        guard generation == capturedGeneration, ready.presentation.isActive,
              case .ready(let current) = state, current.presentation.id == presentationID else {
            throw NeedServiceError.scopeChanged
        }
        let matches = snapshot.homes.filter {
            $0.graph.householdID == householdID && $0.graph.listID == listID
                && $0.graph.storeIdentifier == storeIdentifier && $0.access == .owner
        }
        guard matches.count == 1, let graph = matches.first?.graph else { throw NeedServiceError.scopeChanged }
        let service = ready.service
        try await Task.detached(priority: .userInitiated) {
            try service.renameLocalHome(name: name, graph: graph)
        }.value
        // The save is durable. Update only the same mounted local selection.
        guard generation == capturedGeneration, ready.presentation.isActive,
              case .ready(let selected) = state, selected.presentation.id == presentationID,
              selected.householdID == graph.householdID, selected.listID == graph.listID,
              selected.persistence.primaryStore?.identifier == graph.storeIdentifier else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        localHomeName = trimmed
        if isShowingRetainedLocalHome,
           deviceLocalHome?.storeIdentifier == graph.storeIdentifier,
           deviceLocalHome?.householdID == graph.householdID,
           deviceLocalHome?.listID == graph.listID {
            retainedLocalHomeName = trimmed
        }
    }

    func createHome(name: String, resuming: HomeCreationCommand? = nil, beforeSelectionReconciliation: () async -> Void = {}) async throws -> CreatedHome {
        guard !isCreatingHome, case .ready(let ready) = state,
              let provider = accountProvider else { throw ShopperSessionError.setupRequired }
        let session = try provider.currentSession()
        try await deferAutomaticInvitationOpens(for: session)
        guard ready.presentation.isActive, try provider.currentSession() == session else {
            throw ShopperSessionError.accountChanged
        }
        let capturedGeneration = homeCoordinator.generation
        isCreatingHome = true
        defer { isCreatingHome = false }
        let service = ready.service
        let (journalURL, storeIdentifier) = try creationJournalLocation(ready: ready, session: session)
        guard let cart = personalService, cart.persistence === ready.persistence else { throw ShopperSessionError.setupRequired }
        _ = try await HomeDeletionService(persistence: ready.persistence, cart: cart).statuses()
        guard ready.presentation.isActive, homeCoordinator.generation == capturedGeneration,
              try provider.currentSession() == session else { throw ShopperSessionError.accountChanged }
        let command = try await Task.detached(priority: .userInitiated) {
            try HomeCreationJournal(url: journalURL).begin(name: name, session: session, storeIdentifier: storeIdentifier, resuming: resuming)
        }.value
        let created = try await Task.detached(priority: .userInitiated) {
            try service.createHousehold(command: command)
        }.value
        // Creation has committed. A refresh, account transition or metadata read failure
        // cannot turn that durable success into a retryable creation error.
        func result() -> CreatedHome {
            CreatedHome(command: command, journalURL: journalURL,
                householdID: created.householdID, listID: created.listID,
                selected: homeCoordinator.activeScope?.accountBinding == session.accountBinding
                    && homeCoordinator.activeScope?.graph.householdID == created.householdID
                    && homeCoordinator.activeScope?.graph.listID == created.listID)
        }
        do {
            guard ready.presentation.isActive, homeCoordinator.generation == capturedGeneration,
                  try provider.currentSession() == session,
                  let request = homeCoordinator.beginDiscovery() else { return result() }
            let discovery = HomeDiscoveryService(persistence: ready.persistence)
            let snapshot = try await Task.detached(priority: .utility) { try discovery.discover() }.value
            await beforeSelectionReconciliation()
            guard ready.presentation.isActive, try provider.currentSession() == session,
                  homeCoordinator.reconcile(snapshot, request: request),
                  let home = snapshot.homes.first(where: {
                      $0.graph.householdID == created.householdID && $0.graph.listID == created.listID && $0.access == .owner
                  }) else { return result() }
            try homeCoordinator.select(home.graph)
            applyHomeSelection(to: ready)
        } catch {
            // Keep the committed graph available to normal discovery and explicit selection.
        }
        return result()
    }

    /// Configured entry point for invitation UI and the development sharing harness.
    /// A prepared share is not evidence that its grocery graph has exported.
    func prepareSelectedHomeShare(retryInterrupted: Bool = false) async throws -> PreparedHomeShare {
        guard !isDeletingHome, case .ready(let ready) = state, let scope = ready.homeScope,
              homeCoordinator.homes.contains(where: { $0.graph == scope.graph && $0.access == .owner }),
              let url = ready.persistence.primaryStore?.url else { throw HomeSharingError.ownerRequired }
        let transport = ManagedHomeShareTransport(persistence: ready.persistence,
            authority: ready.presentation.commandAuthority)
        let journalURL = url.deletingLastPathComponent().appendingPathComponent(
            "share-provisioning-" + scope.preferenceNamespace + ".json")
        let result = try await homeShareProvisioner.prepare(scope: scope, journalURL: journalURL,
            transport: transport, retryInterrupted: retryInterrupted)
        guard ready.presentation.isActive, homeCoordinator.activeScope == scope else {
            throw HomeSharingError.scopeChanged
        }
        retryShareAssociations()
        return result
    }

    func homeDetailsActions(scope: ActiveHomeScope) -> HomeDetailsActions {
        let actions = HomeDetailsActions(
            refresh: { [self] in
                let (ready, url, transport) = try membershipContext(scope)
                await refreshHomeAccessAndReplay()
                try validateMembershipPresentation(ready, scope: scope)
                do {
                    let result = try await homeMembershipCoordinator.refresh(scope: scope, journalURL: url, transport: transport)
                    try await refreshHomes()
                    try validateMembershipPresentation(ready, scope: scope)
                    return result
                } catch {
                    try? await refreshHomes()
                    throw error
                }
            },
            pending: { [self] in
                let (ready, url, _) = try membershipContext(scope)
                let result = try await homeMembershipCoordinator.pending(scope: scope, journalURL: url)
                try validateMembershipPresentation(ready, scope: scope)
                return result
            },
            invite: { [self] retry in
                guard #available(iOS 18.0, *) else { throw HomeMembershipError.unsupportedVersion }
                let (ready, url, transport) = try membershipContext(scope)
                _ = try await prepareSelectedHomeShare(retryInterrupted: retry)
                try validateMembershipPresentation(ready, scope: scope)
                let result = try await homeMembershipCoordinator.invite(scope: scope, journalURL: url, transport: transport)
                try validateMembershipPresentation(ready, scope: scope)
                return result
            },
            resend: { [self] participantID in
                let (ready, url, transport) = try membershipContext(scope)
                let result = try await homeMembershipCoordinator.resend(participantID: participantID,
                    scope: scope, journalURL: url, transport: transport)
                try validateMembershipPresentation(ready, scope: scope)
                return result
            },
            acknowledge: { [self] delivery in
                guard delivery.scope == scope else { throw HomeMembershipError.scopeChanged }
                let (ready, url, _) = try membershipContext(scope)
                try await homeMembershipCoordinator.acknowledge(delivery, journalURL: url)
                try validateMembershipPresentation(ready, scope: scope)
            },
            rename: { [self] name in
                let (ready, _, _) = try membershipContext(scope)
                let service = ready.service
                try await Task.detached(priority: .userInitiated) { try service.renameHome(name: name, scope: scope) }.value
                try validateMembershipPresentation(ready, scope: scope)
                try await refreshHomes()
            }, removals: HomeDetailsRemovalActions(
                prepare: { [self] purpose, participantID in
                    let (ready, url, transport) = try membershipContext(scope)
                    let result = try await homeMembershipCoordinator.prepareRemoval(purpose: purpose,
                        participantID: participantID, scope: scope, journalURL: url, transport: transport)
                    try validateMembershipPresentation(ready, scope: scope)
                    return result
                }, confirm: { [self] confirmation in
                    let (ready, url, transport) = try membershipContext(scope)
                    guard confirmation.removal.origin == scope else { throw HomeMembershipError.scopeChanged }
                    let result = try await homeMembershipCoordinator.confirmRemoval(confirmation,
                        scope: scope, journalURL: url, transport: transport)
                    try validateMembershipPresentation(ready, scope: scope)
                    return result
                }, retry: { [self] in
                    let (ready, url, transport) = try membershipContext(scope)
                    let result = try await homeMembershipCoordinator.retryRemovals(scope: scope,
                        journalURL: url, transport: transport)
                    try validateMembershipPresentation(ready, scope: scope)
                    return result
                }), leave: HomeDetailsLeaveActions(
                    prepare: { [self] in try await prepareHomeLeave(scope: scope) },
                    confirm: { [self] command in try await confirmHomeLeave(command, scope: scope) }),
                deletion: homeDeletionActions(scope: scope))
#if DEBUG
        if var fixture = homeDetailsFixtures[scope] { fixture.deletion = actions.deletion; return fixture }
        if var fixture = HomeDetailsUITestFixture.make(scope: scope,
            name: homeCoordinator.homes.first(where: { $0.graph == scope.graph })?.name ?? "Current home",
            rename: actions.rename,
            leaveOverride: HomeLeaveRootGoneUITestBackend.isEnabled(ProcessInfo.processInfo.environment) ? actions.leave : nil) {
            fixture.deletion = actions.deletion
            homeDetailsFixtures[scope] = fixture
            return fixture
        }
#endif
        return actions
    }

    func prepareHomeLeave(scope: ActiveHomeScope) async throws -> HomeLeaveCommand {
        let (ready, _, _) = try membershipContext(scope)
        guard let cart = personalService, cart.persistence === ready.persistence,
              let provider = accountProvider,
              participantStoreForHomeChoice(ready.persistence)?.identifier == scope.graph.storeIdentifier else {
            throw HomeMembershipError.scopeChanged
        }
        let session = try verifiedSession(provider)
        guard let share = try await invitationShareIdentity(ready.persistence, session, scope.graph) else {
            throw HomeMembershipError.shareUnavailable
        }
        try validateMembershipPresentation(ready, scope: scope)
        let identity = HomeNativeAccessIdentity(scope: HomeEffectScope(session: session,
            householdID: scope.graph.householdID, listID: scope.graph.listID),
            storeIdentifier: scope.graph.storeIdentifier, rootURI: scope.graph.rootURI,
            share: HomeEffectShare(recordName: share.recordName, zoneName: share.zoneName, zoneOwnerName: share.zoneOwnerName))
        let command = try await makeHomeLeaveTransport(cart).prepare(identity: identity,
            authority: ready.presentation.commandAuthority)
        try validateMembershipPresentation(ready, scope: scope)
        return command
    }

    func confirmHomeLeave(_ command: HomeLeaveCommand, scope: ActiveHomeScope) async throws -> HomeLeaveStatus {
        let (ready, _, _) = try membershipContext(scope)
        guard let cart = personalService, cart.persistence === ready.persistence,
              let provider = accountProvider else { throw HomeMembershipError.scopeChanged }
        let session = try verifiedSession(provider)
        guard command.origin.scope == HomeEffectScope(session: session,
            householdID: scope.graph.householdID, listID: scope.graph.listID),
              command.origin.storeIdentifier == scope.graph.storeIdentifier,
              command.origin.rootURI == scope.graph.rootURI else { throw HomeMembershipError.scopeChanged }
        let requestGeneration = generation
        do {
            let result = try await makeHomeLeaveTransport(cart).execute(command, authority: ready.presentation.commandAuthority)
            await publishHomeLeaveOutcome(cart: cart, generation: requestGeneration)
            return result
        } catch {
            await publishHomeLeaveOutcome(cart: cart, generation: requestGeneration)
            throw error
        }
    }

    /// An already-retained but unsubmitted confirmation can be finished without
    /// reopening the shared graph's retired screen. Submitted uncertainty only observes.
    func resumeHomeLeave(_ command: HomeLeaveCommand) async throws {
        guard homeLeaveResumingID == nil, let cart = personalService,
              let status = homeLeaveStatuses.first(where: { $0.command == command }), canResumeHomeLeave(status) else {
            throw HomeMembershipError.scopeChanged
        }
        let requestGeneration = generation
        homeLeaveResumingID = command.id
        defer { if generation == requestGeneration, homeLeaveResumingID == command.id { homeLeaveResumingID = nil } }
        do {
            _ = try await makeHomeLeaveTransport(cart).execute(command)
            await publishHomeLeaveOutcome(cart: cart, generation: requestGeneration)
        } catch {
            await publishHomeLeaveOutcome(cart: cart, generation: requestGeneration)
            throw error
        }
    }

    func canResumeHomeLeave(_ status: HomeLeaveStatus) -> Bool {
        guard let provider = accountProvider, (try? verifiedSession(provider)) != nil else { return false }
        return !status.submitted && !status.completed && homeLeaveIsOnThisDevice(status.command)
    }

    func homeLeaveIsOnThisDevice(_ command: HomeLeaveCommand) -> Bool {
        guard case .ready(let ready) = state, let provider = accountProvider,
              let session = try? provider.currentSession(),
              command.origin.scope == HomeEffectScope(session: session,
                householdID: command.origin.scope.householdID, listID: command.origin.scope.listID),
              let store = participantStoreForHomeChoice(ready.persistence) else { return false }
        return store.identifier == command.origin.storeIdentifier
            && store.url?.standardizedFileURL == command.storeURL.standardizedFileURL
    }

    private func publishHomeLeaveOutcome(cart: PersonalCartService, generation requestedGeneration: Int) async {
        guard generation == requestedGeneration, personalService === cart else { return }
        await refreshHomeLeaveStatuses(reconcile: false)
        guard generation == requestedGeneration, personalService === cart else { return }
        try? await refreshHomes()
    }

    /// Account-wide private status remains available when the shared root is gone.
    /// Publish retained evidence first; remote checks never submit another purge.
    func refreshHomeLeaveStatuses(reconcile: Bool = true) async {
        guard case .ready(let ready) = state, let cart = personalService,
              cart.persistence === ready.persistence, let provider = accountProvider,
              let session = try? provider.currentSession(), cart.initialAccountBinding == session.accountBinding else { return }
        let requestGeneration = generation, requestID = UUID()
        homeLeaveRefreshID = requestID
        isCheckingHomeLeaves = true
        defer { if homeLeaveRefreshID == requestID { homeLeaveRefreshID = nil; isCheckingHomeLeaves = false } }
        @MainActor func isCurrent() -> Bool {
            generation == requestGeneration && personalService === cart && homeLeaveRefreshID == requestID
                && (try? provider.currentSession()) == session
        }
        do {
            let retained = try await Task.detached(priority: .utility) { try cart.retainedHomeLeaves() }.value
            guard isCurrent() else { return }
            homeLeaveStatuses = retained
            homeLeaveStatusError = nil
            guard reconcile, (try? verifiedSession(provider)) == session else { return }
            var observedFailure = false
            let transport = makeHomeLeaveTransport(cart)
            for status in retained where status.submitted && !status.completed {
                guard isCurrent() else { return }
                guard (try? verifiedSession(provider)) == session else { break }
                guard homeLeaveIsOnThisDevice(status.command) else { continue }
                do { _ = try await transport.reconcile(status.command) }
                catch { observedFailure = true }
            }
            let refreshed = try await Task.detached(priority: .utility) { try cart.retainedHomeLeaves() }.value
            guard isCurrent() else { return }
            homeLeaveStatuses = refreshed
            if observedFailure { homeLeaveStatusError = "iCloud has not confirmed leaving this home. Your personal cart and history remain saved." }
        } catch {
            guard isCurrent() else { return }
            homeLeaveStatusError = "Saved leave status could not be checked. Your personal cart and history remain saved."
        }
    }

    private func clearHomeLeavePresentation() {
        homeDeletionRefreshID = nil
        homeDeletionStatuses = []
        homeDeletionStatusError = nil
        isDeletingHome = false
        homeLeaveRefreshID = nil
        homeLeaveStatuses = []
        homeLeaveStatusError = nil
        isCheckingHomeLeaves = false
        homeLeaveResumingID = nil
    }

    // MARK: Home deletion

    var hasDeletedHome: Bool { !homeDeletionStatuses.isEmpty }

    private func homeDeletionActions(scope: ActiveHomeScope) -> HomeDetailsDeletionActions? {
        guard case .ready(let ready) = state, ready.homeScope == scope,
              homeCoordinator.homes.first(where: { $0.graph == scope.graph })?.access == .owner,
              let cart = personalService else { return nil }
        return deletionActions(ready: ready, service: HomeDeletionService(persistence: ready.persistence, cart: cart))
    }

    func localHomeDeletionActions() -> HomeDetailsDeletionActions? {
        guard case .ready(let ready) = state, !ready.persistence.personalCartsEnabled,
              ready.householdID != nil, ready.listID != nil else { return nil }
        return deletionActions(ready: ready, service: HomeDeletionService(persistence: ready.persistence))
    }

    private func deletionActions(ready: ReadyState, service: HomeDeletionService) -> HomeDetailsDeletionActions {
        var confirmed: HomeDeletionCommand?
        return HomeDetailsDeletionActions(prepare: { [weak self] in
            guard let self, ready.presentation.isActive, !self.isDeletingHome else { throw HomeDeletionError.scopeChanged }
            let graph: HomeGraphIdentity
            if let scope = ready.homeScope { graph = scope.graph }
            else {
                let discovery = HomeDiscoveryService(persistence: ready.persistence)
                let homes = try await Task.detached(priority: .utility) { try discovery.discover() }.value
                guard let home = homes.homes.first(where: { $0.graph.householdID == ready.householdID && $0.graph.listID == ready.listID }) else {
                    throw HomeDeletionError.scopeChanged
                }
                graph = home.graph
            }
            return try await service.prepare(graph: graph, scope: ready.homeScope, authority: ready.presentation.commandAuthority)
        }, confirm: { [weak self] command in
            guard let self, ready.presentation.isActive, !self.isDeletingHome,
                  command.graph.householdID == ready.householdID, command.graph.listID == ready.listID,
                  command.scope == ready.homeScope else { throw HomeDeletionError.scopeChanged }
            confirmed = command
            self.isDeletingHome = true
            defer { self.isDeletingHome = false }
            guard await self.homeShareProvisioner.activeRequestCount == 0 else { throw HomeDeletionError.sharingPending }
            do {
                let result = try await service.execute(command, authority: ready.presentation.commandAuthority)
                await self.refreshHomeDeletionStatuses(reconcile: false)
                self.applyDeletedHomeSelection()
                return result
            } catch {
                await self.refreshHomeDeletionStatuses(reconcile: false)
                self.applyDeletedHomeSelection()
                throw error
            }
        }, reconcile: { [weak self] command in
            guard let self else { throw HomeDeletionError.scopeChanged }
            let retained = try await service.statuses().contains { $0.command == command }
            let result: HomeDeletionStatus
            if retained { result = try await service.reconcile(command) }
            else {
                guard confirmed == command, ready.presentation.isActive, !self.isDeletingHome,
                      await self.homeShareProvisioner.activeRequestCount == 0 else { throw HomeDeletionError.scopeChanged }
                result = try await service.execute(command, authority: ready.presentation.commandAuthority)
            }
            await self.refreshHomeDeletionStatuses(reconcile: false)
            self.applyDeletedHomeSelection()
            return result
        })
    }

    func retryHomeDeletion(_ command: HomeDeletionCommand) async throws {
        guard !isDeletingHome, case .ready(let ready) = state,
              homeDeletionStatuses.contains(where: { $0.command == command && !$0.completed }) else { throw HomeDeletionError.scopeChanged }
        isDeletingHome = true
        defer { isDeletingHome = false }
        let service = HomeDeletionService(persistence: ready.persistence, cart: personalService)
        do {
            if ready.persistence.primaryStore?.identifier == command.graph.storeIdentifier {
                _ = try await service.reconcile(command)
            } else {
                let retained = try await retainedLocalDeletionStatuses(reconcile: false)
                guard retained.contains(where: { $0.command == command }) else { throw HomeDeletionError.scopeChanged }
                _ = try await retainedLocalDeletionStatuses(reconcile: true)
            }
            await refreshHomeDeletionStatuses(reconcile: false)
            applyDeletedHomeSelection()
        } catch {
            homeDeletionStatusError = "Couldn’t check deletion. Try again."
            throw error
        }
    }

    func refreshHomeDeletionStatuses(reconcile: Bool = true) async {
        guard case .ready(let ready) = state else { return }
        let cart = personalService
        guard cart == nil || cart?.persistence === ready.persistence else { return }
        let requestID = UUID(), requestGeneration = generation
        // A completion refresh supersedes an older read. Dropping it could leave
        // a deleted home selected after the background read published stale data.
        homeDeletionRefreshID = requestID
        defer { if homeDeletionRefreshID == requestID { homeDeletionRefreshID = nil } }
        let service = HomeDeletionService(persistence: ready.persistence, cart: cart)
        @MainActor func isCurrent() -> Bool {
            guard self.generation == requestGeneration, self.homeDeletionRefreshID == requestID,
                  self.personalService === cart, case .ready(let current) = self.state,
                  current.persistence === ready.persistence else { return false }
            return cart == nil || (try? cart?.sessionProvider.currentSession().accountBinding) == cart?.initialAccountBinding
        }
        do {
            var statuses = try await service.statuses()
            statuses += try await retainedLocalDeletionStatuses(reconcile: false)
            guard isCurrent() else { return }
            homeDeletionStatuses = statuses
            homeDeletionStatusError = nil
            if reconcile, !isDeletingHome {
                for status in statuses where !status.completed && status.command.graph.storeIdentifier == ready.persistence.primaryStore?.identifier {
                    guard isCurrent() else { return }
                    do { _ = try await service.reconcile(status.command) }
                    catch { homeDeletionStatusError = "Couldn’t check deletion. Try again." }
                }
                do { _ = try await retainedLocalDeletionStatuses(reconcile: true) }
                catch { homeDeletionStatusError = "Couldn’t check deletion. Try again." }
                statuses = try await service.statuses()
                statuses += try await retainedLocalDeletionStatuses(reconcile: false)
            }
            guard isCurrent() else { return }
            homeDeletionStatuses = statuses
            await recordCompletedRetainedHomeDeletions(statuses)
            guard isCurrent() else { return }
            if !isDeletingHome { applyDeletedHomeSelection() }
        } catch {
            guard isCurrent() else { return }
            homeDeletionStatusError = "Couldn’t check deletion. Try again."
        }
    }

    private func applyDeletedHomeSelection() {
        guard case .ready(let ready) = state else { return }
        if let retained = deviceLocalHome, homeDeletionStatuses.contains(where: {
            $0.completed && $0.command.isLocal && $0.command.graph.storeIdentifier == retained.storeIdentifier
                && $0.command.graph.householdID == retained.householdID && $0.command.graph.listID == retained.listID
        }) {
            deviceLocalHome = nil
            retainedLocalHomeName = nil
            isShowingRetainedLocalHome = false
            defaults.set(false, forKey: Self.retainedLocalKey)
        }
        if ready.persistence.personalCartsEnabled {
            var changed = false
            for status in homeDeletionStatuses {
                if let scope = status.command.scope {
                    changed = homeCoordinator.forgetSelectedHome(scope, generation: homeCoordinator.generation) || changed
                }
            }
            if changed {
                applyHomeSelection(to: ready)
                Task { try? await refreshHomes() }
            }
        } else if homeDeletionStatuses.contains(where: {
            $0.command.graph.householdID == ready.householdID && $0.command.graph.listID == ready.listID
        }) {
            if isShowingRetainedLocalHome {
                deviceLocalHome = nil
                retainedLocalHomeName = nil
                isShowingRetainedLocalHome = false
                defaults.set(false, forKey: Self.retainedLocalKey)
            }
            localHomeName = nil
            localDiscoveryComplete = true
            ready.presentation.retire()
            state = .ready(ReadyState(persistence: ready.persistence, service: ready.service, householdID: nil, listID: nil))
        }
    }

    private func membershipContext(_ scope: ActiveHomeScope) throws -> (ReadyState, URL, ManagedHomeMembershipTransport) {
        guard case .ready(let ready) = state,
              let store = ready.persistence.storeBindings.first(where: { $0.store.identifier == scope.graph.storeIdentifier })?.store,
              let storeURL = store.url else { throw HomeMembershipError.scopeChanged }
        try validateMembershipPresentation(ready, scope: scope)
        let journalURL = storeURL.deletingLastPathComponent().appendingPathComponent(
            "home-invitation-" + scope.preferenceNamespace + ".json")
        return (ready, journalURL, ManagedHomeMembershipTransport(persistence: ready.persistence,
            authority: ready.presentation.commandAuthority, privateRecords: ready.personalCartService))
    }

    private func validateMembershipPresentation(_ ready: ReadyState, scope: ActiveHomeScope) throws {
        guard ready.presentation.isActive, ready.homeScope == scope,
              homeCoordinator.activeScope == scope else { throw HomeMembershipError.scopeChanged }
    }

    func pendingHomeCreation() async throws -> HomeCreationCommand? {
        guard case .ready(let ready) = state, let provider = accountProvider else { return nil }
        let session = try provider.currentSession()
        let (url, storeIdentifier) = try creationJournalLocation(ready: ready, session: session)
        let pending = try await Task.detached(priority: .utility) {
            try HomeCreationJournal(url: url).pending(session: session, storeIdentifier: storeIdentifier)
        }.value
        guard ready.presentation.isActive, try provider.currentSession() == session else { return nil }
        return pending
    }

    func acknowledgeHomeCreation(_ created: CreatedHome) async throws {
        try await Task.detached(priority: .utility) {
            try HomeCreationJournal(url: created.journalURL).acknowledge(created.command)
        }.value
    }

    private func creationJournalLocation(ready: ReadyState, session: ShopperSession) throws -> (URL, String) {
        guard ready.persistence.personalCartInitialBinding == session.accountBinding else {
            throw ShopperSessionError.accountChanged
        }
        guard let store = ready.persistence.primaryStore, let url = store.url else {
            throw PersistenceSetupError.missingPrimaryStoreURL
        }
        return (HomeCreationJournal.location(storeURL: url, session: session), store.identifier)
    }

    private func applyHomeSelection(to ready: ReadyState) {
        let scope = homeCoordinator.activeScope
        guard ready.homeScope != scope || ready.homeGeneration != homeCoordinator.generation else { return }
        ready.presentation.retire()
        clearSharingStatusPresentation()
        let selection = scope.map { (householdID: $0.graph.householdID, listID: $0.graph.listID) }
        state = .ready(ReadyState(persistence: ready.persistence, service: ready.service,
            householdID: selection?.householdID, listID: selection?.listID,
            homeScope: scope, homeGeneration: homeCoordinator.generation,
            personalCartService: personalService))
    }

    private func resumePendingCart(recheckIfRunning: Bool = false) {
        Task { await refreshHomeDeletionStatuses() }
        Task { await refreshHomeLeaveStatuses() }
        Task { await refreshHomeAccessAndReplay(recheckIfRunning: recheckIfRunning) }
    }

    private func refreshHomeAccessAndReplay(recheckIfRunning: Bool = false) async {
        guard let personalService else { return }
        let requestedGeneration = generation, requestID = UUID()
        homeAccessRefreshID = requestID
        let failure = await personalService.refreshNativeHomeAccessAndReplay(recheckIfRunning: recheckIfRunning)
        guard generation == requestedGeneration, self.personalService === personalService,
              homeAccessRefreshID == requestID else { return }
        homeAccessRefreshID = nil
        if let failure {
            cartResumeError = NSError(domain: "ShoppingCartResume", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure])
        } else {
            cartResumeError = nil
        }
        try? await refreshHomes()
        guard generation == requestedGeneration, self.personalService === personalService else { return }
        if case .ready(let ready) = state { ready.personalCart?.refresh() }
    }

    private func retryShareAssociations() {
        Task { await refreshShareAssociations() }
    }

    private func refreshShareAssociations() async {
        guard let associationWorker else { return }
        let requestedGeneration = generation
        do {
            let count = try await associationWorker.retryPending()
            guard generation == requestedGeneration else { return }
            associationCountKnown = true
            pendingShareAssociationCount = count
            shareAssociationError = nil
        } catch {
            guard generation == requestedGeneration else { return }
            shareAssociationError = error
        }
    }
}

#if DEBUG
private struct UITestHomeRejoinVerifier: HomeRejoinVerifying {
    func validate(_ identity: HomeNativeAccessIdentity, in repository: PersonalCartRepository) throws {
        guard let provider = repository.persistence.personalCartSessionProvider as? ShopperSessionProvider,
              case .ready(let session) = provider.state, session == repository.session else {
            throw PersonalCartError.accountChanged
        }
    }

    func refresh(_ identity: HomeNativeAccessIdentity) async throws {
        try await Task.sleep(for: .seconds(1))
    }
}
#endif
