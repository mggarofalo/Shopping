import CoreData
import Observation
import os
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
    /// The cart as last read or patched by a receipt. `entries` presents it with pending
    /// removals already gone.
    private var confirmedEntries: [PersonalCartEntrySnapshot] = []
    private(set) var outstandingNeedIDs: Set<UUID> = []
    private(set) var presence: [PersonalCartPresenceSnapshot] = []
    private(set) var history: [PersonalCheckoutHistoryEntry] = []
    private(set) var recovery: PersonalCartRecoverySnapshot?
    var pendingLegacyReview: [LegacyCartReviewSnapshot] { recovery?.pendingLegacyReview ?? [] }
    private(set) var error: String?
    /// False until a complete snapshot is read. Until then, empty sets mean "unknown", not "empty".
    private(set) var hasLoadedSnapshot = false
    /// Local edits whose commit has not yet returned. A command's receipt clears them.
    private var pendingCartState: [UUID: Bool] = [:]
    private var pendingQuantityIDs: Set<UUID> = []
    private var refreshInProgress = false
    private var refreshRequested = false
    /// Counts receipts and edits. A read that overlaps one may predate it, so it is
    /// discarded and read again rather than applied over the receipt.
    private var mutationRevision = 0
    private let presencePublisher: PersonalCartPresencePublisher

    init(service: PersonalCartService, householdID: UUID, listID: UUID, presenceDelay: Duration = .seconds(2)) {
        self.service = service
        self.householdID = householdID
        self.listID = listID
        presencePublisher = PersonalCartPresencePublisher(delay: presenceDelay) { [service] needIDs in
            await BlockingWriterWork.run(qos: .utility) {
                let state = PersonalCartService.signposter.beginInterval("Cart presence batch", "needs=\(needIDs.count)")
                defer { PersonalCartService.signposter.endInterval("Cart presence batch", state) }
                return service.republishPresence(each: needIDs)
            }
        }
        refresh()
    }

    func refresh() {
        presencePublisher.retry()
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
                let result = await BlockingWriterWork.run {
                    Self.readSnapshot(service: service, householdID: householdID, listID: listID)
                }
                guard requestedRevision == mutationRevision else {
                    refreshRequested = true
                    continue
                }
                switch result {
                case .success(let snapshot):
                    ShoppingPerformanceTrace.launchEvent("Cart snapshot published", "outstanding=\(snapshot.outstandingNeedIDs.count)")
                    publish(\.confirmedEntries, snapshot.entries)
                    publish(\.history, snapshot.history)
                    publish(\.recovery, snapshot.recovery)
                    publish(\.outstandingNeedIDs, snapshot.outstandingNeedIDs)
                    publish(\.presence, snapshot.presence)
                    publish(\.error, snapshot.householdError)
                    if snapshot.householdError == nil { publish(\.hasLoadedSnapshot, true) }
                case .failure(let failure):
                    publish(\.error, failure)
                }
            } while refreshRequested
            refreshInProgress = false
        }
    }

    /// Every store change refreshes the cart, and `@Observable` notifies readers of any write,
    /// even an equal one. Grocery rows read the cart, so unchanged values must not be rewritten.
    private func publish<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PersonalCartPresentation, Value>,
                                           _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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

    /// A removal leaves the presented cart as soon as it starts, so a swiped row collapses at
    /// once; if its commit fails, clearing the pending state brings the row back.
    var entries: [PersonalCartEntrySnapshot] {
        guard pendingCartState.values.contains(false) else { return confirmedEntries }
        return confirmedEntries.filter { pendingCartState[$0.needID] != false }
    }

    var cartedNeedIDs: Set<UUID> {
        var ids = Set(entries.map(\.needID))
        for (id, carted) in pendingCartState {
            if carted { ids.insert(id) } else { ids.remove(id) }
        }
        return ids
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

    /// An action completes when its local commit returns. Its receipt patches the
    /// cart at once; presence publication and the confirming read follow later.
    func cart(_ needID: UUID) async throws {
        guard pendingCartState[needID] == nil else { return }
        pendingCartState[needID] = true
        mutationRevision += 1
        defer { finishEdit { pendingCartState.removeValue(forKey: needID) } }
        let service = self.service, householdID = self.householdID, listID = self.listID
        let receipt = try await BlockingWriterWork.run {
            try service.cart(needID: needID, householdID: householdID, listID: listID, presencePolicy: .deferred)
        }
        apply(receipt)
    }

    /// Marks the removal pending before returning, so a swipe that removes a row sees the
    /// change in the same update; the returned task is the local commit.
    @discardableResult
    func uncart(_ entry: PersonalCartEntrySnapshot) -> Task<Void, any Error> {
        guard pendingCartState[entry.needID] == nil else { return Task<Void, any Error> {} }
        pendingCartState[entry.needID] = false
        mutationRevision += 1
        let service = self.service
        return Task {
            defer { finishEdit { pendingCartState.removeValue(forKey: entry.needID) } }
            let receipt = try await BlockingWriterWork.run {
                try service.uncart(entry.token, presencePolicy: .deferred)
            }
            apply(receipt)
        }
    }

    func setQuantity(_ quantity: Int64?, entry: PersonalCartEntrySnapshot) async throws {
        guard !pendingQuantityIDs.contains(entry.id) else { return }
        pendingQuantityIDs.insert(entry.id)
        mutationRevision += 1
        defer { finishEdit { pendingQuantityIDs.remove(entry.id) } }
        let service = self.service
        let receipt = try await BlockingWriterWork.run {
            try service.setQuantity(quantity, token: entry.token, presencePolicy: .deferred)
        }
        apply(receipt)
    }

    func prepareCheckout(tokens: [PersonalCartEntryToken], storeID: UUID?) async throws -> PersonalCheckoutToken {
        let service = self.service
        return try await BlockingWriterWork.run { try service.prepareCheckout(tokens: tokens, storeID: storeID) }
    }

    /// Purchased entries leave the cart and groceries as soon as the intent is saved.
    func checkout(_ token: PersonalCheckoutToken, buyAnywayReceiptIDs: Set<UUID>) async throws -> PersonalCheckoutOutcome {
        mutationRevision += 1
        defer { finishEdit {} }
        let service = self.service
        let outcome = try await BlockingWriterWork.run {
            try service.checkout(token, buyAnywayReceiptIDs: buyAnywayReceiptIDs, operationID: token.id,
                                 effects: .deferred)
        }
        publish(\.confirmedEntries, confirmedEntries.filter { !outcome.purchasedNeedIDs.contains($0.needID) })
        publish(\.outstandingNeedIDs, outstandingNeedIDs.subtracting(outcome.purchasedNeedIDs))
        outcome.purchasedNeedIDs.forEach(presencePublisher.markDirty)
        return outcome
    }

    func restore(checkoutID: UUID) async throws -> PersonalCheckoutOutcome {
        mutationRevision += 1
        defer { finishEdit {} }
        let service = self.service
        let outcome = try await BlockingWriterWork.run {
            try service.restore(checkoutID: checkoutID, effects: .deferred)
        }
        outcome.purchasedNeedIDs.forEach(presencePublisher.markDirty)
        return outcome
    }

    private func apply(_ receipt: PersonalCartReceipt) {
        var patched = confirmedEntries.filter { $0.needID != receipt.needID }
        if let entry = receipt.entry { patched.append(entry) }
        publish(\.confirmedEntries, patched)
        presencePublisher.markDirty(receipt.needID)
    }

    /// Clears the edit's pending state whether it committed or failed, then reads
    /// again. Any read already in flight predates this edit and is discarded.
    private func finishEdit(_ clearPending: () -> Void) {
        clearPending()
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
