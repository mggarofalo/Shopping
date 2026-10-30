import AppIntents
import Foundation

struct AddGroceryIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Add item"
    static var description = IntentDescription("Add a remembered item to your selected Home, or create a new item in the app.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Item name", requestValueDialog: "What would you like to add?")
    var name: String?

    @Parameter(title: "Catalog item")
    var catalogItem: CatalogItemEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$catalogItem, .hasAnyValue) {
            Summary("Add \(\.$catalogItem) to groceries")
        } otherwise: {
            Summary("Add \(\.$name) to groceries")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriActionLog.started("Prompted add")
        do {
            return try await .result(dialog: add())
        } catch {
            SiriActionLog.failed("Prompted add", error)
            throw error
        }
    }

    @MainActor
    private func add() async throws -> IntentDialog {
        let runtime = ShoppingApplicationRuntime.shared
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let spoken: String?
        if catalogItem != nil || name != nil { spoken = name }
        else { spoken = try await $name.requestValue("What would you like to add?") }
        let dialogue = try await CatalogAddDialogue(context: context, name: spoken, entityID: catalogItem?.id)
        if let need = dialogue.existingOneTime {
            SiriActionLog.finished("Prompted add", "existing one-time need")
            return "\(need.title) is already on your grocery list."
        }
        if dialogue.candidates.isEmpty {
            try dialogue.rejectRepeatedCreation()
            try await requestToContinueInForeground("No catalog match for \(dialogue.name). Continue in Milk & Bananas to create it?") {
                try dialogue.createInApp()
            }
            SiriActionLog.finished("Prompted add", "handed off to the editor")
            return "Review \(dialogue.name) in the app, then save and add it."
        }
        let selectedID: String
        if dialogue.candidates.count == 1 {
            selectedID = context.entityID(for: dialogue.candidates[0].id)
        } else {
            let choices = dialogue.candidates.enumerated().map {
                CatalogItemEntity(item: $0.element, context: context, choiceNumber: $0.offset + 1)
            }
            selectedID = try await $catalogItem.requestDisambiguation(
                among: choices, dialog: "Which catalog item do you mean?").id
        }
        let (item, _, added) = try await dialogue.add(entityID: selectedID)
        SiriActionLog.finished("Prompted add", added ? "added" : "existing catalog need")
        return added
            ? "Added \(item.name) to your grocery list."
            : "\(item.name) is already on your grocery list."
    }
}

enum CatalogActionError: LocalizedError, Equatable {
    case tooManyMatches, conflictingSelection

    var errorDescription: String? {
        switch self {
        case .tooManyMatches:
            return "Several catalog items match. Please try a more specific item name."
        case .conflictingSelection:
            return "The item name and selected catalog item do not match. Choose one item and try again."
        }
    }
}
