#if compiler(>=6.4)
import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct AddSpokenGroceryIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Add grocery by voice"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Item name") var title: String
    @Parameter(title: "List") var list: GroceryListEntity?
    @Parameter(title: "Note") var note: AttributedString?
    @Parameter(title: "Flagged") var isFlagged: Bool?
    @Parameter(title: "Images", default: [], supportedContentTypes: [.image]) var images: [IntentFile]
    @Parameter(title: "Tags", default: []) var tags: Set<String>
    @Parameter(title: "URLs", default: []) var urls: [URL]
    @Parameter(title: "Due date") var dueDate: DateComponents?
    @Parameter(title: "Recurrence") var recurrence: Calendar.RecurrenceRule?
    @Parameter(title: "Location reminder") var locationTrigger: GroceryReminderLocationEntity?
    @Parameter(title: "Section") var section: GroceryReminderSectionEntity?
    @Parameter(title: "Catalog choice") var catalogChoice: CatalogItemEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GroceryReminderEntity> & ProvidesDialog {
        let runtime = ShoppingApplicationRuntime.shared
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let dialogue = try await prepare(context: context)
        if dialogue.candidates.isEmpty {
            throw needsToContinueInForegroundError("No catalog match for \(dialogue.name). Continue in Milk & Bananas to create it?") {
                try dialogue.createInApp()
            }
        }
        let selectedID: String
        if dialogue.candidates.count == 1 {
            selectedID = context.entityID(for: dialogue.candidates[0].id)
        } else {
            let choices = dialogue.candidates.enumerated().map {
                CatalogItemEntity(item: $0.element, context: context, choiceNumber: $0.offset + 1)
            }
            selectedID = try await $catalogChoice.requestDisambiguation(
                among: choices, dialog: "Which catalog item do you mean?").id
        }
        let (item, needID, added) = try await dialogue.add(entityID: selectedID)
        guard let need = try await context.groceryNeeds(ids: [needID]).first else {
            throw ShoppingActionError.scopeChanged
        }
        let dialog: IntentDialog = added
            ? "Added \(item.name) to your grocery list."
            : "\(item.name) is already on your grocery list."
        return .result(value: GroceryReminderEntity(snapshot: need, context: context), dialog: dialog)
    }
    @MainActor
    func prepare(context: CatalogActionContext) async throws -> CatalogAddDialogue {
        guard note == nil, isFlagged != true, images.isEmpty, tags.isEmpty, urls.isEmpty,
              dueDate == nil, recurrence == nil, locationTrigger == nil, section == nil else {
            throw SpokenGroceryError.unsupportedDetails
        }
        guard list == nil || list?.id == GroceryListEntity(context: context).id else {
            throw ShoppingActionError.scopeChanged
        }
        return try await CatalogAddDialogue(context: context, name: title, entityID: catalogChoice?.id)
    }

}

enum SpokenGroceryError: LocalizedError {
    case unsupportedDetails
    var errorDescription: String? {
        "I can add a grocery name. Add notes or urgency in Milk & Bananas; scheduled reminders and attachments aren’t supported."
    }
}
#endif
