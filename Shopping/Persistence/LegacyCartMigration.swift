import CoreData

struct LegacyCartReviewSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let householdID: UUID
    let listID: UUID
    let needID: UUID
    let title: String
    let quantity: Int64?
    let oneTime: Bool
    let archived: Bool
    let oldCartedAt: Date?
    let oldRecoveryPayload: Data?
    let decision: String
}

extension PersonalCartService {
    /// Snapshot unknown ownership before any explicit claim. Legacy flags are never attribution.
    func captureLegacyReview() throws {
        try transact { repository in
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "carted == YES OR clearOperationID != nil")
            for need in try repository.context.fetch(request) {
                guard need.id != PersistenceModel.unsetID, let list = need.list, let household = list.household,
                      let source = need.objectID.persistentStore?.identifier else { continue }
                let id = PersonalCartCoding.stableID("personal-cart-v1", source, need.id.uuidString)
                let existing = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
                existing.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard try repository.context.fetch(existing).isEmpty else { continue }
                let oldOperation = household.clearOperations?.first { $0.id == need.clearOperationID }
                let snapshot = LegacyCartReviewSnapshot(id: id, householdID: household.id, listID: list.id,
                    needID: need.id, title: need.item?.name ?? need.title, quantity: need.quantity,
                    oneTime: need.kind == NeedKind.oneTime.rawValue, archived: need.archived,
                    oldCartedAt: need.cartedAt, oldRecoveryPayload: oldOperation?.snapshot, decision: "keep")
                guard let store = repository.persistence.primaryStore else { throw PersonalCartError.unavailable }
                let review = LegacyCartReview(context: repository.context)
                repository.context.assign(review, to: store)
                review.id = id
                review.payload = try PersonalCartCoding.encode(snapshot)
                review.decision = "keep"
                review.claimedAccount = ""
            }
        }
    }

    func legacyReview() throws -> [LegacyCartReviewSnapshot] {
        try transact(save: false) { repository in
            let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
            request.affectedStores = repository.persistence.primaryStore.map { [$0] }
            let claimedIDs = Set(try repository.privateRecords(kind: "cart").map(\.id))
            return try repository.context.fetch(request).map { record in
                let value = try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, record.payload)
                return LegacyCartReviewSnapshot(id: value.id, householdID: value.householdID, listID: value.listID,
                    needID: value.needID, title: value.title, quantity: value.quantity, oneTime: value.oneTime,
                    archived: value.archived, oldCartedAt: value.oldCartedAt, oldRecoveryPayload: value.oldRecoveryPayload,
                    decision: claimedIDs.contains(PersonalCartCoding.stableID("claim", value.id.uuidString)) ? "claimed" : record.decision)
            }
        }
    }

    func decideLegacyReview(id: UUID, claim: Bool) throws {
        try transact { repository in
            let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.affectedStores = repository.persistence.primaryStore.map { [$0] }
            let matches = try repository.context.fetch(request)
            guard matches.count == 1 else { throw PersonalCartError.corruptRecord }
            let record = matches[0]
            guard record.claimedAccount.isEmpty || record.claimedAccount == repository.session.accountBinding else {
                throw PersonalCartError.accountChanged
            }
            let immutableClaimID = PersonalCartCoding.stableID("claim", id.uuidString)
            if try repository.privateRecords(kind: "cart").contains(where: { $0.id == immutableClaimID }) {
                guard claim else { throw PersonalCartError.reusedOperationID }
                return
            }
            let decision = claim ? "claimed" : "discarded"
            guard record.decision == "keep" || record.decision == decision else { throw PersonalCartError.reusedOperationID }
            if record.decision == decision { return }
            let review = try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, record.payload)
            if claim {
                guard !review.archived,
                      let need = try repository.need(review.needID, householdID: review.householdID, listID: review.listID),
                      !need.archived else { throw PersonalCartError.unavailable }
                let current = try self.entries(householdID: review.householdID, listID: review.listID, repository: repository)
                if !current.contains(where: { $0.needID == review.needID }) {
                    let operationID = PersonalCartCoding.stableID("claim", id.uuidString)
                    let ancestors = try self.evidence(needID: review.needID, repository: repository)
                    let snapshot = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                        generation: PersonalCartCoding.stableID("claim-generation", id.uuidString),
                        evidence: ancestors.union([operationID]), quantity: review.quantity)
                    let edit = PersonalCartEdit(id: operationID, action: .add, snapshot: snapshot, ancestors: ancestors)
                    try repository.insert(id: operationID, kind: "cart", command: PersonalCartCommand.cart(needID: review.needID,
                        householdID: review.householdID, listID: review.listID), value: PersonalCartCommandResult(edit: edit, skipped: false))
                }
                record.claimedAccount = repository.session.accountBinding
            }
            record.decision = decision
        }
        try? republishPresence()
    }
}
