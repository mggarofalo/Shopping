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

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$name) to groceries") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runtime = ShoppingApplicationRuntime.shared
        let context = try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
        let spoken: String
        if let name { spoken = name }
        else if let catalogItem { spoken = catalogItem.name }
        else { spoken = try await $name.requestValue("What would you like to add?") }
        let query = spoken.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !query.isEmpty else { throw NeedServiceError.invalidName }
        try context.validate()
        let candidates = CatalogActionMatcher.matches(query, in: try await context.items())
        if candidates.isEmpty {
            guard catalogItem == nil else { throw ShoppingActionError.scopeChanged }
            try await requestToContinueInForeground("No catalog match for \(query). Continue in Milk & Bananas to create it?") {
                try context.createInApp(name: query)
            }
            return .result(dialog: "Review \(query) in the app, then save and add it.")
        }
        guard candidates.count <= 20 else { throw CatalogActionError.tooManyMatches }
        let token = try await context.capture(candidates)
        let item: CatalogActionItem
        if let catalogItem {
            guard let selected = candidates.first(where: { context.entityID(for: $0.id) == catalogItem.id }) else {
                throw ShoppingActionError.scopeChanged
            }
            item = selected
        } else if candidates.count == 1 {
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
        return .result(dialog: added ? "Added \(item.name) to your grocery list." : "\(item.name) is already on your grocery list.")
    }
}

enum CatalogActionError: LocalizedError {
    case tooManyMatches
    var errorDescription: String? { "Several catalog items match. Please try a more specific item name." }
}
