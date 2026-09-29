import Foundation

/// Known private operations awaiting app processing, not an iCloud delivery count.
struct HomeSharingWorkSnapshot: Equatable, Sendable {
    let scope: HomeEffectScope
    let pendingCheckoutCount: Int
    let pendingUndoCount: Int
    let heldCheckoutCount: Int
    let heldUndoCount: Int
    let incompleteUndoCount: Int
    /// Legacy operations without a known home remain account-wide uncertainty.
    let unassignedUndoCount: Int

    var heldCount: Int { heldCheckoutCount + heldUndoCount }
    var isIncomplete: Bool { incompleteUndoCount > 0 || unassignedUndoCount > 0 }
}

extension PersonalCartService {
    /// Call from a background worker. The caller must revalidate its selected
    /// graph and presentation before showing this portable account/home snapshot.
    /// This read neither publishes work nor invokes native permission APIs.
    func sharingWorkSnapshot(householdID: UUID, listID: UUID) throws -> HomeSharingWorkSnapshot {
        try transact(save: false) { repository in
            let scope = repository.homeEffectScope(householdID: householdID, listID: listID)
            let evidence = try repository.homeLeaveEvidence(scope: scope)
            let access = try repository.homeEffectAccess(householdID: householdID, listID: listID)
            let checkouts = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
            let restores = try repository.values(PersonalRestoreIntent.self, kind: "restore")
            var heldCheckouts = 0
            var heldUndos = 0
            var incompleteUndos = 0
            for id in evidence.checkoutIDs {
                guard let checkout = checkouts[id], checkout.token.accountBinding == scope.accountBinding,
                      checkout.token.householdID == householdID, checkout.token.listID == listID else {
                    throw PersonalCartError.corruptRecord
                }
                if !access.permitsPublication(checkout.token.homeEffectAuthority ?? .legacy) { heldCheckouts += 1 }
            }
            for id in evidence.restoreIDs {
                guard let restore = restores[id] else { throw PersonalCartError.incompleteImport }
                guard let checkout = checkouts[restore.checkoutID] else {
                    incompleteUndos += 1
                    continue
                }
                guard checkout.token.accountBinding == scope.accountBinding,
                      checkout.token.householdID == householdID, checkout.token.listID == listID else {
                    throw PersonalCartError.corruptRecord
                }
                let authority = restore.homeEffectAuthority ?? checkout.token.homeEffectAuthority ?? .legacy
                if !access.permitsPublication(authority) { heldUndos += 1 }
            }
            return HomeSharingWorkSnapshot(scope: scope, pendingCheckoutCount: evidence.checkoutIDs.count,
                pendingUndoCount: evidence.restoreIDs.count, heldCheckoutCount: heldCheckouts,
                heldUndoCount: heldUndos, incompleteUndoCount: incompleteUndos,
                unassignedUndoCount: evidence.unresolvedRestoreIDs.count)
        }
    }
}
