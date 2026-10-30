import Foundation

/// Captures catalog choices and write authority once, before either Siri adapter asks a question.
@MainActor
struct CatalogAddDialogue {
    let context: CatalogActionContext
    let name: String
    let candidates: [CatalogActionItem]
    /// A one-time need already on the list with exactly this name, when no catalog item has it.
    let existingOneTime: GroceryActionNeed?
    private let token: CatalogAddToken?

    init(context: CatalogActionContext, name: String?, entityID: String? = nil) async throws {
        self.context = context
        self.name = (name ?? "").split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        if let entityID {
            candidates = [try await context.resolve(entityID: entityID, matching: name)]
            existingOneTime = nil
        } else {
            guard !self.name.isEmpty else { throw NeedServiceError.invalidName }
            let matches = CatalogActionMatcher.matches(self.name, in: try await context.items())
            let normalized = CatalogProjection.normalizedName(self.name)
            // An exact name outranks substring catalog matches, as it does within the catalog.
            if matches.contains(where: { CatalogProjection.normalizedName($0.name) == normalized }) {
                existingOneTime = nil
            } else {
                existingOneTime = try await context.oneTimeNeeds()
                    .filter { CatalogProjection.normalizedName($0.title) == normalized }
                    .min { $0.id.uuidString < $1.id.uuidString }
            }
            candidates = existingOneTime == nil ? matches : []
        }
        guard candidates.count <= 20 else { throw CatalogActionError.tooManyMatches }
        token = candidates.isEmpty ? nil : try await context.capture(candidates)
    }

    func add(entityID: String) async throws -> (item: CatalogActionItem, needID: UUID, added: Bool) {
        try context.validate()
        guard let token, let item = candidates.first(where: { context.entityID(for: $0.id) == entityID }) else {
            throw ShoppingActionError.scopeChanged
        }
        let receipt = try await context.addReceipt(itemID: item.id, using: token)
        return (item, receipt.needID, receipt.added)
    }

    /// Checked before asking to continue in the app, so Siri's re-run never prompts twice.
    func rejectRepeatedCreation() throws {
        try context.rejectRepeatedCreation(name: name)
    }

    func createInApp() throws {
        guard candidates.isEmpty, existingOneTime == nil else { throw CatalogActionError.conflictingSelection }
        try context.createInApp(name: name)
    }
}
