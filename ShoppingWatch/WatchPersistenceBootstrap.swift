import CloudKit
import CoreData
import Foundation
import os

enum WatchPerformanceTrace {
    static let log = OSLog(subsystem: "com.mggarofalo.shopping.watchkitapp", category: .pointsOfInterest)
}

@MainActor
final class WatchPersistenceBootstrap {
    /// Created off the UI actor, then transferred once to the main-actor runtime.
    /// No context or container is touched concurrently during that transfer.
    private struct PreparedStore: @unchecked Sendable {
        let persistence: PersistenceController
        let directory: URL

        func close() throws {
            let coordinator = persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
    }
    private struct RetiringStore: @unchecked Sendable {
        let persistence: PersistenceController
    }
    private struct Preparation {
        let accountBinding: String
        let task: Task<PreparedStore, Error>
    }

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
    var onSyncChanged: ((WatchSyncStatus) -> Void)?
    private let cloudSync = CloudSyncEventMonitor()
    private let associationStatus = WatchAssociationStatus()
    private let provider: ShopperSessionProvider
    private let baseDirectory: URL
    private var current: Runtime?
    private var preparation: Preparation?
    private var retirement: Task<Void, Error>?
    private var binding: String?
    private var observer: NSObjectProtocol?
    private var remoteObserver: NSObjectProtocol?
    private var associationObserver: NSObjectProtocol?
    private var shareObserver: NSObjectProtocol?
    private var lastRefresh: Date?
    private var authorityGeneration = 0
    private var accessRefreshID: UUID?
    private var detachmentError: Error?
    private(set) var syncMessage: String?
    private var accessMessage: String?

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
        cloudSync.onChange = { [weak self] _ in
            guard let self else { return }
            self.onSyncChanged?(self.syncStatus())
        }
        associationStatus.onChange = { [weak self] in self?.onDataChanged?() }
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
        let cached: Bool
        if case .cached = provider.state { cached = true } else { cached = false }
        return associationStatus.projectedMessage(cloudStatus: cloudSync.status,
            cachedAccount: cached, otherMessage: accessMessage ?? syncMessage)
    }

    func syncStatus(additionalMessage: String? = nil) -> WatchSyncStatus {
        var messages = [additionalMessage, syncMessage, accessMessage, associationStatus.message].compactMap { $0 }
        if case .cached = provider.state {
            messages.append("Using saved data. Changes sync when a connection returns.")
        }
        return WatchSyncStatus(cloud: cloudSync.status, attentionMessages: messages)
    }

    var householdWaitingMessage: String {
        if cloudSync.status.hasFailure { return cloudSync.status.message }
        return "Waiting for your household to sync from iCloud. Accept a household invitation or finish setup on your iPhone."
    }

    func runtime() async throws -> Runtime {
        if let detachmentError { throw detachmentError }
        if let retirement {
            do { try await retirement.value }
            catch {
                detachmentError = error
                syncMessage = "The previous account store could not be closed. Relaunch Shopping to retry."
                throw error
            }
            self.retirement = nil
        }
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
        let generation = authorityGeneration
        let accountsDirectory = baseDirectory.appendingPathComponent("Accounts", isDirectory: true)
        let ownsPreparation = preparation?.accountBinding != session.accountBinding
        let task: Task<PreparedStore, Error>
        if let preparation, preparation.accountBinding == session.accountBinding {
            task = preparation.task
        } else {
            task = Task.detached(priority: .userInitiated) {
                let signpostID = OSSignpostID(log: WatchPerformanceTrace.log)
                os_signpost(.begin, log: WatchPerformanceTrace.log, name: "Watch store bootstrap", signpostID: signpostID)
                defer { os_signpost(.end, log: WatchPerformanceTrace.log, name: "Watch store bootstrap", signpostID: signpostID) }
                let configuration = try PersonalCartActivation.activate(sourceURL: nil, session: session,
                    baseDirectory: accountsDirectory, importLegacy: false)
                let persistence = try PersistenceController(configuration: configuration)
                let directory = try session.storeDirectory(in: accountsDirectory)
                return PreparedStore(persistence: persistence, directory: directory)
            }
            preparation = Preparation(accountBinding: session.accountBinding, task: task)
        }
        let prepared: PreparedStore
        do { prepared = try await task.value }
        catch {
            if generation == authorityGeneration, preparation?.accountBinding == session.accountBinding { preparation = nil }
            throw error
        }
        guard generation == authorityGeneration, (try? provider.currentSession()) == session else {
            if generation == authorityGeneration, preparation?.accountBinding == session.accountBinding { preparation = nil }
            if ownsPreparation { Task.detached(priority: .utility) { try? prepared.close() } }
            throw PersonalCartError.accountChanged
        }
        if let current, binding == session.accountBinding { return current }
        preparation = nil
        let persistence = prepared.persistence
        cloudSync.attach(to: persistence.container)
        let cart = PersonalCartService(persistence: persistence, sessionProvider: provider)
        let runtime = Runtime(persistence: persistence, provider: provider, cart: cart,
            history: PersistentHistoryConsumer(persistence: persistence,
                checkpoints: FileHistoryCheckpointStore(directory: prepared.directory.appendingPathComponent("History", isDirectory: true))),
            selectionURL: prepared.directory.appendingPathComponent("watch-selection.json"),
            associations: persistence.shareAssociationJournal.map { ManagedShareAssociationWorker(persistence: persistence, journal: $0) })
        associationStatus.reset()
        current = runtime
        binding = session.accountBinding
        observeImports(runtime)
        associationObserver = NotificationCenter.default.addObserver(forName: PersistenceController.pendingShareAssociation,
            object: persistence, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.drainAssociations(runtime) }
            }
        refreshHomeAccess()
        return runtime
    }

    private func accountChanged() {
        let next = try? provider.currentSession().accountBinding
        guard binding != nil else { return }
        guard next != binding else {
            if case .ready = provider.state { refreshHomeAccess() }
            return
        }
        authorityGeneration += 1
        accessRefreshID = nil
        preparation = nil
        cloudSync.reset()
        associationStatus.reset()
        syncMessage = nil
        accessMessage = nil
        onAuthorityInvalidated?()
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
        associationObserver = nil
        let previous = current
        current = nil
        binding = nil
        lastRefresh = nil
        if let previous {
            retirement = Self.retireStore(previous.persistence)
        }
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = nil
    }

    static func retireStore(_ persistence: PersistenceController) -> Task<Void, Error> {
        persistence.container.viewContext.reset()
        let retiring = RetiringStore(persistence: persistence)
        return Task.detached(priority: .utility) {
            let writer = retiring.persistence.writer
            writer.performAndWait { writer.reset() }
            let coordinator = retiring.persistence.container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
    }

    private func observeImports(_ runtime: Runtime) {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        remoteObserver = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: runtime.persistence.container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.current?.persistence === runtime.persistence else { return }
                do {
                    let imported = try await runtime.history.consumeSummary()
                    guard self.current?.persistence === runtime.persistence else { return }
                    if imported.transactionCount > 0 { runtime.persistence.homeNativeAccess.invalidateVerification() }
                    await self.drainAssociations(runtime)
                    guard self.current?.persistence === runtime.persistence else { return }
                    if imported.requiresAccessRefresh { self.refreshHomeAccess(recheckIfRunning: true) }
                    self.onDataChanged?()
                } catch {
                    guard self.current?.persistence === runtime.persistence else { return }
                    self.syncMessage = "Saved data is available. Recent changes could not be refreshed."
                    self.onDataChanged?()
                }
            }
        }
    }

    /// Native access refresh is independent of local snapshot loading. In
    /// particular, the active-list timer and store switching never await it.
    func refreshHomeAccess(recheckIfRunning: Bool = false) {
        guard let runtime = current else { return }
        let requestID = UUID(), generation = authorityGeneration
        accessRefreshID = requestID
        Task { [weak self] in
            let failure = await runtime.cart.refreshNativeHomeAccessAndReplay(recheckIfRunning: recheckIfRunning)
            guard let self, self.authorityGeneration == generation,
                  self.current?.persistence === runtime.persistence, self.accessRefreshID == requestID else { return }
            self.accessRefreshID = nil
            self.accessMessage = failure.map { _ in "Saved cart available. Home access could not be verified; shared changes are waiting." }
            self.onDataChanged?()
        }
    }

    func retryPendingAssociations() {
        guard let current else { return }
        Task { @MainActor [weak self] in await self?.drainAssociations(current) }
    }

    private func drainAssociations(_ runtime: Runtime) async {
        guard current?.persistence === runtime.persistence else { return }
        await associationStatus.refresh {
            try await runtime.associations?.retryPending() ?? 0
        }
    }

    private func accept(_ metadata: CKShare.Metadata) async {
        let generation = authorityGeneration
        do {
            let runtime = try await runtime()
            let session = try runtime.provider.currentSession()
            let share = HomeEffectShare(recordName: metadata.share.recordID.recordName,
                zoneName: metadata.share.recordID.zoneID.zoneName, zoneOwnerName: metadata.share.recordID.zoneID.ownerName)
            try await runtime.persistence.homeParticipantOperations.perform(in: HomeParticipantZone(session: session, share: share)) { @MainActor in
                _ = try self.acceptanceEnvironment(runtime, session: session, metadata: metadata, generation: generation)
                try await HomeJoinGate.validate(persistence: runtime.persistence, session: session, share: share)
                let (cloud, store) = try self.acceptanceEnvironment(runtime, session: session, metadata: metadata, generation: generation)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    cloud.acceptShareInvitations(from: [metadata], into: store) { accepted, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let accepted, accepted.count == 1, let result = accepted.first,
                                result.containerIdentifier == metadata.containerIdentifier,
                                result.share.recordID == metadata.share.recordID {
                            continuation.resume()
                        } else { continuation.resume(throwing: PersonalCartError.unavailable) }
                    }
                }
                try await HomeJoinGate.validate(persistence: runtime.persistence, session: session, share: share)
                _ = try self.acceptanceEnvironment(runtime, session: session, metadata: metadata, generation: generation)
            }
            guard generation == authorityGeneration, current?.persistence === runtime.persistence else { return }
            guard try runtime.provider.currentSession() == session else { throw PersonalCartError.accountChanged }
            syncMessage = "Invitation accepted. Waiting for your household to arrive."
        } catch {
            guard generation == authorityGeneration else { return }
            syncMessage = (error as? HomeLeaveError)?.localizedDescription
                ?? "The household invitation could not be accepted. \(CloudSyncStatus.Failure.classify(error).message)"
        }
        onDataChanged?()
    }

    private func acceptanceEnvironment(_ runtime: Runtime, session: ShopperSession,
        metadata: CKShare.Metadata, generation: Int) throws -> (NSPersistentCloudKitContainer, NSPersistentStore) {
        guard generation == authorityGeneration, current?.persistence === runtime.persistence,
              case .ready(let verified) = provider.state, verified == session,
              try runtime.provider.currentSession() == session,
              runtime.persistence.personalCartInitialBinding == session.accountBinding else { throw PersonalCartError.accountChanged }
        guard metadata.containerIdentifier == session.containerIdentifier, metadata.share.publicPermission == .none,
              metadata.participantRole == .privateUser,
              metadata.participantPermission == .readWrite || metadata.participantPermission == .readOnly,
              metadata.participantStatus == .pending || metadata.participantStatus == .accepted,
              case .managed(_, let sharedURL, let containerID) = runtime.persistence.configuration,
              containerID == session.containerIdentifier,
              sharedURL.deletingLastPathComponent().lastPathComponent == session.accountBinding,
              let cloud = runtime.persistence.container as? NSPersistentCloudKitContainer,
              let store = runtime.persistence.store(for: .participantShared), store.url == sharedURL,
              cloud.persistentStoreCoordinator.persistentStores.contains(where: { $0 === store }),
              let description = cloud.persistentStoreDescriptions.first(where: { $0.url == sharedURL }),
              description.cloudKitContainerOptions?.containerIdentifier == containerID,
              description.cloudKitContainerOptions?.databaseScope == .shared else { throw PersonalCartError.scopeChanged }
        return (cloud, store)
    }
}
