import SwiftUI

/// Only editable values are retained; managed objects and command/checkout tokens never are.
@MainActor
final class HomeEditorDraftStore {
    struct Lease {
        let scope: ActiveHomeScope
        let editor: String
        fileprivate let id: UUID
    }
    private let defaults: UserDefaults
    private var leases: [String: UUID] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func open(scope: ActiveHomeScope, editor: String) -> Lease {
        let lease = Lease(scope: scope, editor: editor, id: UUID())
        leases[key(scope: scope, editor: editor)] = lease.id
        return lease
    }

    func currentLease(scope: ActiveHomeScope?, editor: String) -> Lease? {
        guard let scope, let id = leases[key(scope: scope, editor: editor)] else { return nil }
        return Lease(scope: scope, editor: editor, id: id)
    }

    func save<T: Encodable>(_ value: T, lease: Lease) throws {
        guard leases[key(scope: lease.scope, editor: lease.editor)] == lease.id else { return }
        try save(value, scope: lease.scope, editor: lease.editor)
    }

    func finish(_ lease: Lease) {
        guard leases[key(scope: lease.scope, editor: lease.editor)] == lease.id else { return }
        remove(scope: lease.scope, editor: lease.editor)
    }

    func load<T: Decodable>(_ type: T.Type, scope: ActiveHomeScope, editor: String) throws -> T? {
        guard let data = defaults.data(forKey: key(scope: scope, editor: editor)) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, scope: ActiveHomeScope, editor: String) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key(scope: scope, editor: editor))
    }

    func remove(scope: ActiveHomeScope, editor: String) {
        let root = key(scope: scope, editor: editor)
        // Nested category/store drafts belong to this editor, never to its next use.
        for entry in defaults.dictionaryRepresentation().keys where entry == root || entry.hasPrefix(root + ".") {
            defaults.removeObject(forKey: entry)
        }
        leases = leases.filter { $0.key != root && !$0.key.hasPrefix(root + ".") }
    }

    private func key(scope: ActiveHomeScope, editor: String) -> String {
        "shopping.editorDraft.v1.\(scope.preferenceNamespace).\(editor)"
    }
}

private struct HomeEditorDraftStoreKey: EnvironmentKey {
    static let defaultValue: HomeEditorDraftStore? = nil
}

extension EnvironmentValues {
    var homeEditorDraftStore: HomeEditorDraftStore? {
        get { self[HomeEditorDraftStoreKey.self] }
        set { self[HomeEditorDraftStoreKey.self] = newValue }
    }
}

struct GroceryEditorDraft: Codable, Equatable {
    var remembered: Bool
    var name: String
    var catalogNotes: String
    var purchaseNotes: String
    var quantity: Int?
    var urgency: String
    var categoryID: UUID?
    var storeIDs: Set<UUID>
    var anyStore: Bool
    var personID: UUID?
    var isPromotingOneTime: Bool
    var promotionChoice: String
    var catalogSearch: String
    var selectedCatalogItemID: UUID?
}

struct CatalogEditorDraft: Codable, Equatable {
    var itemID: UUID?
    var name: String
    var notes: String
    var categoryID: UUID?
    var anyStore: Bool
    var storeIDs: Set<UUID>
}
