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

    init(runtime: ShoppingApplicationRuntime, ready: PersistenceBootstrap.ReadyState) throws {
        guard let householdID = ready.householdID, let listID = ready.listID else {
            throw ShoppingActionError.homeUnavailable
        }
        self.runtime = runtime
        self.ready = ready
        self.householdID = householdID
        self.listID = listID
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
        try validate()
        let service = ready.service, householdID = householdID, listID = listID
        let items = try await Task.detached(priority: .userInitiated) {
            try service.catalogActionItems(householdID: householdID, listID: listID)
        }.value
        try validate()
        return items
    }

    func capture(_ items: [CatalogActionItem]) async throws -> CatalogAddToken {
        try validate()
        let service = ready.service, householdID = householdID, listID = listID
        let preview = try await Task.detached(priority: .userInitiated) {
            try service.captureCatalogAdd(itemIDs: Set(items.map(\.id)), householdID: householdID,
                                          listID: listID, selectedStoreID: nil)
        }.value
        try validate()
        guard preview.token.entries.count == items.count,
              items.allSatisfy({ item in preview.token.entries.contains {
                  $0.itemID == item.id && $0.itemRevision == item.revision
              } }) else { throw ShoppingActionError.scopeChanged }
        return preview.token
    }

    func add(itemID: UUID, using token: CatalogAddToken) async throws -> Bool {
        try validate()
        guard token.householdID == householdID, token.listID == listID,
              let entry = token.entries.first(where: { $0.itemID == itemID }),
              entry.disposition == .add || entry.disposition == .focusExisting || entry.disposition == .needAgain else {
            throw ShoppingActionError.scopeChanged
        }
        let selected = CatalogAddToken(id: token.id, householdID: householdID, listID: listID,
                                       selectedStoreID: nil, entries: [entry])
        let service = ready.service
        let result = try await Task.detached(priority: .userInitiated) {
            try service.applyCatalogAdd(selected, renewCarted: false)
        }.value
        try validate()
        guard result.changedCount == 0, result.missingCount == 0,
              result.archivedCount == 0, result.ineligibleCount == 0 else {
            throw ShoppingActionError.scopeChanged
        }
        if result.addedNeedIDs.count == 1 { return true }
        if result.existingNeedIDs.count == 1 { return false }
        throw ShoppingActionError.scopeChanged
    }

    func entityID(for itemID: UUID) -> String { namespace + ":" + itemID.uuidString.lowercased() }

    func createInApp(name: String) throws {
        try validate()
        try runtime.actions.enqueue(.createItem(name), presentationID: ready.presentation.id)
    }
}
