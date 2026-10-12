#if compiler(>=6.4)
import AppIntents
import Foundation

@available(iOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct GroceryReminderEntity {
    static let defaultQuery = GroceryReminderEntityQuery()
    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Note") var note: AttributedString?
    @Property(title: "Tags") var tags: Set<String>
    @Property(title: "URLs") var urls: [URL]
    @Property(title: "Due date") var dueDate: DateComponents?
    @Property(title: "Recurrence") var recurrence: Calendar.RecurrenceRule?
    @Property(title: "Completed") var isCompleted: Bool
    @Property(title: "Urgent") var isFlagged: Bool?
    @Property(title: "Created") var creationDate: Date?
    @Property(title: "Completed on") var completionDate: Date?
    @Property(title: "List") var list: GroceryListEntity
    @Property(title: "Location reminder") var locationTrigger: GroceryReminderLocationEntity?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    @MainActor init(snapshot: GroceryActionNeed, context: CatalogActionContext) {
        id = context.entityID(for: snapshot.id)
        title = snapshot.title
        note = snapshot.notes.isEmpty ? nil : AttributedString(snapshot.notes)
        tags = []; urls = []; dueDate = nil; recurrence = nil
        isCompleted = false; isFlagged = snapshot.urgent
        creationDate = nil; completionDate = nil
        list = GroceryListEntity(context: context); locationTrigger = nil
    }

    struct GroceryReminderEntityQuery: EntityQuery {
        @MainActor func entities(for identifiers: [String]) async throws -> [GroceryReminderEntity] {
            let runtime = ShoppingApplicationRuntime.shared
            let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
            let ids = Set(identifiers.compactMap { identifier -> UUID? in
                let parts = identifier.split(separator: ":")
                guard parts.count == 2, String(parts[0]) == context.namespace else { return nil }
                return UUID(uuidString: String(parts[1]))
            })
            return try await context.groceryNeeds(ids: ids).map { GroceryReminderEntity(snapshot: $0, context: context) }
        }
        func suggestedEntities() async throws -> [GroceryReminderEntity] { [] }
    }
}
#endif
