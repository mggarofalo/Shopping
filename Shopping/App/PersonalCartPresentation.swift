import CoreData
import Observation
import SwiftUI

@Observable @MainActor
final class PersonalCartPresentation {
    let service: PersonalCartService
    let householdID: UUID
    let listID: UUID
    private(set) var entries: [PersonalCartEntrySnapshot] = []
    private(set) var outstandingNeedIDs: Set<UUID> = []
    private(set) var presence: [PersonalCartPresenceSnapshot] = []
    private(set) var history: [PersonalCheckoutHistoryEntry] = []
    private(set) var error: String?

    init(service: PersonalCartService, householdID: UUID, listID: UUID) {
        self.service = service
        self.householdID = householdID
        self.listID = listID
        refresh()
    }

    func refresh() {
        do {
            let nextEntries = try service.entries(householdID: householdID, listID: listID)
            let nextHistory = try service.history(householdID: householdID, listID: listID)
            entries = nextEntries
            history = nextHistory
        } catch {
            self.error = error.localizedDescription
            return
        }
        do {
            let nextOutstanding = try service.outstandingNeedIDs(householdID: householdID, listID: listID)
            let nextPresence = try service.presence(householdID: householdID, listID: listID)
            outstandingNeedIDs = nextOutstanding
            presence = nextPresence
            error = nil
        } catch {
            // Incomplete household imports cannot hide private removal or purchase history.
            outstandingNeedIDs = []
            presence = []
            self.error = error.localizedDescription
        }
    }

    func contains(_ needID: UUID) -> Bool { entries.contains { $0.needID == needID } }

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
        refresh()
    }

    func uncart(_ entry: PersonalCartEntrySnapshot) throws {
        try service.uncart(entry.token)
        refresh()
    }

    func setQuantity(_ quantity: Int64?, entry: PersonalCartEntrySnapshot) throws {
        try service.setQuantity(quantity, token: entry.token)
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
