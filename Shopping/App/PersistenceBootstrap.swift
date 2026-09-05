import CoreData
import Foundation
import SwiftUI

struct PersistenceSelection: Equatable {
    let householdID: UUID?
    let listID: UUID?
}

private struct NeedServiceEnvironmentKey: EnvironmentKey {
    static let defaultValue: NeedService? = nil
}

private struct PersistenceSelectionEnvironmentKey: EnvironmentKey {
    static let defaultValue = PersistenceSelection(householdID: nil, listID: nil)
}

extension EnvironmentValues {
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
    struct ReadyState {
        let persistence: PersistenceController
        let service: NeedService
        let householdID: UUID?
        let listID: UUID?
    }

    enum State {
        case loading
        case ready(ReadyState)
        case failed(Error)
    }

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

    init(
        configuration: @escaping () throws -> PersistenceConfiguration = { try .applicationLocal() },
        preloadedPreviewEnvironment: ShoppingPreviewEnvironment? = nil
    ) {
        self.configuration = configuration
        self.preloadedPreviewEnvironment = preloadedPreviewEnvironment
    }

    static func application(processInfo: ProcessInfo = .processInfo) -> PersistenceBootstrap {
        if let path = processInfo.environment["SHOPPING_UI_TEST_STORE_PATH"] {
            let storeURL = URL(fileURLWithPath: path)
            if let fixtureName = processInfo.environment["SHOPPING_UI_TEST_FIXTURE"],
               let fixture = ShoppingPreviewCase(rawValue: fixtureName) {
                do {
                    let environment = try ShoppingPreviewFixtures.make(fixture, storeURL: storeURL)
                    return PersistenceBootstrap(
                        configuration: { .local(storeURL: storeURL) },
                        preloadedPreviewEnvironment: environment
                    )
                } catch {
                    return PersistenceBootstrap(configuration: { throw error })
                }
            }
            return PersistenceBootstrap(configuration: { .local(storeURL: storeURL) })
        }
        return PersistenceBootstrap()
    }

    deinit {
        if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
        if let associationObserver { NotificationCenter.default.removeObserver(associationObserver) }
    }

    func start() {
        guard case .loading = state else { return }
        load()
    }

    func retry() {
        generation += 1
        state = .loading
        load()
    }

    func applicationDidEnterForeground() {
        consumeHistory()
        retryShareAssociations()
    }

    private func load() {
        do {
            let resolvedConfiguration: PersistenceConfiguration
            let persistence: PersistenceController
            let service: NeedService
            var selection: (householdID: UUID, listID: UUID)?
            if let preview = preloadedPreviewEnvironment {
                resolvedConfiguration = preview.persistence.configuration
                persistence = preview.persistence
                service = preview.service
                selection = (preview.ids.householdID, preview.ids.listID)
                preloadedPreviewEnvironment = nil
            } else {
                resolvedConfiguration = try self.configuration()
                persistence = try PersistenceController(configuration: resolvedConfiguration)
                service = NeedService(persistence: persistence)
                selection = try service.firstHouseholdSelection()
                if selection == nil, !resolvedConfiguration.isManaged, try service.isPersistentStoreEmpty() {
                    let created = try service.createHousehold()
                    selection = (created.householdID, created.listID)
                }
            }
            let checkpointDirectory = (resolvedConfiguration.stores.first?.url?.deletingLastPathComponent())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShoppingHistory")
            let consumer = PersistentHistoryConsumer(
                persistence: persistence,
                checkpoints: FileHistoryCheckpointStore(directory: checkpointDirectory)
            )
            historyConsumer = consumer
            if let journal = persistence.shareAssociationJournal {
                associationWorker = ManagedShareAssociationWorker(persistence: persistence, journal: journal)
            }
            installRemoteObserver(for: persistence)
            installAssociationObserver(for: persistence)
            state = .ready(ReadyState(
                persistence: persistence,
                service: service,
                householdID: selection?.householdID,
                listID: selection?.listID
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
                        listID: selection.listID
                    ))
                }
            } catch {
                guard generation == requestedGeneration else { return }
                state = .failed(error)
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
