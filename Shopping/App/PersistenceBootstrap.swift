import CoreData
import CryptoKit
import Foundation
import SwiftUI

struct PersistenceSelection: Equatable {
    let householdID: UUID?
    let listID: UUID?
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
    private static let performanceFixtureVersion = 2
    private static let retainedUITestStoreLimit = 12
    private static let retainedUITestHistoryTokenLimit = 24

    final class Presentation {
        let id = UUID()
        private(set) var isActive = true
        func retire() { isActive = false }
    }

    struct ReadyState {
        let presentation = Presentation()
        let persistence: PersistenceController
        let service: NeedService
        let householdID: UUID?
        let listID: UUID?
        var personalCart: PersonalCartPresentation? = nil
        var personalCartService: PersonalCartService? = nil
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
    private let makeAccountProvider: (URL) throws -> ShopperSessionProvider
    @Published private(set) var state: State = .loading
    @Published private(set) var pendingShareAssociationCount = 0
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
#if DEBUG
    private var personalFixture = false
    private var personalNoticeFixture = false
    private var personalRevokedFixture = false
#endif
    private static let personalModeKey = "shopping.personalCart.enabled"
    private static let pendingImportKey = "shopping.personalCart.pendingImport"

    init(
        configuration: @escaping () throws -> PersistenceConfiguration = { try .applicationLocal() },
        preloadedPreviewEnvironment: ShoppingPreviewEnvironment? = nil,
        defaults: UserDefaults = .standard,
        makeAccountProvider: @escaping (URL) throws -> ShopperSessionProvider = PersistenceBootstrap.productionAccountProvider
    ) {
        self.configuration = configuration
        self.preloadedPreviewEnvironment = preloadedPreviewEnvironment
        self.defaults = defaults
        self.makeAccountProvider = makeAccountProvider
        cloudMonitor.onChange = { [weak self] in self?.cloudStatus = $0 }
    }

    private static func productionAccountProvider(_ base: URL) throws -> ShopperSessionProvider {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "ShoppingCloudKitContainerIdentifier") as? String,
              let environment = Bundle.main.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String else {
            throw ShopperSessionError.invalidConfiguration
        }
        return try ShopperSessionProvider(containerIdentifier: identifier, environment: environment,
            cacheDirectory: base.appendingPathComponent("Bindings", isDirectory: true))
    }

    var sharingStatusDescription: String {
        guard personalMode else { return "Saved on this device. iCloud setup has not been completed." }
        guard let accountProvider, (try? accountProvider.currentSession()) != nil else {
            return "Your iCloud account is not ready. Saved groceries are retained on this device."
        }
        return cloudStatus.message
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
#else
                let unavailableSetup = false
#endif
                let providerFactory: (URL) throws -> ShopperSessionProvider = { base in
                    if unavailableSetup { throw ShopperSessionError.temporarilyUnavailable }
                    return try productionAccountProvider(base)
                }
                if let fixtureName = processInfo.environment["SHOPPING_UI_TEST_FIXTURE"],
                   let fixture = ShoppingPreviewCase(rawValue: fixtureName) {
                    let environment = try ShoppingPreviewFixtures.make(fixture, storeURL: storeURL)
                    let bootstrap = PersistenceBootstrap(
                        configuration: { .local(storeURL: storeURL) },
                        preloadedPreviewEnvironment: environment,
                        defaults: fixtureDefaults, makeAccountProvider: providerFactory
                    )
#if DEBUG
                    bootstrap.personalFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_CART"] == "1"
                    bootstrap.personalNoticeFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_NOTICE"] == "1"
                    bootstrap.personalRevokedFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_REVOKED"] == "1"
#endif
                    return bootstrap
                }
                let bootstrap = PersistenceBootstrap(configuration: { .local(storeURL: storeURL) },
                    defaults: fixtureDefaults, makeAccountProvider: providerFactory)
                if unavailableSetup { bootstrap.personalMode = fixtureDefaults.bool(forKey: personalModeKey) }
#if DEBUG
                bootstrap.personalFixture = processInfo.environment["SHOPPING_UI_TEST_PERSONAL_CART"] == "1"
#endif
                return bootstrap
            } catch {
                return PersistenceBootstrap(configuration: { throw error })
            }
        }
        let bootstrap = PersistenceBootstrap()
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
        guard case .loading = state, transition == nil else { return }
        if personalMode { activatePersonalCarts(importLegacy: false) } else { load() }
    }

    func retry() {
        if personalMode { activatePersonalCarts(importLegacy: false) }
        else { beginTransition { [weak self] in self?.load() } }
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
    func runLoadingTransition() {
        guard let transition else { start(); return }
        guard loadingTransitionID == transition.id,
              transition.previous.map({ !mountedPresentations.contains($0.presentation.id) }) ?? true else { return }
        self.transition = nil
        do {
            try detachStores(transition.previous)
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
        if let accountProvider { Task { await accountProvider.refresh() } }
        if let personalService { try? personalService.resumePending() }
        if case .ready(let ready) = state { ready.personalCart?.refresh() }
        consumeHistory()
        retryShareAssociations()
    }

    func activatePersonalCarts(importLegacy: Bool) {
        guard !accountLoadInProgress, transition == nil else { return }
        accountLoadInProgress = true
        let sourceURL: URL?
        if importLegacy, case .ready(let ready) = state, !ready.persistence.configuration.isManaged {
            sourceURL = ready.persistence.configuration.stores.first?.url
            defaults.set(sourceURL?.path, forKey: Self.pendingImportKey)
        } else {
            sourceURL = defaults.string(forKey: Self.pendingImportKey).map { URL(fileURLWithPath: $0) }
        }
        personalMode = true
        defaults.set(true, forKey: Self.personalModeKey)
        beginTransition { [weak self] in self?.openPersonalStore(sourceURL: sourceURL) }
    }

    private func openPersonalStore(sourceURL: URL?) {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ShoppingAccounts", isDirectory: true)
            if accountProvider == nil {
                let provider = try makeAccountProvider(base)
                accountProvider = provider
                accountObserver = NotificationCenter.default.addObserver(forName: .shopperSessionDidChange,
                    object: provider, queue: nil) { [weak self] _ in
                    Task { @MainActor in self?.accountStateChanged() }
                }
            }
            guard let provider = accountProvider else { throw ShopperSessionError.setupRequired }
            Task {
                await provider.refresh()
                do {
                    let session = try provider.currentSession()
                    personalConfiguration = try PersonalCartActivation.activate(sourceURL: sourceURL,
                        session: session, baseDirectory: base, importLegacy: sourceURL != nil)
                    guard try provider.currentSession() == session else { throw ShopperSessionError.accountChanged }
                    defaults.removeObject(forKey: Self.pendingImportKey)
                    activeAccountBinding = session.accountBinding
                    personalMode = true
                    defaults.set(true, forKey: Self.personalModeKey)
                    load()
                } catch { state = .failed(error) }
                accountLoadInProgress = false
            }
        } catch {
            accountLoadInProgress = false
            state = .failed(error)
        }
    }

    private func accountStateChanged() {
        guard let accountProvider, !accountLoadInProgress else { return }
        do {
            let session = try accountProvider.currentSession()
            if session.accountBinding != activeAccountBinding {
                activatePersonalCarts(importLegacy: false)
            }
        } catch {
            retireAndFail(error)
        }
    }

    private func detachStores(_ previous: ReadyState?) throws {
        generation += 1
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver); self.remoteObserver = nil }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver); self.associationObserver = nil }
        historyConsumer = nil
        associationWorker = nil
        personalService = nil
        cloudMonitor.reset()
        if let ready = previous {
            let writer = ready.persistence.writer
            writer.performAndWait { writer.reset() }
            ready.persistence.container.viewContext.reset()
            let coordinator = ready.persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        activeAccountBinding = nil
    }

    private func makePersonalPresentation(selection: (householdID: UUID, listID: UUID)?) -> PersonalCartPresentation? {
        guard let personalService, let selection else { return nil }
        return PersonalCartPresentation(service: personalService, householdID: selection.householdID, listID: selection.listID)
    }

    private var allowsLocalHouseholdCreation: Bool {
#if DEBUG
        return !personalMode && !personalFixture
#else
        return !personalMode
#endif
    }

    private func load() {
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
            } else {
                resolvedConfiguration = try personalConfiguration ?? self.configuration()
                persistence = try PersistenceController(configuration: resolvedConfiguration)
                service = NeedService(persistence: persistence)
                selection = try service.firstHouseholdSelection()
                if selection == nil, allowsLocalHouseholdCreation, !resolvedConfiguration.isManaged, try service.isPersistentStoreEmpty() {
                    let created = try service.createHousehold()
                    selection = (created.householdID, created.listID)
                }
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
            if personalMode, let accountProvider {
                let cartService = PersonalCartService(persistence: persistence, sessionProvider: accountProvider)
                try cartService.captureLegacyReview()
                personalService = cartService
                do { try cartService.resumePending() }
                catch { shareAssociationError = error }
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
                personalCart: makePersonalPresentation(selection: selection),
                personalCartService: personalService
            ))
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
                _ = try await historyConsumer.consume()
                guard generation == requestedGeneration else { return }
                if case .ready(let ready) = state,
                   ready.householdID == nil,
                   let selection = try ready.service.firstHouseholdSelection() {
                    state = .ready(ReadyState(
                        persistence: ready.persistence,
                        service: ready.service,
                        householdID: selection.householdID,
                        listID: selection.listID,
                        personalCart: makePersonalPresentation(selection: selection),
                personalCartService: personalService
                    ))
                }
                do { try personalService?.resumePending() }
                catch { shareAssociationError = error }
                if case .ready(let ready) = state { ready.personalCart?.refresh() }
            } catch {
                guard generation == requestedGeneration else { return }
                retireAndFail(error)
            }
        }
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
                if case .ready(let ready) = state,
                   let journal = ready.persistence.shareAssociationJournal {
                    pendingShareAssociationCount = (try? journal.pending().count) ?? pendingShareAssociationCount
                }
            }
        }
    }
}
