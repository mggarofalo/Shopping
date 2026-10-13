#if compiler(>=6.4)
import AppIntents
import GeoToolbox

/// Required schema type. Grocery additions do not create location reminders.
@available(iOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct GroceryReminderLocationEntity {
    static let defaultQuery = GroceryReminderLocationEntityQuery()
    let id: String
    @Property(title: "Place") var place: PlaceDescriptor
    @Property(title: "Event") var event: GroceryReminderLocationEvent
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Location reminder") }
    struct GroceryReminderLocationEntityQuery: EntityStringQuery {
        func entities(matching string: String) async throws -> [GroceryReminderLocationEntity] { [] }
        func entities(for identifiers: [String]) async throws -> [GroceryReminderLocationEntity] { [] }
    }
}
#endif
