import Foundation

/// Captures catalog choices and write authority once, before either Siri adapter asks a question.
@MainActor
struct CatalogAddDialogue {
    let context: CatalogActionContext
    let name: String
    let candidates: [CatalogActionItem]
    private let token: CatalogAddToken?

    init(context: CatalogActionContext, name: String?, entityID: String? = nil) async throws {
        self.context = context
        self.name = (name ?? "").split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        if let entityID {
            candidates = [try await context.resolve(entityID: entityID, matching: name)]
        } else {
            guard !self.name.isEmpty else { throw NeedServiceError.invalidName }
            candidates = CatalogActionMatcher.matches(self.name, in: try await context.items())
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

    func createInApp() throws {
        guard candidates.isEmpty else { throw CatalogActionError.conflictingSelection }
        try context.createInApp(name: name)
    }
}
