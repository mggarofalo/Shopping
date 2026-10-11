import AppIntents
import Foundation

struct CatalogItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Catalog item"
    static var defaultQuery = CatalogItemEntityQuery()

    let id: String
    let name: String
    let details: String
    var choiceNumber: Int? = nil

    var displayRepresentation: DisplayRepresentation {
        let title = choiceNumber.map { "\(name), option \($0)" } ?? name
        return DisplayRepresentation(title: "\(title)", subtitle: "\(details)")
    }

    @MainActor init(item: CatalogActionItem, context: CatalogActionContext, choiceNumber: Int? = nil) {
        id = context.entityID(for: item.id)
        name = item.name
        details = item.category + " · " + item.purchaseRules
        self.choiceNumber = choiceNumber
    }
}

struct CatalogItemEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CatalogItemEntity] {
        let context = try await context()
        return try await context.items().filter { identifiers.contains(context.entityID(for: $0.id)) }
            .map { CatalogItemEntity(item: $0, context: context) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CatalogItemEntity] {
        let context = try await context()
        return CatalogActionMatcher.matches(string, in: try await context.items())
            .map { CatalogItemEntity(item: $0, context: context) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CatalogItemEntity] {
        let context = try await context()
        return try await context.items().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(50).map { CatalogItemEntity(item: $0, context: context) }
    }

    @MainActor
    private func context() async throws -> CatalogActionContext {
        let runtime = ShoppingApplicationRuntime.shared
        return try await CatalogActionContext(runtime: runtime, ready: runtime.ready())
    }
}
