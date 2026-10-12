#if compiler(>=6.4)
import AppIntents

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct GroceryListEntity {
    static let defaultQuery = GroceryListEntityQuery()
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Type") var type: GroceryReminderListType
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    @MainActor init(context: CatalogActionContext) {
        id = context.entityID(for: context.listID)
        name = "Grocery List"
        type = .standard
    }

    struct GroceryListEntityQuery: EntityStringQuery {
        @MainActor func entities(for identifiers: [String]) async throws -> [GroceryListEntity] {
            let current = try await current()
            return identifiers.contains(current.id) ? [current] : []
        }
        @MainActor func entities(matching string: String) async throws -> [GroceryListEntity] {
            guard ["grocery list", "shopping list", "my shopping list", "the shopping list", "groceries", "shopping"].contains(CatalogProjection.normalizedName(string)) else { return [] }
            return [try await current()]
        }
        @MainActor func suggestedEntities() async throws -> [GroceryListEntity] { [try await current()] }
        @MainActor private func current() async throws -> GroceryListEntity {
            let runtime = ShoppingApplicationRuntime.shared
            return try await GroceryListEntity(context: CatalogActionContext(runtime: runtime, ready: runtime.ready()))
        }
    }
}
#endif
