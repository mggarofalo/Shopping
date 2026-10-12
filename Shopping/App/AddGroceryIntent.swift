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
        let runtime = ShoppingApplicationRuntime.shared
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let candidates: [CatalogActionItem]
        if let catalogItem {
            candidates = [try await context.resolve(entityID: catalogItem.id, matching: name)]
        } else {
            let spoken: String
            if let name { spoken = name }
            else { spoken = try await $name.requestValue("What would you like to add?") }
            let query = spoken.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            guard !query.isEmpty else { throw NeedServiceError.invalidName }
            try context.validate()
            candidates = CatalogActionMatcher.matches(query, in: try await context.items())
            if candidates.isEmpty {
                try await requestToContinueInForeground("No catalog match for \(query). Continue in Milk & Bananas to create it?") {
                    try context.createInApp(name: query)
                }
                return .result(dialog: "Review \(query) in the app, then save and add it.")
            }
        }
        guard candidates.count <= 20 else { throw CatalogActionError.tooManyMatches }
        let token = try await context.capture(candidates)
        let item: CatalogActionItem
        if candidates.count == 1 {
            item = candidates[0]
        } else {
            let choices = candidates.enumerated().map {
                CatalogItemEntity(item: $0.element, context: context, choiceNumber: $0.offset + 1)
            }
            let selected = try await $catalogItem.requestDisambiguation(among: choices,
                                                                        dialog: "Which catalog item do you mean?")
            try context.validate()
            guard let choice = candidates.first(where: { context.entityID(for: $0.id) == selected.id }) else {
                throw ShoppingActionError.scopeChanged
            }
            item = choice
        }
        let added = try await context.add(itemID: item.id, using: token)
        let dialog: IntentDialog = added
            ? "Added \(item.name) to your grocery list."
            : "\(item.name) is already on your grocery list."
        return .result(dialog: dialog)
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
