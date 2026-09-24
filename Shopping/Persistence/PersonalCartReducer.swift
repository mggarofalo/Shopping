import Foundation

struct PersonalCartReducer {
    let edits: [UUID: PersonalCartEdit]
    let checkouts: [UUID: PersonalCheckoutIntent]
    let restores: [UUID: PersonalRestoreIntent]
    let purchases: [HouseholdPurchaseEvent]
    let demandEvidence: [UUID: Set<UUID>]
    let superseded: Set<UUID>
    var validateSharedRecovery = true

    func entries(accountBinding: String, householdID: UUID, listID: UUID) throws -> [PersonalCartEntrySnapshot] {
        let scoped = edits.values.filter {
            $0.snapshot.token.accountBinding == accountBinding && $0.snapshot.householdID == householdID
                && $0.snapshot.listID == listID
        }
        let groups = Dictionary(grouping: scoped, by: { $0.snapshot.needID })
        return try groups.compactMap { needID, events in
            let allIDs = Set(events.map(\.id))
            guard events.allSatisfy({ $0.ancestors.isSubset(of: allIDs) && !$0.ancestors.contains($0.id) }) else {
                throw PersonalCartError.incompleteImport
            }
            let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
            guard events.allSatisfy({ event in
                event.ancestors.allSatisfy { parentID in
                    guard let parent = byID[parentID] else { return false }
                    return parent.ancestors.isSubset(of: event.ancestors)
                }
            }) else { throw PersonalCartError.corruptRecord }
            let tips = events.filter { event in !events.contains { $0.ancestors.contains(event.id) } }
            guard !tips.contains(where: { $0.action == .remove }),
                  let winner = tips.max(by: { $0.id.uuidString < $1.id.uuidString }) else { return nil }
            let hidden = checkouts.contains { operationID, intent in
                guard intent.accepted.contains(needID),
                      let capture = intent.token.captures.first(where: { $0.entry.needID == needID }),
                      capture.entry.token.generation == winner.snapshot.id,
                      capture.entry.token.evidence == allIDs else { return false }
                let restored = restores.values.contains {
                    $0.checkoutID == operationID && $0.restoredNeedIDs.contains(needID)
                }
                return !(restored && (!validateSharedRecovery || (!superseded.contains(needID)
                         && capture.demandEvidence == demandEvidence[needID, default: []])))
            }
            guard !hidden else { return nil }
            let saved = winner.snapshot
            return PersonalCartEntrySnapshot(
                title: saved.title, quantity: saved.quantity, notes: saved.notes,
                categoryID: saved.categoryID, categoryName: saved.categoryName, categoryOrder: saved.categoryOrder,
                urgency: saved.urgency, anyStore: saved.anyStore, storeIDs: saved.storeIDs,
                purchaseRulesResolved: saved.purchaseRulesResolved,
                token: PersonalCartEntryToken(accountBinding: accountBinding, householdID: householdID,
                                              listID: listID, needID: needID, generation: saved.id, evidence: allIDs),
                purchaseNotices: purchases.filter { $0.capture.entry.needID == needID }
                    .map { PersonalPurchaseNotice(receiptID: $0.id, purchaserName: nil) },
                demandAvailable: saved.demandAvailable
            )
        }
    }
}
