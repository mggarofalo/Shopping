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
    private static let performanceFixtureVersion = 2
    private static let retainedUITestStoreLimit = 12
    private static let retainedUITestHistoryTokenLimit = 24

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
        if let path = processInfo.environment["SHOPPING_UI_TEST_STORE_PATH"] {
            do {
                let storeURL = try uiTestStoreURL(for: path)
                if let fixtureName = processInfo.environment["SHOPPING_UI_TEST_FIXTURE"],
                   let fixture = ShoppingPreviewCase(rawValue: fixtureName) {
                    let environment = try ShoppingPreviewFixtures.make(fixture, storeURL: storeURL)
                    return PersistenceBootstrap(
                        configuration: { .local(storeURL: storeURL) },
                        preloadedPreviewEnvironment: environment
                    )
                }
                return PersistenceBootstrap(configuration: { .local(storeURL: storeURL) })
            } catch {
                return PersistenceBootstrap(configuration: { throw error })
            }
        }
        return PersistenceBootstrap()
    }

    private static func uiTestStoreURL(for path: String) throws -> URL {
        let requestedURL = URL(fileURLWithPath: path)
        if path.hasPrefix("/"), FileManager.default.isWritableFile(
            atPath: requestedURL.deletingLastPathComponent().path
        ) {
            return requestedURL
        }
        let fileName = requestedURL.lastPathComponent
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("UITestStores", isDirectory: true)
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
