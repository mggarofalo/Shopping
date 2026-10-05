import Foundation
import Testing
@testable import Shopping

@Suite("Personal cart reducer input and causal contracts", .tags(.unit))
struct PersonalCartReducerContractTests {
    private let householdID = UUID()
    private let listID = UUID()
    private let needID = UUID()
    private let generation = UUID()

    private func snapshot(binding: String = "owner", evidence: Set<UUID> = []) -> PersonalCartEntrySnapshot {
        PersonalCartEntrySnapshot(title: "Milk", quantity: nil, notes: "",
            categoryID: nil, categoryName: nil, categoryOrder: 0, urgency: "normal",
            anyStore: true, storeIDs: [], purchaseRulesResolved: true,
            token: PersonalCartEntryToken(accountBinding: binding, householdID: householdID,
                listID: listID, needID: needID, generation: generation, evidence: evidence),
            purchaseNotices: [], demandAvailable: true)
    }

    private func reducer(_ edits: [PersonalCartEdit], checkouts: [UUID: PersonalCheckoutIntent] = [:],
                         restores: [UUID: PersonalRestoreIntent] = [:],
                         evidence: [UUID: Set<UUID>] = [:], superseded: Set<UUID> = []) -> PersonalCartReducer {
        PersonalCartReducer(edits: Dictionary(uniqueKeysWithValues: edits.map { ($0.id, $0) }),
            checkouts: checkouts, restores: restores, purchases: [],
            demandEvidence: evidence, superseded: superseded)
    }

    @Test func malformedTransitiveAncestryIsRejectedDespiteEveryParentBeingPresent() throws {
        let root = UUID()
        let middle = UUID()
        let tip = UUID()
        let value = snapshot()
        let subject = reducer([
            PersonalCartEdit(id: root, action: .add, snapshot: value, ancestors: []),
            PersonalCartEdit(id: middle, action: .quantity, snapshot: value, ancestors: [root]),
            PersonalCartEdit(id: tip, action: .quantity, snapshot: value, ancestors: [middle])
        ])
        #expect(throws: PersonalCartError.corruptRecord) {
            try subject.entries(accountBinding: "owner", householdID: householdID, listID: listID)
        }
    }

    @Test func unrelatedOwnerMissingAncestryCannotBlockOrPopulateCurrentOwner() throws {
        let mine = UUID()
        let other = UUID()
        let subject = reducer([
            PersonalCartEdit(id: mine, action: .add, snapshot: snapshot(evidence: [mine]), ancestors: []),
            PersonalCartEdit(id: other, action: .add, snapshot: snapshot(binding: "other"), ancestors: [UUID()])
        ])
        let entries = try subject.entries(accountBinding: "owner", householdID: householdID, listID: listID)
        #expect(entries.count == 1)
        #expect(entries.first?.token.accountBinding == "owner")
        #expect(entries.first?.token.evidence == [mine])
        #expect(try subject.entries(accountBinding: "owner", householdID: UUID(), listID: listID).isEmpty)
        #expect(try subject.entries(accountBinding: "owner", householdID: householdID, listID: UUID()).isEmpty)
    }

    @Test func restoreRequiresUnchangedDemandEvidenceAndNoReplacementOccurrence() throws {
        let editID = UUID()
        let demandID = UUID()
        let purchaseID = UUID()
        let saved = snapshot(evidence: [editID])
        let edit = PersonalCartEdit(id: editID, action: .add, snapshot: saved, ancestors: [])
        let capture = PersonalCheckoutCapture(entry: saved, demandEvidence: [demandID],
            purchaseRuleEvidence: "rules", needRevision: 1)
        let token = PersonalCheckoutToken(id: purchaseID, accountBinding: "owner",
            householdID: householdID, listID: listID, storeID: nil, captures: [capture])
        let checkout = PersonalCheckoutIntent(token: token, accepted: [needID],
            buyAnywayReceiptIDs: [], createdAt: Date(timeIntervalSince1970: 0))
        let restore = PersonalRestoreIntent(checkoutID: purchaseID, restoredNeedIDs: [needID])
        let restoreID = UUID()
        let exact = reducer([edit], checkouts: [purchaseID: checkout], restores: [restoreID: restore],
            evidence: [needID: [demandID]])
        #expect(try exact.entries(accountBinding: "owner", householdID: householdID, listID: listID) == [saved])
        let changed = reducer([edit], checkouts: [purchaseID: checkout], restores: [restoreID: restore],
            evidence: [needID: [demandID, UUID()]])
        #expect(try changed.entries(accountBinding: "owner", householdID: householdID, listID: listID).isEmpty)
        let replaced = reducer([edit], checkouts: [purchaseID: checkout], restores: [restoreID: restore],
            evidence: [needID: [demandID]], superseded: [needID])
        #expect(try replaced.entries(accountBinding: "owner", householdID: householdID, listID: listID).isEmpty)
    }
}
