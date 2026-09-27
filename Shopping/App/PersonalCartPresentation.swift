import CoreData
import Observation
import SwiftUI

@Observable @MainActor
final class PersonalCartPresentation {
    private struct Snapshot: Sendable {
        let entries: [PersonalCartEntrySnapshot]
        let history: [PersonalCheckoutHistoryEntry]
        let outstandingNeedIDs: Set<UUID>
        let presence: [PersonalCartPresenceSnapshot]
        let householdError: String?
    }
    private enum SnapshotResult: Sendable {
        case success(Snapshot)
        case failure(String)
    }

    let service: PersonalCartService
    let householdID: UUID
    let listID: UUID
    private(set) var entries: [PersonalCartEntrySnapshot] = []
    private(set) var outstandingNeedIDs: Set<UUID> = []
    private(set) var presence: [PersonalCartPresenceSnapshot] = []
    private(set) var history: [PersonalCheckoutHistoryEntry] = []
    private(set) var error: String?
    private var pendingCartState: [UUID: Bool] = [:]
    private var refreshInProgress = false
    private var refreshRequested = false
    private var mutationRevision = 0

    init(service: PersonalCartService, householdID: UUID, listID: UUID) {
        self.service = service
        self.householdID = householdID
        self.listID = listID
        refresh()
    }

    func refresh() {
        refreshRequested = true
        guard !refreshInProgress else { return }
        refreshInProgress = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshRequested = false
                let requestedRevision = mutationRevision
                let service = self.service
                let householdID = self.householdID
                let listID = self.listID
                let result = await Task.detached(priority: .userInitiated) {
                    Self.readSnapshot(service: service, householdID: householdID, listID: listID)
                }.value
                guard requestedRevision == mutationRevision else {
                    refreshRequested = true
                    continue
                }
                switch result {
                case .success(let snapshot):
                    entries = snapshot.entries
                    history = snapshot.history
                    outstandingNeedIDs = snapshot.outstandingNeedIDs
                    presence = snapshot.presence
                    error = snapshot.householdError
                    pendingCartState.removeAll()
                case .failure(let failure):
                    error = failure
                }
            } while refreshRequested
            refreshInProgress = false
        }
    }

    nonisolated private static func readSnapshot(
        service: PersonalCartService, householdID: UUID, listID: UUID
    ) -> SnapshotResult {
        do {
            let entries = try service.entries(householdID: householdID, listID: listID)
            let history = try service.history(householdID: householdID, listID: listID)
            do {
                return .success(Snapshot(entries: entries, history: history,
                    outstandingNeedIDs: try service.outstandingNeedIDs(householdID: householdID, listID: listID),
                    presence: try service.presence(householdID: householdID, listID: listID), householdError: nil))
            } catch {
                // Incomplete household imports cannot hide private removal or purchase history.
                return .success(Snapshot(entries: entries, history: history,
                    outstandingNeedIDs: [], presence: [], householdError: error.localizedDescription))
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func contains(_ needID: UUID) -> Bool {
        pendingCartState[needID] ?? entries.contains { $0.needID == needID }
    }

    func isCartTransitionPending(_ needID: UUID) -> Bool { pendingCartState[needID] != nil }

    func visibleEntries(filter: GroceryNeedFilter, activeStoreIDs: Set<UUID>) -> [PersonalCartEntrySnapshot] {
        entries.filter { entry in
            filter.purchase.matches(PurchaseRuleValue(explicitStoreIDs: entry.storeIDs,
                anyStore: entry.anyStore, hasResolvedIdentity: entry.purchaseRulesResolved), activeStoreIDs: activeStoreIDs)
                && (filter.categoryID == nil || entry.categoryID == filter.categoryID)
                && (filter.urgency == nil || entry.urgency == filter.urgency)
                && CatalogProjection.textMatches(entry.title, query: filter.text)
        }
    }

    func cart(_ needID: UUID) throws {
        try service.cart(needID: needID, householdID: householdID, listID: listID)
        pendingCartState[needID] = true
        mutationRevision += 1
        refresh()
    }

    func uncart(_ entry: PersonalCartEntrySnapshot) throws {
        try service.uncart(entry.token)
        entries.removeAll { $0.needID == entry.needID }
        pendingCartState[entry.needID] = false
        mutationRevision += 1
        refresh()
    }

    func setQuantity(_ quantity: Int64?, entry: PersonalCartEntrySnapshot) throws {
        try service.setQuantity(quantity, token: entry.token)
        mutationRevision += 1
        refresh()
    }
}

private struct PersonalCartEnvironmentKey: EnvironmentKey {
    static let defaultValue: PersonalCartPresentation? = nil
}

private struct PersonalCartActivationActionKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var activatePersonalCart: ((Bool) -> Void)? {
        get { self[PersonalCartActivationActionKey.self] }
        set { self[PersonalCartActivationActionKey.self] = newValue }
    }
    var personalCart: PersonalCartPresentation? {
        get { self[PersonalCartEnvironmentKey.self] }
        set { self[PersonalCartEnvironmentKey.self] = newValue }
    }
}
