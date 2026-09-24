import CoreData

/// Commands serialize on the existing persistence writer; tokens carry values across queues.
final class PersonalCartService: @unchecked Sendable {
    let persistence: PersistenceController
    let sessionProvider: any ShopperSessionProviding
    let initialAccountBinding: String?
    var failurePoint: ((String) throws -> Void)?

    init(persistence: PersistenceController, sessionProvider: any ShopperSessionProviding) {
        self.persistence = persistence
        self.sessionProvider = sessionProvider
        self.initialAccountBinding = try? sessionProvider.currentSession().accountBinding
        persistence.personalCartsEnabled = true
        persistence.personalCartSessionProvider = sessionProvider
        persistence.personalCartInitialBinding = initialAccountBinding
    }

    func entries(householdID: UUID, listID: UUID) throws -> [PersonalCartEntrySnapshot] {
        try transact(save: false) { repository in
            try self.entries(householdID: householdID, listID: listID, repository: repository)
        }
    }

    func outstandingNeedIDs(householdID: UUID, listID: UUID) throws -> Set<UUID> {
        try transact(save: false) { repository in
            let request = Need.fetchRequest()
            request.predicate = NSPredicate(format: "list.id == %@ AND list.household.id == %@ AND archived == NO",
                                            listID as CVarArg, householdID as CVarArg)
            var fulfilled = try HouseholdDemandProjection.fulfilledNeedIDs(householdID: householdID, in: repository.context)
            let intents = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
            let restores = try repository.values(PersonalRestoreIntent.self, kind: "restore")
            for (id, intent) in intents where intent.token.householdID == householdID && intent.token.listID == listID {
                for capture in intent.token.captures where intent.accepted.contains(capture.entry.needID) {
                    let needID = capture.entry.needID
                    guard !restores.values.contains(where: { $0.checkoutID == id && $0.restoredNeedIDs.contains(needID) }),
                          try HouseholdDemandProjection.evidence(needID: needID, householdID: householdID, in: repository.context) == capture.demandEvidence,
                          try HouseholdDemandProjection.rulesMatch(capture, in: repository.context) else { continue }
                    fulfilled.insert(needID)
                }
            }
            return Set(try repository.context.fetch(request).map(\.id)).subtracting(fulfilled)
        }
    }

    func presence(householdID: UUID, listID: UUID) throws -> [PersonalCartPresenceSnapshot] {
        try transact(save: false) { repository in
            let events = try PersonalCartRepository.sharedValues(HouseholdPresenceEvent.self, kind: "presence", householdID: householdID, in: repository.context)
            let groups = Dictionary(grouping: events.values.filter { $0.listID == listID && $0.shopperID != repository.session.shopperID },
                                    by: { "\($0.shopperID)/\($0.needID)" })
            return groups.values.compactMap { values in
                let tips = values.filter { event in
                    !values.contains { event.evidence.isStrictSubset(of: $0.evidence) }
                }
                guard !tips.contains(where: \.removed), let winner = tips.max(by: { $0.id.uuidString < $1.id.uuidString }) else { return nil }
                return PersonalCartPresenceSnapshot(needID: winner.needID, shopperID: winner.shopperID, quantity: winner.quantity, name: nil)
            }
        }
    }

    func retainedScopes() throws -> [PersonalCartScopeSnapshot] {
        try transact(save: false) { repository in
            let edits = try repository.values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit)
            let intents = try repository.values(PersonalCheckoutIntent.self, kind: "checkout").values
            var scopes = Set(edits.map { PersonalCartScopeSnapshot(householdID: $0.snapshot.householdID, listID: $0.snapshot.listID) })
            scopes.formUnion(intents.map { PersonalCartScopeSnapshot(householdID: $0.token.householdID, listID: $0.token.listID) })
            return scopes.sorted { ($0.householdID.uuidString, $0.listID.uuidString) < ($1.householdID.uuidString, $1.listID.uuidString) }
        }
    }

    func history(householdID: UUID, listID: UUID) throws -> [PersonalCheckoutHistoryEntry] {
        try transact(save: false) { repository in
            let intents = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
            let restores = try repository.values(PersonalRestoreIntent.self, kind: "restore")
            let completed = try repository.values(UUID.self, kind: "published")
            let restoreCompleted = Set(try repository.values(UUID.self, kind: "restorePublished").values)
            return intents.compactMap { id, intent in
                guard intent.token.householdID == householdID, intent.token.listID == listID else { return nil }
                let restoredIDs = restores.values.filter { $0.checkoutID == id }
                    .reduce(into: Set<UUID>()) { $0.formUnion($1.restoredNeedIDs) }
                return PersonalCheckoutHistoryEntry(id: id, createdAt: intent.createdAt,
                    entries: intent.token.captures.filter { intent.accepted.contains($0.entry.needID) }.map(\.entry),
                    restored: !intent.accepted.isEmpty && intent.accepted.isSubset(of: restoredIDs),
                    restoredNeedIDs: restoredIDs,
                    pendingPublication: !completed.values.contains(id)
                        || restores.contains { $0.value.checkoutID == id && !restoreCompleted.contains($0.key) })
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func entries(householdID: UUID, listID: UUID, repository: PersonalCartRepository) throws -> [PersonalCartEntrySnapshot] {
        let results = try repository.values(PersonalCartCommandResult.self, kind: "cart")
        var edits: [UUID: PersonalCartEdit] = [:]
        for (id, result) in results {
            guard let edit = result.edit else { continue }
            guard edit.id == id, edit.snapshot.token.accountBinding == repository.session.accountBinding,
                  edit.snapshot.quantity == nil || (1...99).contains(edit.snapshot.quantity!),
                  edit.snapshot.id != PersistenceModel.unsetID else { throw PersonalCartError.corruptRecord }
            edits[id] = edit
        }
        let checkouts = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")
        let restores = try repository.values(PersonalRestoreIntent.self, kind: "restore")
        var purchases = try HouseholdDemandProjection.purchases(householdID: householdID, in: repository.context)
        for (id, intent) in checkouts where intent.token.householdID == householdID {
            for capture in intent.token.captures where intent.accepted.contains(capture.entry.needID) {
                guard !restores.values.contains(where: { $0.checkoutID == id && $0.restoredNeedIDs.contains(capture.entry.needID) }) else { continue }
                let receiptID = PersonalCartCoding.stableID("purchase", id.uuidString, capture.entry.needID.uuidString)
                if !purchases.contains(where: { $0.id == receiptID }) {
                    purchases.append(HouseholdPurchaseEvent(id: receiptID, checkoutID: id, shopperID: repository.session.shopperID,
                        householdID: householdID, listID: listID, capture: capture))
                }
            }
        }
        let demandEvents = try PersonalCartRepository.sharedValues(HouseholdDemandEvent.self, kind: "demand", householdID: householdID, in: repository.context)
        let evidence = Dictionary(grouping: demandEvents.values, by: \.needID).mapValues { Set($0.map(\.id)) }
        let superseded = demandEvents.values.reduce(into: Set<UUID>()) { $0.formUnion($1.replaces) }
        let reducer = PersonalCartReducer(edits: edits, checkouts: checkouts, restores: restores,
                                          purchases: purchases, demandEvidence: evidence, superseded: superseded)
        return try reducer.entries(accountBinding: repository.session.accountBinding, householdID: householdID, listID: listID).map { saved in
            guard let need = try repository.need(saved.needID, householdID: householdID, listID: listID) else {
                return self.withMetadata(saved, from: nil)
            }
            let fresh = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                generation: saved.id, evidence: saved.token.evidence, quantity: saved.quantity)
            return self.withMetadata(saved, from: fresh)
        }
    }

    func withMetadata(_ saved: PersonalCartEntrySnapshot, from fresh: PersonalCartEntrySnapshot?) -> PersonalCartEntrySnapshot {
        let display = fresh ?? saved
        return PersonalCartEntrySnapshot(title: display.title, quantity: saved.quantity, notes: display.notes,
            categoryID: display.categoryID, categoryName: display.categoryName, categoryOrder: display.categoryOrder,
            urgency: display.urgency, anyStore: display.anyStore, storeIDs: display.storeIDs,
            purchaseRulesResolved: display.purchaseRulesResolved, token: saved.token,
            purchaseNotices: saved.purchaseNotices, demandAvailable: fresh?.demandAvailable ?? false)
    }

    func evidence(needID: UUID, repository: PersonalCartRepository) throws -> Set<UUID> {
        let results = try repository.values(PersonalCartCommandResult.self, kind: "cart")
        return Set(results.values.compactMap(\.edit).filter { $0.snapshot.needID == needID }.map(\.id))
    }

    func transact<T>(save: Bool = true, _ body: (PersonalCartRepository) throws -> T) throws -> T {
        let session = try sessionProvider.currentSession()
        guard session.accountBinding == initialAccountBinding else { throw PersonalCartError.accountChanged }
        if case .managed(let privateURL, _, _) = persistence.configuration {
            guard privateURL.deletingLastPathComponent().lastPathComponent == session.accountBinding else {
                throw PersonalCartError.accountChanged
            }
        }
        var result: Result<T, Error>!
        persistence.writer.performAndWait {
            let context = persistence.writer
            context.reset()
            context.userInfo[PersonalCartPersistencePolicy.authorizedAccountKey] = session.accountBinding
            defer { context.userInfo.removeObject(forKey: PersonalCartPersistencePolicy.authorizedAccountKey) }
            do {
                let repository = PersonalCartRepository(persistence: persistence, context: context, session: session)
                let value = try body(repository)
                guard try sessionProvider.currentSession() == session else { throw PersonalCartError.accountChanged }
                if save && context.hasChanges {
                    try persistence.prepareForSave(context)
                    try context.save()
                }
                result = .success(value)
            } catch {
                context.rollback()
                result = .failure(error)
            }
        }
        return try result.get()
    }
}
