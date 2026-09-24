import CoreData
import Foundation

struct WatchPersistentProjection {
    let scope: PersonalCartScopeSnapshot
    let stores: [WatchStore]
    let needs: [PersonalCartEntrySnapshot]
    let oneTimeIDs: Set<UUID>
    let archivedCategoryIDs: Set<UUID>
    let writable: Bool

    static func read(cart: PersonalCartService, preferredHouseholdID: UUID?,
                     writable: ((UUID) -> Bool)?) throws -> WatchPersistentProjection? {
        let retained = try cart.retainedScopes()
        return try cart.transact(save: false) { repository in
            let households = try repository.context.fetch(Household.fetchRequest())
                .filter { $0.id != PersistenceModel.unsetID && $0.groceryList?.id != PersistenceModel.unsetID && $0.groceryList != nil }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            let household = preferredHouseholdID.map { id in households.first { $0.id == id } } ?? households.first
            guard let scope = household.map({ PersonalCartScopeSnapshot(householdID: $0.id, listID: $0.groceryList!.id) })
                ?? retained.filter { preferredHouseholdID == nil || $0.householdID == preferredHouseholdID }.sorted(by: { $0.householdID.uuidString < $1.householdID.uuidString }).first else { return nil }
            let stores = (household?.stores ?? []).filter { !$0.isArchived && $0.id != PersistenceModel.unsetID }
                .sorted { $0.displayOrder == $1.displayOrder ? $0.id.uuidString < $1.id.uuidString : $0.displayOrder < $1.displayOrder }
                .map { WatchStore(id: $0.id, name: $0.name) }
            let needs = (household?.groceryList?.needs ?? []).filter { !$0.archived }
            var mayWrite = household != nil
            if let household, let cloud = repository.persistence.container as? NSPersistentCloudKitContainer {
                mayWrite = cloud.canUpdateRecord(forManagedObjectWith: household.objectID)
            }
            if let writable { mayWrite = mayWrite && writable(scope.householdID) }
            return try WatchPersistentProjection(scope: scope, stores: stores,
                needs: needs.map { try PersonalCartSnapshotBuilder.make(need: $0, session: repository.session,
                    generation: $0.id, evidence: [], quantity: $0.quantity) },
                oneTimeIDs: Set(needs.filter { $0.kind == NeedKind.oneTime.rawValue }.map(\.id)),
                archivedCategoryIDs: Set((household?.categories ?? []).filter(\.isArchived).map(\.id)), writable: mayWrite)
        }
    }

    func sections(_ entries: [PersonalCartEntrySnapshot], make: (PersonalCartEntrySnapshot) throws -> WatchShoppingItem) rethrows -> [WatchItemSection] {
        let grouped = Dictionary(grouping: entries) { $0.categoryID?.uuidString ?? "uncategorized" }
        return try grouped.values.sorted { left, right in
            let a = left[0], b = right[0]
            let aRank = a.categoryID == nil ? 2 : archivedCategoryIDs.contains(a.categoryID!) ? 1 : 0
            let bRank = b.categoryID == nil ? 2 : archivedCategoryIDs.contains(b.categoryID!) ? 1 : 0
            if aRank != bRank { return aRank < bRank }
            if a.categoryOrder != b.categoryOrder { return a.categoryOrder < b.categoryOrder }
            return (a.categoryID?.uuidString ?? "") < (b.categoryID?.uuidString ?? "")
        }.map { entries in
            let ordered = entries.sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.needID.uuidString < $1.needID.uuidString : comparison == .orderedAscending
            }
            return try WatchItemSection(id: ordered[0].categoryID?.uuidString ?? "uncategorized",
                title: ordered[0].categoryName ?? "Uncategorized", items: ordered.map(make))
        }
    }
}
