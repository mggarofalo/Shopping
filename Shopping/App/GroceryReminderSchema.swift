#if compiler(>=6.4)
import AppIntents

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum GroceryReminderListType: String {
    case standard
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Grocery List"]
}

@available(iOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum GroceryReminderLocationEvent: String {
    case arrive, depart
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Depart"]
}
#endif
