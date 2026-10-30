import CoreData

/// Everything a grocery row displays, read from Core Data once by its screen.
/// Rows compare these values, so a screen update that leaves a row's data unchanged
/// does not rebuild or re-lay out that row (SHOPPING-272). The model includes values
/// from related objects, such as the catalog name and stores, so their changes still update it.
struct GroceryRowModel: Equatable {
    /// The screen's presentation. A new presentation brings a new cart and services, so rows
    /// rebuild with its commands instead of keeping ones bound to the retired presentation.
    let commandScope: UUID?
    let needID: UUID
    let title: String
    let personLabel: String?
    let notes: String
    let isOneTime: Bool
    let isUrgent: Bool
    let quantity: Int64?
    let revision: Int64
    let isCarted: Bool
    let presenceNames: [String]
    let cartActionAvailable: Bool
    let quantityActionAvailable: Bool
    let anyStore: Bool
    let storeLabels: [String]
    let hasSavedStores: Bool
    let hasResolvedIdentity: Bool
    let storeIndicator: GroceryStoreScopeIndicator?

    fileprivate init(
        need: Need,
        context: GroceryRowContext,
        personalCarted: Bool?,
        presenceNames: [String],
        cartActionAvailable: Bool,
        quantityActionAvailable: Bool
    ) {
        let isOneTime = need.kind == NeedKind.oneTime.rawValue
        let assignedStores = need.item?.stores ?? (isOneTime ? need.oneTimeStores : nil) ?? []
        commandScope = context.commandScope
        needID = need.id
        title = need.item?.name ?? need.title
        personLabel = GroceryPersonLabel.text(for: need.person, people: context.people, household: need.list?.household)
        notes = need.notes
        self.isOneTime = isOneTime
        isUrgent = need.urgency == NeedUrgency.urgent.rawValue
        quantity = need.quantity
        revision = need.revision
        isCarted = personalCarted ?? need.carted
        self.presenceNames = presenceNames
        self.cartActionAvailable = cartActionAvailable
        self.quantityActionAvailable = quantityActionAvailable
        anyStore = need.item?.anyStore ?? (isOneTime && need.oneTimeAnyStore)
        storeLabels = assignedStores.map { $0.isArchived ? "\($0.name) (archived)" : $0.name }.sorted()
        hasSavedStores = !assignedStores.isEmpty
        hasResolvedIdentity = isOneTime || need.item != nil
        storeIndicator = GroceryStoreScopeIndicator.value(
            for: need, selectedStoreID: context.selectedStoreID, activeStoreIDs: context.activeStoreIDs)
    }

    var hasSupportingDetails: Bool { isOneTime || !notes.isEmpty || !presenceNames.isEmpty }

    var storeSummary: String {
        CatalogSuggestionPurchaseSummary.text(anyStore: anyStore, savedStoreLabels: storeLabels,
            hasSavedStores: hasSavedStores, hasResolvedIdentity: hasResolvedIdentity)
    }

    var accessibilityDetails: String {
        var values: [String] = []
        if isUrgent { values.append("Urgent") }
        if isOneTime { values.append("One-time") }
        if isCarted { values.append("In cart") }
        if let storeIndicator { values.append(storeIndicator.title) }
        values.append(storeSummary)
        if let quantity { values.append("Quantity \(quantity)") }
        if let personLabel { values.append("For \(personLabel)") }
        if !notes.isEmpty { values.append(notes) }
        return values.joined(separator: ", ")
    }
}

/// The inputs every row on a screen shares, read once per render rather than once per row.
struct GroceryRowContext {
    let commandScope: UUID?
    let people: [Person]
    let selectedStoreID: UUID?
    let activeStoreIDs: Set<UUID>

    init(commandScope: UUID?, people: [Person], selectedStoreID: UUID?, activeStores: [Store]) {
        self.commandScope = commandScope
        self.people = people
        self.selectedStoreID = selectedStoreID
        activeStoreIDs = Set(activeStores.map(\.id))
    }

    func model(for need: Need, personalCarted: Bool? = nil, presenceNames: [String] = [],
               cartActionAvailable: Bool = true, quantityActionAvailable: Bool = true) -> GroceryRowModel {
        GroceryRowModel(need: need, context: self, personalCarted: personalCarted, presenceNames: presenceNames,
            cartActionAvailable: cartActionAvailable, quantityActionAvailable: quantityActionAvailable)
    }
}

extension Notification {
    /// Whether an `NSManagedObjectContextObjectsDidChange` notification changed a catalog item.
    var changesItems: Bool {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey]
        return keys.contains { key in
            (userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is Item } ?? false
        }
    }
}
