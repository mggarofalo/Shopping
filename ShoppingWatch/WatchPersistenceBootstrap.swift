import CloudKit
import CoreData
import Foundation

@MainActor
final class WatchPersistenceBootstrap {
    struct Runtime {
        let persistence: PersistenceController
        let provider: any ShopperSessionProviding
        let cart: PersonalCartService
        let history: PersistentHistoryConsumer
        let selectionURL: URL
        let associations: ManagedShareAssociationWorker?
    }

    var onAuthorityInvalidated: (() -> Void)?
    var onDataChanged: (() -> Void)?
    private let cloudSync = CloudSyncEventMonitor()
    private let provider: ShopperSessionProvider
    private let baseDirectory: URL
    private var current: Runtime?
    private var binding: String?
    private var observer: NSObjectProtocol?
    private var remoteObserver: NSObjectProtocol?
    private var associationObserver: NSObjectProtocol?
    private var shareObserver: NSObjectProtocol?
    private var lastRefresh: Date?
    private var authorityGeneration = 0
    private var detachmentError: Error?
    private(set) var syncMessage: String?

    init(bundle: Bundle = .main, baseDirectory: URL? = nil) throws {
        guard let container = bundle.object(forInfoDictionaryKey: "ShoppingCloudKitContainerIdentifier") as? String,
              let environment = bundle.object(forInfoDictionaryKey: "ShoppingCloudKitEnvironment") as? String else {
            throw ShopperSessionError.invalidConfiguration
        }
        let base = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("ShoppingWatch", isDirectory: true)
        self.baseDirectory = base
        provider = try ShopperSessionProvider(containerIdentifier: container, environment: environment,
            cacheDirectory: base.appendingPathComponent("Account", isDirectory: true))
        cloudSync.onChange = { [weak self] _ in self?.onDataChanged?() }
        observer = NotificationCenter.default.addObserver(forName: .shopperSessionDidChange, object: provider, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        }
        shareObserver = NotificationCenter.default.addObserver(forName: .watchAcceptedShare, object: nil, queue: .main) { [weak self] notification in
            guard let metadata = notification.userInfo?["metadata"] as? CKShare.Metadata else { return }
            Task { @MainActor in await self?.accept(metadata) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
        if let shareObserver { NotificationCenter.default.removeObserver(shareObserver) }
    }

    var accountStatusMessage: String? {
        if cloudSync.status.hasFailure { return cloudSync.status.message }
        if case .cached = provider.state { return "Using saved data. Changes sync when a connection returns." }
        return syncMessage ?? cloudSync.status.message
    }

    var householdWaitingMessage: String {
        if cloudSync.status.hasFailure { return cloudSync.status.message }
        return "Waiting for your household to sync from iCloud. Accept a household invitation or finish setup on your iPhone."
    }

    func runtime() async throws -> Runtime {
        if let detachmentError { throw detachmentError }
        if (try? provider.currentSession()) == nil {
            lastRefresh = Date()
            await provider.refresh()
        } else if lastRefresh == nil || Date().timeIntervalSince(lastRefresh!) > 30 {
            lastRefresh = Date()
            // An already authenticated replica never waits for a network round trip to shop.
            Task { [provider] in await provider.refresh() }
        }
        let session = try provider.currentSession()
        if let current, session.accountBinding == binding { return current }
        let configuration = try PersonalCartActivation.activate(sourceURL: nil, session: session,
            baseDirectory: baseDirectory.appendingPathComponent("Accounts", isDirectory: true), importLegacy: false)
        let persistence = try PersistenceController(configuration: configuration)
        cloudSync.attach(to: persistence.container)
        guard try provider.currentSession() == session else { throw PersonalCartError.accountChanged }
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let directory = try session.storeDirectory(in: baseDirectory.appendingPathComponent("Accounts", isDirectory: true))
        let runtime = Runtime(persistence: persistence, provider: provider, cart: cart,
            history: PersistentHistoryConsumer(persistence: persistence,
                checkpoints: FileHistoryCheckpointStore(directory: directory.appendingPathComponent("History", isDirectory: true))),
            selectionURL: directory.appendingPathComponent("watch-selection.json"),
            associations: persistence.shareAssociationJournal.map { ManagedShareAssociationWorker(persistence: persistence, journal: $0) })
        current = runtime
        binding = session.accountBinding
        observeImports(runtime)
        associationObserver = NotificationCenter.default.addObserver(forName: PersistenceController.pendingShareAssociation,
            object: persistence, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.drainAssociations(runtime) }
            }
        return runtime
    }

    private func accountChanged() {
        let next = try? provider.currentSession().accountBinding
        guard binding != nil, next != binding else { return }
        authorityGeneration += 1
        cloudSync.reset()
        syncMessage = nil
        onAuthorityInvalidated?()
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
        associationObserver = nil
        let previous = current
        current = nil
        binding = nil
        lastRefresh = nil
        if let previous {
            previous.persistence.writer.performAndWait { previous.persistence.writer.reset() }
            previous.persistence.container.viewContext.reset()
            let coordinator = previous.persistence.container.persistentStoreCoordinator
            do { for store in coordinator.persistentStores { try coordinator.remove(store) } }
            catch {
                detachmentError = error
                syncMessage = "The previous account store could not be closed. Relaunch Shopping to retry."
            }
        }
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = nil
    }

    private func observeImports(_ runtime: Runtime) {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: runtime.persistence.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.current?.persistence === runtime.persistence else { return }
                do {
                    _ = try await runtime.history.consume()
                    guard self.current?.persistence === runtime.persistence else { return }
                    await self.drainAssociations(runtime)
                    guard self.current?.persistence === runtime.persistence else { return }
                    self.onDataChanged?()
                } catch {
                    guard self.current?.persistence === runtime.persistence else { return }
                    self.syncMessage = "Saved data is available. Recent changes could not be refreshed."
                    self.onDataChanged?()
                }
            }
        }
    }

    func retryPendingAssociations() {
        guard let current else { return }
        Task { @MainActor [weak self] in await self?.drainAssociations(current) }
    }

    private func drainAssociations(_ runtime: Runtime) async {
        guard current?.persistence === runtime.persistence else { return }
        do {
            let remaining = try await runtime.associations?.retryPending() ?? 0
            guard current?.persistence === runtime.persistence else { return }
            if remaining > 0 { syncMessage = "Some household changes are waiting to be shared." }
        } catch {
            guard current?.persistence === runtime.persistence else { return }
            syncMessage = "Your changes are saved. Household sharing will retry later."
        }
    }

    private func accept(_ metadata: CKShare.Metadata) async {
        let generation = authorityGeneration
        do {
            let runtime = try await runtime()
            let session = try runtime.provider.currentSession()
            guard metadata.containerIdentifier == session.containerIdentifier,
                  let cloud = runtime.persistence.container as? NSPersistentCloudKitContainer,
                  let store = runtime.persistence.store(for: .participantShared) else { throw PersonalCartError.scopeChanged }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                cloud.acceptShareInvitations(from: [metadata], into: store) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            guard generation == authorityGeneration, current?.persistence === runtime.persistence else { return }
            guard try runtime.provider.currentSession() == session else { throw PersonalCartError.accountChanged }
            syncMessage = "Invitation accepted. Waiting for your household to arrive."
        } catch {
            guard generation == authorityGeneration else { return }
            syncMessage = "The household invitation could not be accepted. \(CloudSyncStatus.Failure.classify(error).message)"
        }
        onDataChanged?()
    }
}
