import Foundation

struct PurchaseRuleValue: Equatable {
    let explicitStoreIDs: Set<UUID>
    let anyStore: Bool
}

enum PurchaseAvailability: Equatable {
    case unavailable
    case mustBuyHere
    case flexibleHere
    case needsStore
}

struct PurchaseFilter: Equatable {
    let selectedStoreID: UUID?
    let includedStoreIDs: Set<UUID>
    let excludedStoreIDs: Set<UUID>
    let requiresAnyStore: Bool?

    init(
        selectedStoreID: UUID? = nil,
        includedStoreIDs: Set<UUID> = [],
        excludedStoreIDs: Set<UUID> = [],
        requiresAnyStore: Bool? = nil
    ) {
        self.selectedStoreID = selectedStoreID
        self.includedStoreIDs = includedStoreIDs
        self.excludedStoreIDs = excludedStoreIDs
        self.requiresAnyStore = requiresAnyStore
    }

    func matches(_ value: PurchaseRuleValue, activeStoreIDs: Set<UUID>) -> Bool {
        let tags = value.explicitStoreIDs.intersection(activeStoreIDs)
        if let selectedStoreID {
            guard activeStoreIDs.contains(selectedStoreID),
                  value.anyStore || tags.contains(selectedStoreID) else { return false }
        }
        guard includedStoreIDs.isEmpty || !tags.isDisjoint(with: includedStoreIDs),
              tags.isDisjoint(with: excludedStoreIDs) else { return false }
        if let requiresAnyStore, value.anyStore != requiresAnyStore { return false }
        return true
    }

    func availability(
        of value: PurchaseRuleValue,
        selectedStoreID: UUID?,
        activeStoreIDs: Set<UUID>
    ) -> PurchaseAvailability {
        let tags = value.explicitStoreIDs.intersection(activeStoreIDs)
        guard let selectedStoreID else {
            return !value.anyStore && tags.isEmpty ? .needsStore : .unavailable
        }
        guard activeStoreIDs.contains(selectedStoreID),
              value.anyStore || tags.contains(selectedStoreID) else { return .unavailable }
        return !value.anyStore && tags == [selectedStoreID] ? .mustBuyHere : .flexibleHere
    }
}

struct CatalogItemFilter: Equatable {
    let purchase: PurchaseFilter
    let text: String
    let categoryID: UUID?

    init(purchase: PurchaseFilter = PurchaseFilter(), text: String = "", categoryID: UUID? = nil) {
        self.purchase = purchase
        self.text = text
        self.categoryID = categoryID
    }
}

struct GroceryNeedFilter: Equatable {
    let purchase: PurchaseFilter
    let text: String
    let categoryID: UUID?
    let carted: Bool?
    let urgency: String?

    init(
        purchase: PurchaseFilter = PurchaseFilter(),
        text: String = "",
        categoryID: UUID? = nil,
        carted: Bool? = nil,
        urgency: String? = nil
    ) {
        self.purchase = purchase
        self.text = text
        self.categoryID = categoryID
        self.carted = carted
        self.urgency = urgency
    }

    func sanitized(activeStoreIDs: Set<UUID>, activeCategoryIDs: Set<UUID>) -> GroceryNeedFilter {
        GroceryNeedFilter(
            purchase: PurchaseFilter(
                selectedStoreID: purchase.selectedStoreID.flatMap {
                    activeStoreIDs.contains($0) ? $0 : nil
                },
                includedStoreIDs: purchase.includedStoreIDs.intersection(activeStoreIDs),
                excludedStoreIDs: purchase.excludedStoreIDs.intersection(activeStoreIDs),
                requiresAnyStore: purchase.requiresAnyStore
            ),
            text: text,
            categoryID: categoryID.flatMap { activeCategoryIDs.contains($0) ? $0 : nil },
            carted: carted,
            urgency: urgency
        )
    }
}

enum CatalogProjection {
    static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    static func suggestionNames(from values: [(name: String, isArchived: Bool)]) -> [String] {
        var namesByKey: [String: String] = [:]
        let sorted = values.sorted {
            let firstKey = normalizedName($0.name)
            let secondKey = normalizedName($1.name)
            return firstKey == secondKey ? $0.name < $1.name : firstKey < secondKey
        }
        for value in sorted where !value.isArchived {
            let displayName = value.name.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            let key = normalizedName(displayName)
            guard !key.isEmpty, namesByKey[key] == nil else { continue }
            namesByKey[key] = displayName
        }
        return namesByKey.values.sorted { normalizedName($0) < normalizedName($1) }
    }


    static func textMatches(_ candidate: String, query: String) -> Bool {
        let query = normalizedName(query)
        return query.isEmpty || normalizedName(candidate).contains(query)
    }
}
