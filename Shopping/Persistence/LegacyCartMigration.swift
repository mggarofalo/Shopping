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
            // Preserve old decisions without decoding unrelated, possibly still importing payloads.
            let resolved = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
            resolved.affectedStores = repository.persistence.primaryStore.map { [$0] }
            resolved.predicate = NSPredicate(format: "decision IN %@", ["discarded", "claimed"])
            for record in try repository.context.fetch(resolved) where record.id != PersistenceModel.unsetID {
                if record.decision == "discarded" {
                    try repository.insert(id: PersonalCartCoding.stableID("legacy-discard", record.id.uuidString),
                        kind: "legacyDiscard", command: record.id, value: record.id)
                } else if record.claimedAccount == repository.session.accountBinding {
                    try repository.insert(id: PersonalCartCoding.stableID("legacy-claim", record.id.uuidString),
                        kind: "legacyClaim", command: record.id, value: record.id)
                }
            }
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "carted == YES AND archived == NO")
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

    /// Retained audit includes earlier history and resolved decisions; the actionable UI uses pendingLegacyReview.
    func legacyReview() throws -> [LegacyCartReviewSnapshot] {
        try transact(save: false) { repository in try self.legacyReview(repository: repository) }
    }

    func pendingLegacyReview(householdID: UUID, listID: UUID) throws -> [LegacyCartReviewSnapshot] {
        try transact(save: false) { repository in
            try self.legacyReview(repository: repository).filter { review in
                guard review.householdID == householdID, review.listID == listID,
                      review.decision == "keep", !review.archived,
                      let need = try repository.need(review.needID, householdID: householdID, listID: listID)
                else { return false }
                return need.carted && !need.archived
            }
        }
    }

    private func legacyRecordGroups(repository: PersonalCartRepository) throws -> [UUID: [LegacyCartReview]] {
        let request = NSFetchRequest<LegacyCartReview>(entityName: "LegacyCartReview")
        request.affectedStores = repository.persistence.primaryStore.map { [$0] }
        let groups = Dictionary(grouping: try repository.context.fetch(request), by: \.id)
        for (id, records) in groups {
            guard id != PersistenceModel.unsetID, let first = records.first else { throw PersonalCartError.incompleteImport }
            let value = try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, first.payload)
            guard value.id == id, try records.allSatisfy({
                try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, $0.payload) == value
            }) else { throw PersonalCartError.corruptRecord }
        }
        return groups
    }

    private func legacyReview(repository: PersonalCartRepository) throws -> [LegacyCartReviewSnapshot] {
        let claimedIDs = Set(try repository.privateRecords(kind: "cart").map(\.id))
        let claimedReviews = Set(try repository.values(UUID.self, kind: "legacyClaim").values)
        let discardedIDs = Set(try repository.values(UUID.self, kind: "legacyDiscard").values)
        return try legacyRecordGroups(repository: repository).map { id, records in
            let value = try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, records[0].payload)
            let decision: String
            if claimedReviews.contains(id) || claimedIDs.contains(PersonalCartCoding.stableID("claim", id.uuidString)) || records.contains(where: { $0.decision == "claimed" }) {
                decision = "claimed"
            } else if discardedIDs.contains(id) || records.contains(where: { $0.decision == "discarded" }) {
                decision = "discarded"
            } else { decision = "keep" }
            return LegacyCartReviewSnapshot(id: id, householdID: value.householdID, listID: value.listID,
                needID: value.needID, title: value.title, quantity: value.quantity, oneTime: value.oneTime,
                archived: value.archived, oldCartedAt: value.oldCartedAt, oldRecoveryPayload: value.oldRecoveryPayload,
                decision: decision)
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    func decideLegacyReview(id: UUID, claim: Bool) throws {
        try transact { repository in
            guard let matches = try self.legacyRecordGroups(repository: repository)[id] else {
                throw PersonalCartError.unavailable
            }
            guard matches.allSatisfy({ $0.claimedAccount.isEmpty || $0.claimedAccount == repository.session.accountBinding }) else {
                throw PersonalCartError.accountChanged
            }
            let record = matches[0]
            let immutableClaimID = PersonalCartCoding.stableID("claim", id.uuidString)
            if try repository.values(UUID.self, kind: "legacyClaim").values.contains(id)
                || repository.privateRecords(kind: "cart").contains(where: { $0.id == immutableClaimID }) {
                guard claim else { throw PersonalCartError.reusedOperationID }
                return
            }
            let decision = claim ? "claimed" : "discarded"
            let existing = try self.legacyReview(repository: repository).first { $0.id == id }?.decision
            guard existing == "keep" || existing == decision else { throw PersonalCartError.reusedOperationID }
            if claim && existing == "claimed" {
                // Build 13 could record a successful claim without adding a cart command.
                // Retrying that decision must not resurrect a membership removed later.
                guard matches.contains(where: { $0.decision == "claimed" && $0.claimedAccount == repository.session.accountBinding })
                else { throw PersonalCartError.accountChanged }
                try repository.insert(id: PersonalCartCoding.stableID("legacy-claim", id.uuidString),
                    kind: "legacyClaim", command: id, value: id)
                return
            }
            let review = try PersonalCartCoding.decode(LegacyCartReviewSnapshot.self, record.payload)
            if claim {
                guard !review.archived,
                      let need = try repository.need(review.needID, householdID: review.householdID, listID: review.listID),
                      !need.archived else { throw PersonalCartError.unavailable }
                let current = try self.entries(householdID: review.householdID, listID: review.listID, repository: repository)
                if !current.contains(where: { $0.needID == review.needID }) {
                    let operationID = UUID()
                    let ancestors = try self.evidence(needID: review.needID, repository: repository)
                    let snapshot = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                        generation: UUID(),
                        evidence: ancestors.union([operationID]), quantity: review.quantity)
                    let edit = PersonalCartEdit(id: operationID, action: .add, snapshot: snapshot, ancestors: ancestors)
                    try repository.insert(id: operationID, kind: "cart", command: PersonalCartCommand.cart(needID: review.needID,
                        householdID: review.householdID, listID: review.listID), value: PersonalCartCommandResult(edit: edit, skipped: false))
                }
                // A decision is identical across replicas; its optional cart edit is not.
                // Keep them separate so an already-carted replica cannot collide with an add.
                try repository.insert(id: PersonalCartCoding.stableID("legacy-claim", id.uuidString),
                    kind: "legacyClaim", command: id, value: id)
                for record in matches { record.claimedAccount = repository.session.accountBinding }
            } else {
                try repository.insert(id: PersonalCartCoding.stableID("legacy-discard", id.uuidString),
                    kind: "legacyDiscard", command: id, value: id)
            }
            for record in matches { record.decision = decision }
        }
        try? republishPresence()
    }
}
