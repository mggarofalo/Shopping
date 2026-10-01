import CoreData
import Observation
import SwiftUI

@Observable @MainActor
final class PersonalCartPresentation {
    private struct Snapshot: Sendable {
        let entries: [PersonalCartEntrySnapshot]
        let history: [PersonalCheckoutHistoryEntry]
        let recovery: PersonalCartRecoverySnapshot?
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
    private(set) var recovery: PersonalCartRecoverySnapshot?
    var pendingLegacyReview: [LegacyCartReviewSnapshot] { recovery?.pendingLegacyReview ?? [] }
    private(set) var error: String?
    private var pendingCartState: [UUID: Bool] = [:]
    private var pendingQuantityIDs: Set<UUID> = []
    private var inFlightNeedIDs: Set<UUID> = []
    private var inFlightQuantityIDs: Set<UUID> = []
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
                    recovery = snapshot.recovery
                    outstandingNeedIDs = snapshot.outstandingNeedIDs
                    presence = snapshot.presence
                    error = snapshot.householdError
                    pendingCartState = pendingCartState.filter { inFlightNeedIDs.contains($0.key) }
                    pendingQuantityIDs.formIntersection(inFlightQuantityIDs)
                case .failure(let failure):
                    error = failure
                    pendingQuantityIDs.formIntersection(inFlightQuantityIDs)
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
            // Discovery failures cannot disable checkout or erase household projections.
            let recovery: PersonalCartRecoverySnapshot?
            do { recovery = try service.recoverySnapshot(householdID: householdID, listID: listID) }
            catch { recovery = nil }
            do {
                return .success(Snapshot(entries: entries, history: history, recovery: recovery,
                    outstandingNeedIDs: try service.outstandingNeedIDs(householdID: householdID, listID: listID),
                    presence: try service.presence(householdID: householdID, listID: listID), householdError: nil))
            } catch {
                // Incomplete household imports cannot hide private removal or purchase history.
                return .success(Snapshot(entries: entries, history: history, recovery: recovery,
                    outstandingNeedIDs: [], presence: [], householdError: error.localizedDescription))
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func isSelected(in selection: PersistenceSelection) -> Bool {
        selection.householdID == householdID && selection.listID == listID
    }

    func canReviewEarlierCleared(in selection: PersistenceSelection) -> Bool {
        isSelected(in: selection) && recovery?.hasEarlierClearedGroceries == true
    }

    func contains(_ needID: UUID) -> Bool {
        pendingCartState[needID] ?? entries.contains { $0.needID == needID }
    }

    func isCartTransitionPending(_ needID: UUID) -> Bool { pendingCartState[needID] != nil }

    func isQuantityTransitionPending(_ entryID: UUID) -> Bool { pendingQuantityIDs.contains(entryID) }

    func visibleEntries(filter: GroceryNeedFilter, activeStoreIDs: Set<UUID>) -> [PersonalCartEntrySnapshot] {
        entries.filter { entry in
            filter.purchase.matches(PurchaseRuleValue(explicitStoreIDs: entry.storeIDs,
                anyStore: entry.anyStore, hasResolvedIdentity: entry.purchaseRulesResolved), activeStoreIDs: activeStoreIDs)
                && (filter.categoryID == nil || entry.categoryID == filter.categoryID)
                && (filter.urgency == nil || entry.urgency == filter.urgency)
                && CatalogProjection.textMatches(entry.title, query: filter.text)
        }
    }

    func cart(_ needID: UUID) async throws {
        guard !inFlightNeedIDs.contains(needID) else { return }
        pendingCartState[needID] = true
        inFlightNeedIDs.insert(needID)
        mutationRevision += 1
        do {
            let service = self.service, householdID = self.householdID, listID = self.listID
            try await Task.detached(priority: .userInitiated) {
                try service.cart(needID: needID, householdID: householdID, listID: listID)
            }.value
            inFlightNeedIDs.remove(needID)
            mutationRevision += 1
            refresh()
        } catch {
            inFlightNeedIDs.remove(needID)
            pendingCartState.removeValue(forKey: needID)
            mutationRevision += 1
            refresh()
            throw error
        }
    }

    func uncart(_ entry: PersonalCartEntrySnapshot) async throws {
        guard !inFlightNeedIDs.contains(entry.needID) else { return }
        pendingCartState[entry.needID] = false
        inFlightNeedIDs.insert(entry.needID)
        mutationRevision += 1
        do {
            let service = self.service
            try await Task.detached(priority: .userInitiated) { try service.uncart(entry.token) }.value
            entries.removeAll { $0.needID == entry.needID }
            inFlightNeedIDs.remove(entry.needID)
            mutationRevision += 1
            refresh()
        } catch {
            inFlightNeedIDs.remove(entry.needID)
            pendingCartState.removeValue(forKey: entry.needID)
            mutationRevision += 1
            refresh()
            throw error
        }
    }

    func setQuantity(_ quantity: Int64?, entry: PersonalCartEntrySnapshot) async throws {
        guard !pendingQuantityIDs.contains(entry.id) else { return }
        pendingQuantityIDs.insert(entry.id)
        inFlightQuantityIDs.insert(entry.id)
        mutationRevision += 1
        do {
            let service = self.service
            try await Task.detached(priority: .userInitiated) {
                try service.setQuantity(quantity, token: entry.token)
            }.value
            inFlightQuantityIDs.remove(entry.id)
            mutationRevision += 1
            refresh()
        } catch {
            inFlightQuantityIDs.remove(entry.id)
            pendingQuantityIDs.remove(entry.id)
            mutationRevision += 1
            refresh()
            throw error
        }
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
