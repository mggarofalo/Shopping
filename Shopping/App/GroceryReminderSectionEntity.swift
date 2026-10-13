#if compiler(>=6.4)
import AppIntents

/// Required schema type. The Add action rejects sections; it never invents category assignments.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct GroceryReminderSectionEntity {
    static let defaultQuery = GroceryReminderSectionEntityQuery()
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "List") var list: GroceryListEntity
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    struct GroceryReminderSectionEntityQuery: EntityStringQuery {
        func entities(matching string: String) async throws -> [GroceryReminderSectionEntity] { [] }
        func entities(for identifiers: [String]) async throws -> [GroceryReminderSectionEntity] { [] }
    }
}
#endif
