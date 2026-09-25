import CoreData
import SwiftUI

struct ItemCollectionSection<SectionID: Hashable, Item>: Identifiable {
    let id: SectionID
    let title: String
    let items: [Item]
}

struct ItemCollectionSections<SectionID: Hashable, ItemID: Hashable, Item, Row: View>: View {
    let sections: [ItemCollectionSection<SectionID, Item>]
    let itemID: KeyPath<Item, ItemID>
    @ViewBuilder let row: (SectionID, Item) -> Row

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items, id: itemID) { item in
                    row(section.id, item)
                }
            } header: {
                Text(section.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.grocerySecondary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

enum CatalogCollectionSectionID: Hashable {
    case category(UUID)
    case unavailable
    case uncategorized
}

enum CatalogCollectionProjection {
    static func sections(
        items: [Item],
        categories: [Category],
        household: Household?
    ) -> [ItemCollectionSection<CatalogCollectionSectionID, Item>] {
        let globallyOrdered = CategoryGrouping.ordered(categories, household: household)
        let settingsOrdered = globallyOrdered.filter { !$0.isArchived } + globallyOrdered.filter(\.isArchived)
        let validCategoryObjects = Set(settingsOrdered.map(\.objectID))
        var remaining = items
        var sections: [ItemCollectionSection<CatalogCollectionSectionID, Item>] = []

        for category in settingsOrdered {
            let matching = remaining.filter { $0.category?.objectID == category.objectID }
            guard !matching.isEmpty else { continue }
            sections.append(ItemCollectionSection(
                id: .category(category.id),
                title: category.name,
                items: sorted(matching)
            ))
            remaining.removeAll { $0.category?.objectID == category.objectID }
        }

        let unavailable = remaining.filter {
            guard let category = $0.category else { return false }
            return !validCategoryObjects.contains(category.objectID)
        }
        if !unavailable.isEmpty {
            sections.append(ItemCollectionSection(
                id: .unavailable,
                title: "Unavailable category",
                items: sorted(unavailable)
            ))
        }

        let uncategorized = remaining.filter { $0.category == nil }
        if !uncategorized.isEmpty {
            sections.append(ItemCollectionSection(
                id: .uncategorized,
                title: "Uncategorized",
                items: sorted(uncategorized)
            ))
        }
        return sections
    }

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }
}

enum GroceryCollectionSectionID: Hashable {
    case category(CategoryNeedGroupID)
}

enum GroceryCollectionProjection {
    static func sections(
        needs: [Need],
        selectedStoreID: UUID?,
        activeStores: [Store],
        categories: [Category],
        household: Household?
    ) -> [ItemCollectionSection<GroceryCollectionSectionID, Need>] {
        let projectedNeeds: [Need]
        if let selectedStoreID {
            let activeStoreIDs = Set(activeStores.map(\.id))
            projectedNeeds = needs.filter {
                let value = availability(
                    of: $0,
                    selectedStoreID: selectedStoreID,
                    activeStoreIDs: activeStoreIDs
                )
                return value == .mustBuyHere || value == .flexibleHere
            }
        } else {
            projectedNeeds = needs
        }

        return CategoryGrouping.listGroups(
            needs: projectedNeeds,
            categories: categories,
            household: household
        ).map {
            ItemCollectionSection(
                id: .category($0.id),
                title: $0.title,
                items: $0.needs
            )
        }
    }

    static func availability(
        of need: Need,
        selectedStoreID: UUID,
        activeStoreIDs: Set<UUID>
    ) -> PurchaseAvailability {
        let item = need.item
        let oneTime = need.kind == NeedKind.oneTime.rawValue
        let value = PurchaseRuleValue(
            explicitStoreIDs: item.map { Set($0.stores?.map(\.id) ?? []) }
                ?? (oneTime ? Set(need.oneTimeStores?.map(\.id) ?? []) : []),
            anyStore: item?.anyStore ?? (oneTime && need.oneTimeAnyStore),
            hasResolvedIdentity: item != nil || oneTime
        )
        return PurchaseFilter().availability(
            of: value,
            selectedStoreID: selectedStoreID,
            activeStoreIDs: activeStoreIDs
        )
    }
}

enum GroceryStoreScopeIndicator: Equatable {
    case onlyBuyHere
    case canBuyHere

    var title: String {
        switch self {
        case .onlyBuyHere: "Only buy here"
        case .canBuyHere: "Can buy here"
        }
    }

    var symbol: String {
        switch self {
        case .onlyBuyHere: "lock.fill"
        case .canBuyHere: "lock.open.fill"
        }
    }

    var identifierComponent: String {
        switch self {
        case .onlyBuyHere: "onlyBuyHere"
        case .canBuyHere: "canBuyHere"
        }
    }

    static func value(
        for need: Need,
        selectedStoreID: UUID?,
        activeStoreIDs: Set<UUID>
    ) -> GroceryStoreScopeIndicator? {
        guard let selectedStoreID else { return nil }
        switch GroceryCollectionProjection.availability(
            of: need,
            selectedStoreID: selectedStoreID,
            activeStoreIDs: activeStoreIDs
        ) {
        case .mustBuyHere: return .onlyBuyHere
        case .flexibleHere: return .canBuyHere
        case .unavailable, .needsStore: return nil
        }
    }
}

enum CategoryGrouping {
    static func ordered(_ categories: [Category], household: Household?) -> [Category] {
        guard let household, let persistentStore = household.objectID.persistentStore else { return [] }
        let counts = Dictionary(grouping: categories, by: \.id).mapValues(\.count)
        let scoped = categories.filter {
            $0.household == household && $0.objectID.persistentStore == persistentStore &&
                $0.id != PersistenceModel.unsetID && counts[$0.id] == 1
        }
        return scoped.sorted {
            if $0.displayOrder != $1.displayOrder { return $0.displayOrder < $1.displayOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func listGroups(
        needs: [Need],
        categories: [Category],
        household: Household?
    ) -> [CategoryNeedGroup] {
        let globallyOrdered = ordered(categories, household: household)
        let settingsOrdered = globallyOrdered.filter { !$0.isArchived } + globallyOrdered.filter(\.isArchived)
        return categoryGroups(
            needs: needs,
            orderedCategories: settingsOrdered,
            validObjects: Set(settingsOrdered.map(\.objectID)),
            sort: sortedForShoppingList
        )
    }

    static func orderedNeeds(
        _ needs: [Need],
        categories: [Category],
        household: Household?
    ) -> [Need] {
        listGroups(needs: needs, categories: categories, household: household)
            .flatMap(\.needs)
    }

    static func groups(
        needs: [Need],
        categories: [Category],
        household: Household?
    ) -> [PriorityCategoryNeedGroup] {
        let orderedCategories = ordered(categories, household: household)
        let validObjects = Set(orderedCategories.map(\.objectID))
        return [NeedUrgency.urgent, .normal].compactMap { urgency in
            let matchingUrgency = needs.filter {
                (NeedUrgency(rawValue: $0.urgency) ?? .normal) == urgency
            }
            guard !matchingUrgency.isEmpty else { return nil }
            let categories = categoryGroups(
                needs: matchingUrgency,
                orderedCategories: orderedCategories,
                validObjects: validObjects,
                sort: sortedNames
            )
            return PriorityCategoryNeedGroup(urgency: urgency, categories: categories)
        }
    }

    private static func categoryGroups(
        needs: [Need],
        orderedCategories: [Category],
        validObjects: Set<NSManagedObjectID>,
        sort: ([Need]) -> [Need]
    ) -> [CategoryNeedGroup] {
        var remaining = needs
        var groups: [CategoryNeedGroup] = []
        for category in orderedCategories {
            let matching = remaining.filter { categoryObject(for: $0)?.objectID == category.objectID }
            guard !matching.isEmpty else { continue }
            groups.append(CategoryNeedGroup(
                id: .category(category.id), categoryID: category.id,
                title: category.name, needs: sort(matching)
            ))
            remaining.removeAll { categoryObject(for: $0)?.objectID == category.objectID }
        }
        let unavailable = remaining.filter {
            guard let category = categoryObject(for: $0) else { return false }
            return !validObjects.contains(category.objectID)
        }
        if !unavailable.isEmpty {
            groups.append(CategoryNeedGroup(
                id: .unavailable, categoryID: nil,
                title: "Unavailable category", needs: sort(unavailable)
            ))
        }
        let uncategorized = remaining.filter { categoryObject(for: $0) == nil }
        if !uncategorized.isEmpty {
            groups.append(CategoryNeedGroup(
                id: .uncategorized, categoryID: nil,
                title: "Uncategorized", needs: sort(uncategorized)
            ))
        }
        return groups
    }

    private static func categoryObject(for need: Need) -> Category? {
        if let item = need.item { return item.category }
        return need.kind == NeedKind.oneTime.rawValue ? need.oneTimeCategory : nil
    }

    private static func sortedForShoppingList(_ needs: [Need]) -> [Need] {
        needs.sorted {
            let leftUrgency = NeedUrgency(rawValue: $0.urgency) ?? .normal
            let rightUrgency = NeedUrgency(rawValue: $1.urgency) ?? .normal
            if leftUrgency != rightUrgency { return leftUrgency == .urgent }
            return orderedByNameThenID($0, $1)
        }
    }

    private static func sortedNames(_ needs: [Need]) -> [Need] {
        needs.sorted(by: orderedByNameThenID)
    }

    private static func orderedByNameThenID(_ left: Need, _ right: Need) -> Bool {
        let leftName = left.item?.name ?? left.title
        let rightName = right.item?.name ?? right.title
        let comparison = leftName.localizedCaseInsensitiveCompare(rightName)
        return comparison == .orderedSame ? left.id.uuidString < right.id.uuidString : comparison == .orderedAscending
    }
}
