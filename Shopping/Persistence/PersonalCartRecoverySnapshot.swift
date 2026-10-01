import CoreData

/// Discovery for contextual links, separate from the authoritative cart snapshot.
struct PersonalCartRecoverySnapshot: Sendable {
    let pendingLegacyReview: [LegacyCartReviewSnapshot]
    let legacyReviewError: String?
    let otherSavedScopes: [PersonalCartScopeSnapshot]
    let hasEarlierClearedGroceries: Bool
}

extension PersonalCartService {
    func recoverySnapshot(householdID: UUID, listID: UUID) throws -> PersonalCartRecoverySnapshot {
        let pending: [LegacyCartReviewSnapshot]
        let legacyError: String?
        do {
            pending = try pendingLegacyReview(householdID: householdID, listID: listID)
            legacyError = nil
        } catch {
            pending = []
            legacyError = error.localizedDescription
        }
        let otherScopes = try retainedScopes().filter {
            $0.householdID != householdID || $0.listID != listID
        }.filter {
            try !entries(householdID: $0.householdID, listID: $0.listID).isEmpty
                || !history(householdID: $0.householdID, listID: $0.listID).isEmpty
        }
        let earlierHistory = try transact(save: false) { repository in
            let request = ClearOperation.fetchRequest()
            let operations = try repository.context.fetch(request)
            let lists = GroceryList.fetchRequest()
            lists.predicate = NSPredicate(format: "id == %@ AND household.id == %@",
                listID as CVarArg, householdID as CVarArg)
            let candidates = try repository.context.fetch(lists)
            guard candidates.count == 1 else { return false }
            return !ClearOperationSelection.valid(operations, list: candidates[0]).isEmpty
        }
        return PersonalCartRecoverySnapshot(pendingLegacyReview: pending, legacyReviewError: legacyError,
            otherSavedScopes: otherScopes, hasEarlierClearedGroceries: earlierHistory)
    }
}
