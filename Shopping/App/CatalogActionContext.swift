import CryptoKit
import Foundation

/// Retains the same Home and persistence authority throughout a Siri dialogue.
@MainActor
struct CatalogActionContext {
    let runtime: ShoppingApplicationRuntime
    let ready: PersistenceBootstrap.ReadyState
    let householdID: UUID
    let listID: UUID
    let namespace: String
    /// Siri gives up on a request it cannot answer, so a store busy with sync or
    /// another command fails visibly instead of holding the dialogue open.
    let storeTimeout: Duration

    init(runtime: ShoppingApplicationRuntime, ready: PersistenceBootstrap.ReadyState,
         storeTimeout: Duration = .seconds(10)) throws {
        guard let householdID = ready.householdID, let listID = ready.listID else {
            throw ShoppingActionError.homeUnavailable
        }
        self.runtime = runtime
        self.ready = ready
        self.householdID = householdID
        self.listID = listID
        self.storeTimeout = storeTimeout
        let scope = ready.homeScope?.preferenceNamespace ?? "local:\(householdID):\(listID)"
        namespace = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        try Task.checkCancellation()
        switch runtime.bootstrap.homeEntry.root {
        case .activeHome(let scope):
            guard scope == ready.homeScope else { throw ShoppingActionError.scopeChanged }
        case .localHome: break
        default: throw ShoppingActionError.homeUnavailable
        }
        guard ready.presentation.isActive, case .ready(let current) = runtime.bootstrap.state,
              current.presentation.id == ready.presentation.id,
              current.householdID == householdID, current.listID == listID else {
            throw ShoppingActionError.scopeChanged
        }
    }

    func items() async throws -> [CatalogActionItem] {
        let householdID = householdID, listID = listID
        return try await onStore { try $0.catalogActionItems(householdID: householdID, listID: listID) }
    }

    /// Saved shortcuts retain identity across renames, but never across Homes.
    func resolve(entityID: String, matching name: String? = nil) async throws -> CatalogActionItem {
        let current = try await items()
        guard let item = current.first(where: { self.entityID(for: $0.id) == entityID }) else {
            throw ShoppingActionError.scopeChanged
        }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !CatalogActionMatcher.matches(name, in: current).contains(where: { $0.id == item.id }) {
            throw CatalogActionError.conflictingSelection
        }
        return item
    }

    func capture(_ items: [CatalogActionItem]) async throws -> CatalogAddToken {
        let householdID = householdID, listID = listID, itemIDs = Set(items.map(\.id))
        let preview = try await onStore {
            try $0.captureCatalogAdd(itemIDs: itemIDs, householdID: householdID, listID: listID, selectedStoreID: nil)
        }
        guard preview.token.entries.count == items.count,
              items.allSatisfy({ item in preview.token.entries.contains {
                  $0.itemID == item.id && $0.itemRevision == item.revision
              } }) else { throw ShoppingActionError.scopeChanged }
        return preview.token
    }

    func add(itemID: UUID, using token: CatalogAddToken) async throws -> Bool {
        try await addReceipt(itemID: itemID, using: token).added
    }

    func addReceipt(itemID: UUID, using token: CatalogAddToken) async throws -> (needID: UUID, added: Bool) {
        try validate()
        guard token.householdID == householdID, token.listID == listID,
              let entry = token.entries.first(where: { $0.itemID == itemID }),
              entry.disposition == .add || entry.disposition == .focusExisting || entry.disposition == .needAgain else {
            throw ShoppingActionError.scopeChanged
        }
        let selected = CatalogAddToken(id: token.id, householdID: householdID, listID: listID,
                                       selectedStoreID: nil, entries: [entry])
        let result = try await onStore { try $0.applyCatalogAdd(selected, renewCarted: false) }
        guard result.changedCount == 0, result.missingCount == 0,
              result.archivedCount == 0, result.ineligibleCount == 0 else {
            throw ShoppingActionError.scopeChanged
        }
        if let id = result.addedNeedIDs.first, result.addedNeedIDs.count == 1 { return (id, true) }
        if let id = result.existingNeedIDs.first, result.existingNeedIDs.count == 1 { return (id, false) }
        throw ShoppingActionError.scopeChanged
    }

    func groceryNeeds(ids: Set<UUID>) async throws -> [GroceryActionNeed] {
        let householdID = householdID, listID = listID
        return try await onStore { try $0.groceryActionNeeds(ids: ids, householdID: householdID, listID: listID) }
    }

    func oneTimeNeeds() async throws -> [GroceryActionNeed] {
        let householdID = householdID, listID = listID
        return try await onStore { try $0.oneTimeGroceryActionNeeds(householdID: householdID, listID: listID) }
    }

    /// Persistence errors have no spoken text; report them as a user-facing failure.
    private func onStore<Value: Sendable>(
        _ work: @escaping @Sendable (NeedService) throws -> Value
    ) async throws -> Value {
        try validate()
        let service = ready.service
        let value: Value
        do {
            value = try await ShoppingActionDeadline.run(within: storeTimeout, onTimeout: .timedOut) {
                try await BlockingStoreWork.run { try work(service) }
            }
        } catch let error as NeedServiceError {
            throw error == .scopeChanged ? ShoppingActionError.scopeChanged : ShoppingActionError.unavailable
        }
        try validate()
        return value
    }

    func entityID(for itemID: UUID) -> String { namespace + ":" + itemID.uuidString.lowercased() }

    func createInApp(name: String) throws {
        try validate()
        try runtime.actions.enqueue(.createItem(name), presentationID: ready.presentation.id)
    }
}
