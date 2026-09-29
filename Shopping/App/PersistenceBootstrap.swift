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
    private let makeHomeRejoinVerifier: @Sendable (PersonalCartService) -> any HomeRejoinVerifying
    private var invitationActivations: [UUID: (entry: HomeInvitationInbox.Entry, authority: UICommandAuthority)] = [:]
    private let activateAccountStore: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration
    @Published private(set) var state: State = .loading
    @Published private(set) var pendingShareAssociationCount = 0
    @Published private(set) var isCreatingHome = false
    @Published private(set) var shareAssociationError: Error?
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
    private var retainedLocalRecord: HomeAdoptionJournal.Record?
    private var retainedLocalConfiguration: PersistenceConfiguration?
    private var localHomeName: String?
    private var restoringLocalRoute = false
    private var preferredAdoptedHome: (householdID: UUID, listID: UUID)?
    @Published private(set) var retainedLocalHomeName: String?
    @Published private(set) var isShowingRetainedLocalHome = false

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
        makeAccountProvider: ((URL) throws -> ShopperSessionProvider)? = nil,
        accountStoreDirectory: (() throws -> URL)? = nil,
        participantStoreForHomeChoice: @escaping (PersistenceController) -> NSPersistentStore? = { $0.store(for: .participantShared) },
        invitationShareIdentity: @escaping @MainActor @Sendable (PersistenceController, ShopperSession, HomeGraphIdentity) async throws -> HomeShareIdentity? = {
            try await ManagedHomeInvitationTransport(persistence: $0, session: $1).shareIdentity(for: $2)
        },
        makeHomeRejoinVerifier: @escaping @Sendable (PersonalCartService) -> any HomeRejoinVerifying = { ManagedHomeRejoinVerifier(cart: $0) },
        activateAccountStore: @escaping @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration = { try PersistenceBootstrap.productionAccountActivation(source: $0, session: $1, base: $2, importLegacy: $3) }
    ) {
        self.configuration = configuration
        self.preloadedPreviewEnvironment = preloadedPreviewEnvironment
        self.defaults = defaults
        self.invitations = invitations
        self.homeCoordinator = ActiveHomeCoordinator(defaults: defaults)
        self.editorDrafts = HomeEditorDraftStore(defaults: defaults)
        self.makeAccountProvider = makeAccountProvider
        self.accountStoreDirectory = accountStoreDirectory
        self.participantStoreForHomeChoice = participantStoreForHomeChoice
        self.invitationShareIdentity = invitationShareIdentity
        self.makeHomeRejoinVerifier = makeHomeRejoinVerifier
        self.activateAccountStore = activateAccountStore
        cloudMonitor.onChange = { [weak self] in self?.cloudStatus = $0 }
        invitations?.onChoiceInvalidated = { [weak self] identity in
            guard let self else { return }
            for activation in self.invitationActivations.values where activation.entry.identity == identity {
                activation.authority.retire()
            }
        }
        invitations?.onChange = { [weak self] in
            guard let self else { return }
            for activation in self.invitationActivations.values {
                if self.invitations?.allEntries.contains(activation.entry) != true { activation.authority.retire() }
            }
            self.homeCoordinator.setInvitationPending(self.invitations?.hasPendingActivation == true)
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

    var sharingStatusPresentation: SharingStatusPresentation {
        guard personalMode else {
            return SharingStatusPresentation(symbol: "internaldrive", title: "Saved on this device",
                details: "Saved on this device. iCloud setup has not been completed.")
        }
        guard let accountProvider, (try? accountProvider.currentSession()) != nil else {
            return SharingStatusPresentation(symbol: "exclamationmark.icloud", title: "iCloud account needs attention",
                details: "Your iCloud account is not ready. Saved groceries are retained on this device.")
        }
        let symbol: String
        let title: String
        if cloudStatus.hasFailure {
            symbol = "exclamationmark.icloud"
            title = "Sync needs attention"
        } else if cloudStatus.isWorking {
            symbol = "arrow.triangle.2.circlepath.icloud"
            title = "iCloud working"
        } else if cloudStatus.lastUpload != nil || cloudStatus.lastDownload != nil {
            symbol = "checkmark.icloud"
            title = "Recent iCloud activity"
        } else {
            symbol = "icloud"
            title = "Waiting for iCloud"
        }
        return SharingStatusPresentation(symbol: symbol, title: title, details: cloudStatus.message)
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
#else
                let unavailableSetup = false
                let activeHomesFixture = false
                let homeAdoptionFixture = false
#endif
                let providerFactory: (URL) throws -> ShopperSessionProvider = { base in
                    if unavailableSetup { throw ShopperSessionError.temporarilyUnavailable }
                    if activeHomesFixture || homeAdoptionFixture {
                        return try ShopperSessionProvider(containerIdentifier: "iCloud.test.shopping-homes", environment: "Development",
                            cacheDirectory: base.appendingPathComponent("Bindings"),
                            lookup: .init(status: { .available }, recordName: { "isolated-home-test-account" }))
                    }
                    return try productionAccountProvider(base)
                }
                let accountDirectory: () throws -> URL = {
                    if homeAdoptionFixture || activeHomesFixture {
                        return storeURL.deletingLastPathComponent().appendingPathComponent(storeURL.lastPathComponent + "-accounts", isDirectory: true)
                    }
                    return try productionAccountDirectory()
                }
                let activate: @Sendable (URL?, ShopperSession, URL, Bool) throws -> PersistenceConfiguration = { source, session, base, approved in
                    if activeHomesFixture { return .local(storeURL: storeURL) }
                    if homeAdoptionFixture {
                        guard source == nil, !approved else { throw HomeAdoptionJournal.Failure.copyUnavailable }
                        return .local(storeURL: base.appendingPathComponent("Account.sqlite"))
                    }
                    return try productionAccountActivation(source: source, session: session, base: base, importLegacy: approved)
                }
                var fixtureInvitations: HomeInvitationController?
#if DEBUG
                if activeHomesFixture || homeAdoptionFixture {
                    let inboxURL = storeURL.deletingLastPathComponent()
                        .appendingPathComponent(storeURL.lastPathComponent + "-invitations/inbox.json")
                    let inbox = try HomeInvitationInbox(url: inboxURL,
                        containerIdentifier: "iCloud.test.shopping-homes", environment: "Development")
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
                    let bootstrap = PersistenceBootstrap(
                        configuration: { .local(storeURL: storeURL) },
                        preloadedPreviewEnvironment: environment,
                        defaults: fixtureDefaults, invitations: fixtureInvitations, makeAccountProvider: providerFactory,
                        accountStoreDirectory: accountDirectory, activateAccountStore: activate
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
                    accountStoreDirectory: accountDirectory, activateAccountStore: activate)
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
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
    }

    func start() {
        guard case .loading = state, transition == nil, !restoringLocalRoute else { return }
        if !personalMode, defaults.bool(forKey: Self.retainedLocalKey), retainedLocalRecord == nil {
            restoringLocalRoute = true
            let requestedGeneration = generation
            Task {
                defer { restoringLocalRoute = false }
                do {
                    let base = try await resolvedAccountDirectory()
                    let record = try await Task.detached(priority: .userInitiated) {
                        let journal = HomeAdoptionJournal(baseDirectory: base)
                        guard let record = try journal.retainedLocalRecord() else {
                            throw HomeAdoptionJournal.Failure.invalidJournal
                        }
                        try journal.validateRetainedSource(record)
                        return record
                    }.value
                    guard generation == requestedGeneration, transition == nil else { return }
                    retainedLocalRecord = record
                    retainedLocalHomeName = record.homeName
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
        else if defaults.bool(forKey: Self.retainedLocalKey), retainedLocalRecord == nil {
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
        if let accountProvider {
            Task {
                await accountProvider.refresh()
                configureInvitations()
                await refreshHomeAccessAndReplay()
            }
        } else { resumePendingCart() }
        invitations?.checkAgain()
        if case .ready(let ready) = state { ready.personalCart?.refresh() }
        consumeHistory()
        Task {
            do { try await refreshHomes() }
            catch { shareAssociationError = error }
        }
        retryShareAssociations()
    }

    /// Existing personal-cart entry point uses the same durable, account-bound approval.
    func activatePersonalCarts(importLegacy: Bool) {
        guard !accountLoadInProgress, transition == nil else { return }
        if !personalMode, case .ready = state, !isShowingRetainedLocalHome {
            Task {
                do {
                    let choice = try await prepareInvitationSetup()
                    try await confirmInvitationSetup(choice, copyLocal: importLegacy)
                } catch { shareAssociationError = error }
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
        accountObserver = NotificationCenter.default.addObserver(forName: .shopperSessionDidChange,
            object: provider, queue: nil) { [weak self] _ in
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

    func confirmInvitationSetup(_ choice: InvitationSetupChoice, copyLocal: Bool) async throws {
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
            // Intent is durable before the UI retires or the restart preference changes.
            personalMode = true
            defaults.set(true, forKey: Self.personalModeKey)
            beginTransition { [weak self] in self?.openPersonalStore(expectedSession: proposal.session) }
        } catch {
            accountLoadInProgress = false
            throw error
        }
    }

    private func openPersonalStore(expectedSession: ShopperSession? = nil) {
        Task {
            defer { accountLoadInProgress = false }
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
                let activated = try await Task.detached(priority: .userInitiated) {
                    let journal = HomeAdoptionJournal(baseDirectory: base)
                    // A legacy path alone is not permission to import into the current account.
                    if let record = try journal.record(session: session), !record.verified {
                        guard case .ready(let verified) = provider.state, verified == session else {
                            throw ShopperSessionError.setupRequired
                        }
                    }
                    return try journal.activate(session: session, using: activate)
                }.value
                guard try provider.currentSession() == session else { throw ShopperSessionError.accountChanged }
                personalConfiguration = activated.configuration
                retainedLocalRecord = activated.retainedLocal
                retainedLocalHomeName = activated.retainedLocal?.homeName
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

    func openRetainedLocalHome() async throws {
        guard !accountLoadInProgress, transition == nil, let record = retainedLocalRecord,
              let source = record.sourceURL else { throw HomeAdoptionJournal.Failure.staleProposal }
        let capturedGeneration = generation
        let base = try await resolvedAccountDirectory()
        try await Task.detached(priority: .userInitiated) {
            try HomeAdoptionJournal(baseDirectory: base).validateRetainedSource(record)
        }.value
        guard generation == capturedGeneration, transition == nil else { throw HomeAdoptionJournal.Failure.staleProposal }
        retainedLocalConfiguration = .local(storeURL: source)
        personalConfiguration = nil
        preferredAdoptedHome = nil
        personalMode = false
        isShowingRetainedLocalHome = true
        defaults.set(true, forKey: Self.retainedLocalKey)
        defaults.set(false, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.load() }
    }

    func connectBackToAccount() async throws {
        guard !accountLoadInProgress, transition == nil, isShowingRetainedLocalHome,
              let record = retainedLocalRecord else { throw HomeAdoptionJournal.Failure.staleProposal }
        let capturedGeneration = generation
        let base = try await resolvedAccountDirectory()
        let provider = try await resolvedAccountProvider(base: base)
        await provider.refresh()
        guard generation == capturedGeneration, transition == nil, !accountLoadInProgress,
              isShowingRetainedLocalHome,
              try verifiedSession(provider) == record.session else { throw ShopperSessionError.accountChanged }
        accountLoadInProgress = true
        personalMode = true
        defaults.set(true, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.openPersonalStore(expectedSession: record.session) }
    }

    private func accountStateChanged() {
        guard personalMode, let accountProvider, !accountLoadInProgress else { return }
        do {
            let session = try accountProvider.currentSession()
            if session.accountBinding != activeAccountBinding {
                activatePersonalCarts(importLegacy: false)
            }
        } catch {
            retireAndFail(error)
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

    private var allowsLocalHouseholdCreation: Bool {
        if isShowingRetainedLocalHome { return false }
        if invitations?.hasPendingActivation == true { return false }
#if DEBUG
        return !personalMode && !personalFixture
#else
        return !personalMode
#endif
    }

    private func load() {
        guard preloadedPreviewEnvironment == nil else { finishLoad(prepared: nil); return }
        let requestedGeneration = generation
        let configuration = self.configuration
        let personalConfiguration = personalMode ? self.personalConfiguration : retainedLocalConfiguration
        let allowsLocalHouseholdCreation = self.allowsLocalHouseholdCreation
        let accountProvider = self.accountProvider
        let personalMode = self.personalMode
        let retainedLocalRecord = self.retainedLocalRecord
        let session = personalMode ? (try? accountProvider?.currentSession()) : nil
        homeCoordinator.bind(session)
        configureInvitations()
        let discoveryRequest = homeCoordinator.beginDiscovery()
        Task {
            do {
                if !personalMode, let retainedLocalRecord {
                    let base = try await resolvedAccountDirectory()
                    try await Task.detached(priority: .userInitiated) {
                        try HomeAdoptionJournal(baseDirectory: base).validateRetainedSource(retainedLocalRecord)
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
                    if !personalMode, let retainedLocalRecord,
                       let home = discovery.homes.first(where: {
                           $0.graph.householdID == retainedLocalRecord.householdID
                               && $0.graph.listID == retainedLocalRecord.listID
                       }) {
                        selection = (home.graph.householdID, home.graph.listID)
                    }
                    if selection == nil, allowsLocalHouseholdCreation, !resolved.isManaged,
                       try service.isPersistentStoreEmpty() {
                        let created = try service.createHousehold()
                        selection = (created.householdID, created.listID)
                        discovery = try HomeDiscoveryService(persistence: persistence).discover()
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
                personalService = prepared.personalCartService
                if let resumeError = prepared.resumeError {
                    shareAssociationError = NSError(domain: "ShoppingCartResume", code: 1,
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
            state = .ready(ReadyState(
                persistence: persistence,
                service: service,
                householdID: selection?.householdID,
                listID: selection?.listID,
                homeScope: homeCoordinator.activeScope,
                homeGeneration: homeCoordinator.generation,
                personalCartService: personalService
            ))
            configureInvitations()
            resumePendingCart()
            consumeHistory()
            retryShareAssociations()
        } catch {
            state = .failed(error)
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
                if imported.transactionCount > 0, case .ready(let ready) = state {
                    ready.persistence.homeNativeAccess.invalidateVerification()
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
        guard case .ready(let ready) = state, let request = homeCoordinator.beginDiscovery() else { return }
        let requestedGeneration = generation
        let discovery = HomeDiscoveryService(persistence: ready.persistence)
        let snapshot = try await Task.detached(priority: .utility) { try discovery.discover() }.value
        guard generation == requestedGeneration, ready.presentation.isActive,
              try accountProvider?.currentSession() == request.sessionForValidation else { return }
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
        }
        try homeCoordinator.select(graph)
        applyHomeSelection(to: ready)
    }

    func activateInvitedHome(entryID: UUID, graph: HomeGraphIdentity) async throws {
        let (ready, invitationController) = try validateInvitationChoice(entryID, graph: graph)
        guard invitationActivations[entryID] == nil, let cart = ready.personalCartService,
              let entry = invitationController.allEntries.first(where: { $0.id == entryID }),
              let session = entry.session else { throw HomeInvitationInbox.Error.busy }
        let choiceAuthority = UICommandAuthority()
        invitationActivations[entryID] = (entry, choiceAuthority)
        defer { invitationActivations.removeValue(forKey: entryID); choiceAuthority.retire() }
        let capturedGeneration = generation
        let share = HomeEffectShare(recordName: entry.identity.share.recordName, zoneName: entry.identity.share.zoneName,
            zoneOwnerName: entry.identity.share.zoneOwnerName)
        let identity = HomeNativeAccessIdentity(scope: HomeEffectScope(session: session,
            householdID: graph.householdID, listID: graph.listID), storeIdentifier: graph.storeIdentifier,
            rootURI: graph.rootURI, share: share)
        let verifier = makeHomeRejoinVerifier(cart)
        try await ready.persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: share)) { @MainActor in
            @MainActor func validateChoice() throws {
                try choiceAuthority.validate()
                let (current, _) = try self.validateInvitationChoice(entryID, graph: graph)
                guard self.generation == capturedGeneration, current.presentation.id == ready.presentation.id,
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
            guard let request = self.homeCoordinator.beginDiscovery() else { throw HomeInvitationInbox.Error.invalidState }
            let discovery = try await Task.detached(priority: .utility) {
                try HomeDiscoveryService(persistence: ready.persistence).discover()
            }.value
            try validateChoice()
            guard self.homeCoordinator.reconcile(discovery, request: request) else { throw HomeInvitationInbox.Error.invalidState }
            try self.homeCoordinator.select(graph, renewingAuthority: true)
            self.applyHomeSelection(to: ready)
            try await invitationController.resolveActivation(entryID)
        }
    }

    func keepCurrentHome(entryID: UUID) async throws {
        guard invitationActivations[entryID] == nil else { throw HomeInvitationInbox.Error.busy }
        let (ready, invitationController) = try validateInvitationChoice(entryID, graph: nil)
        let capturedGeneration = generation
        let returnToLocal = homeCoordinator.activeScope == nil && retainedLocalRecord != nil
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

    func createHome(name: String, resuming: HomeCreationCommand? = nil, beforeSelectionReconciliation: () async -> Void = {}) async throws -> CreatedHome {
        guard !isCreatingHome, case .ready(let ready) = state,
              let provider = accountProvider else { throw ShopperSessionError.setupRequired }
        let session = try provider.currentSession()
        let capturedGeneration = homeCoordinator.generation
        isCreatingHome = true
        defer { isCreatingHome = false }
        let service = ready.service
        let (journalURL, storeIdentifier) = try creationJournalLocation(ready: ready, session: session)
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
        guard case .ready(let ready) = state, let scope = ready.homeScope,
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
                }))
#if DEBUG
        if let fixture = homeDetailsFixtures[scope] { return fixture }
        if let fixture = HomeDetailsUITestFixture.make(scope: scope,
            name: homeCoordinator.homes.first(where: { $0.graph == scope.graph })?.name ?? "Current home",
            rename: actions.rename) {
            homeDetailsFixtures[scope] = fixture
            return fixture
        }
#endif
        return actions
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
        let selection = scope.map { (householdID: $0.graph.householdID, listID: $0.graph.listID) }
        state = .ready(ReadyState(persistence: ready.persistence, service: ready.service,
            householdID: selection?.householdID, listID: selection?.listID,
            homeScope: scope, homeGeneration: homeCoordinator.generation,
            personalCartService: personalService))
    }

    private func resumePendingCart(recheckIfRunning: Bool = false) {
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
            shareAssociationError = NSError(domain: "ShoppingCartResume", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure])
        } else if (shareAssociationError as NSError?)?.domain == "ShoppingCartResume" {
            shareAssociationError = nil
        }
        do { try await refreshHomes() }
        catch { shareAssociationError = error }
        if case .ready(let ready) = state { ready.personalCart?.refresh() }
    }

    private func retryShareAssociations() {
        guard let associationWorker else { return }
        let requestedGeneration = generation
        Task {
            do {
                let count = try await associationWorker.retryPending()
                guard generation == requestedGeneration else { return }
                pendingShareAssociationCount = count
                shareAssociationError = nil
            } catch {
                guard generation == requestedGeneration else { return }
                shareAssociationError = error
            }
        }
    }
}
