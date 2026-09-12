import CoreData

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
