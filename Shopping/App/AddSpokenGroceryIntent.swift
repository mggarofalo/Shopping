#if compiler(>=6.4)
import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct AddSpokenGroceryIntent: AppIntent {
    static var title: LocalizedStringResource = "Add grocery by voice"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    /// Siri runs the app in the background; only an unknown name moves to the app's editor.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
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

    /// No reminder exists for an unknown name until the user saves it in the app.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<GroceryReminderEntity?> & ProvidesDialog {
        SiriActionLog.started("Spoken add")
        do throws(SpokenGroceryError) {
            try rejectUnsupportedDetails()
        } catch {
            SiriActionLog.finished("Spoken add", "declined \(error)")
            throw error
        }
        do {
            let runtime = ShoppingApplicationRuntime.shared
            let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
            let dialogue = try await prepare(context: context)
            if let need = dialogue.existingOneTime {
                SiriActionLog.finished("Spoken add", "existing one-time need")
                return .result(value: GroceryReminderEntity(snapshot: need, context: context),
                               dialog: "\(need.title) is already on your grocery list.")
            }
            if dialogue.candidates.isEmpty {
                try await handOff(dialogue)
                SiriActionLog.finished("Spoken add", "handed off to the editor")
                return .result(value: nil, dialog: "Review \(dialogue.name) in Milk & Bananas, then save and add it.")
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
            SiriActionLog.finished("Spoken add", added ? "added" : "existing catalog need")
            let dialog: IntentDialog = added
                ? "Added \(item.name) to your grocery list."
                : "\(item.name) is already on your grocery list."
            return .result(value: GroceryReminderEntity(snapshot: need, context: context), dialog: dialog)
        } catch {
            SiriActionLog.failed("Spoken add", error)
            throw error
        }
    }

    /// The editor request is queued only once the app is in front; a declined
    /// handoff queues nothing. When already in front, continuing stalled the action
    /// in system execution (SHOPPING-258), so the request is queued directly.
    /// A handoff returns no reminder, which Siri AI treats as unfinished and re-runs
    /// (SHOPPING-271); that re-run is refused before it can ask to continue again.
    @MainActor
    func handOff(_ dialogue: CatalogAddDialogue) async throws {
        try dialogue.rejectRepeatedCreation()
        if systemContext.currentMode != .foreground {
            try await continueInForeground("No catalog match for \(dialogue.name). Continue in Milk & Bananas to create it?")
        }
        try dialogue.createInApp()
    }

    /// Siri offers this app for any reminder (SHOPPING-270), and the schema cannot be
    /// narrowed, so `perform()` declines a timed or repeating reminder before it waits
    /// for the store. No location entity resolves, so a location trigger only lands here
    /// if Siri supplies one. A grocery need has nowhere to keep the other details either.
    func rejectUnsupportedDetails() throws(SpokenGroceryError) {
        guard dueDate == nil, recurrence == nil, locationTrigger == nil else {
            throw SpokenGroceryError.scheduledReminder
        }
        guard note == nil, isFlagged != true, images.isEmpty, tags.isEmpty, urls.isEmpty, section == nil else {
            throw SpokenGroceryError.unsupportedDetails
        }
    }

    @MainActor
    func prepare(context: CatalogActionContext) async throws -> CatalogAddDialogue {
        guard list == nil || list?.id == GroceryListEntity(context: context).id else {
            throw ShoppingActionError.scopeChanged
        }
        return try await CatalogAddDialogue(context: context, name: title, entityID: catalogChoice?.id)
    }
}

enum SpokenGroceryError: LocalizedError {
    case scheduledReminder, unsupportedDetails
    var errorDescription: String? {
        switch self {
        case .scheduledReminder:
            "Milk & Bananas only keeps your grocery list, so it can’t set timed or location reminders. Ask again and choose Reminders."
        case .unsupportedDetails:
            "I can add a grocery name. Add notes or urgency in Milk & Bananas; attachments and tags aren’t supported."
        }
    }
}
#endif
