import SwiftUI

/// Only editable values are retained; managed objects and command/checkout tokens never are.
@MainActor
final class HomeEditorDraftStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load<T: Decodable>(_ type: T.Type, scope: ActiveHomeScope, editor: String) throws -> T? {
        guard let data = defaults.data(forKey: key(scope: scope, editor: editor)) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, scope: ActiveHomeScope, editor: String) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key(scope: scope, editor: editor))
    }

    func remove(scope: ActiveHomeScope, editor: String) {
        defaults.removeObject(forKey: key(scope: scope, editor: editor))
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
