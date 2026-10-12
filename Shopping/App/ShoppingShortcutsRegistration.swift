import AppIntents
import Combine
import CoreData
import Foundation

/// Owns system suggestions separately from catalog queries and persistence writes.
@MainActor
final class ShoppingShortcutsRegistration {
    private weak var bootstrap: PersistenceBootstrap?
    private let update: () -> Void
    private var scopeID: UUID?
    private var scopeObservation: AnyCancellable?
    private var catalogObservation: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    init(bootstrap: PersistenceBootstrap,
         update: @escaping () -> Void = { ShoppingShortcuts.updateAppShortcutParameters() }) {
        self.bootstrap = bootstrap
        self.update = update
        bindCurrentScope()
        update()
        // objectWillChange fires before publication; read the new state next turn.
        scopeObservation = bootstrap.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.scopeChanged() }
    }

    deinit { refreshTask?.cancel() }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.update()
        }
    }

    private var currentReady: PersistenceBootstrap.ReadyState? {
        guard let bootstrap, case .ready(let ready) = bootstrap.state,
              ready.presentation.isActive, ready.householdID != nil, ready.listID != nil else { return nil }
        switch bootstrap.homeEntry.root {
        case .activeHome, .localHome: return ready
        default: return nil
        }
    }

    private func scopeChanged() {
        guard currentReady?.presentation.id != scopeID else { return }
        bindCurrentScope()
        refresh()
    }

    private func bindCurrentScope() {
        catalogObservation = nil
        let ready = currentReady
        scopeID = ready?.presentation.id
        guard let ready else { return }
        let notifications = NotificationCenter.default
        catalogObservation = notifications.publisher(for: .NSManagedObjectContextDidSaveObjectIDs,
                                                       object: ready.persistence.writer)
            .merge(with: notifications.publisher(for: .NSManagedObjectContextDidMergeChangesObjectIDs,
                                                   object: ready.persistence.container.viewContext))
            // Inspect IDs on the posting queue; no managed objects cross queues.
            .filter(Self.changesCatalog)
            .map { _ in () }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
    }

    nonisolated private static func changesCatalog(_ notification: Notification) -> Bool {
        [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey].contains { key in
            let ids = notification.userInfo?[key] as? Set<NSManagedObjectID> ?? []
            return ids.contains { ["Item", "Category", "Store"].contains($0.entity.name ?? "") }
        }
    }
}
