import CoreData

extension PersonalCartService {
    func resumePending() throws {
        let identifiers = try transact(save: false) { repository in
            (try repository.values(PersonalCheckoutIntent.self, kind: "checkout").keys.sorted { $0.uuidString < $1.uuidString },
             try repository.values(PersonalRestoreIntent.self, kind: "restore").keys.sorted { $0.uuidString < $1.uuidString })
        }
        for id in identifiers.0 { try quarantineUnavailable { try publishCheckout(id: id) } }
        for id in identifiers.1 { try quarantineUnavailable { try publishRestore(id: id) } }
        try quarantineUnavailable { try republishPresence() }
    }

    private func quarantineUnavailable(_ publish: () throws -> Void) throws {
        do { try publish() }
        catch let error as PersonalCartError where error == .permissionDenied || error == .unavailable { return }
        catch is PersistencePermissionError { return }
    }

    func publishCheckout(id: UUID) throws {
        try transact { repository in
            guard let intent = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")[id] else {
                throw PersonalCartError.corruptRecord
            }
            for capture in intent.token.captures where intent.accepted.contains(capture.entry.needID) {
                let receiptID = PersonalCartCoding.stableID("purchase", id.uuidString, capture.entry.needID.uuidString)
                let receipt = HouseholdPurchaseEvent(id: receiptID, checkoutID: id, shopperID: repository.session.shopperID,
                    householdID: intent.token.householdID, listID: intent.token.listID, capture: capture)
                try repository.publish(receipt, id: receiptID, kind: "purchase", householdID: intent.token.householdID)
            }
        }
        try failurePoint?("afterShared")
        try transact { repository in
            let marker = PersonalCartCoding.stableID("published", id.uuidString)
            try repository.insert(id: marker, kind: "published", command: id, value: id)
        }
        try failurePoint?("afterCompletion")
    }

    func publishRestore(id: UUID) throws {
        try transact { repository in
            guard let restore = try repository.values(PersonalRestoreIntent.self, kind: "restore")[id],
                  let checkout = try repository.values(PersonalCheckoutIntent.self, kind: "checkout")[restore.checkoutID] else {
                throw PersonalCartError.corruptRecord
            }
            let receipts = Set(restore.restoredNeedIDs.map {
                PersonalCartCoding.stableID("purchase", restore.checkoutID.uuidString, $0.uuidString)
            })
            if !receipts.isEmpty {
                let event = HouseholdRetractionEvent(id: id, receiptIDs: receipts)
                try repository.publish(event, id: id, kind: "retraction", householdID: checkout.token.householdID)
            }
        }
        try transact { repository in
            let marker = PersonalCartCoding.stableID("restore-published", id.uuidString)
            try repository.insert(id: marker, kind: "restorePublished", command: id, value: id)
        }
    }

    func republishPresence() throws {
        let needIDs = try transact(save: false) { repository in
            Set(try repository.values(PersonalCartCommandResult.self, kind: "cart").values.compactMap(\.edit).map { $0.snapshot.needID })
        }
        for needID in needIDs {
            try quarantineUnavailable {
                try transact { repository in
                    let results = try repository.values(PersonalCartCommandResult.self, kind: "cart")
                    let group = results.values.compactMap(\.edit).filter { $0.snapshot.needID == needID }
                    guard let reference = group.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first?.snapshot else { return }
                    let entries = try self.entries(householdID: reference.householdID, listID: reference.listID, repository: repository)
                    let entry = entries.first { $0.needID == needID }
                    let evidence = Set(group.map(\.id))
                    let checkoutIDs = try repository.values(PersonalCheckoutIntent.self, kind: "checkout").filter {
                        $0.value.accepted.contains(needID)
                    }.map(\.key)
                    let restoreIDs = try repository.values(PersonalRestoreIntent.self, kind: "restore").filter {
                        $0.value.restoredNeedIDs.contains(needID)
                    }.map(\.key)
                    let demandEvents = try PersonalCartRepository.sharedValues(HouseholdDemandEvent.self, kind: "demand",
                        householdID: reference.householdID, in: repository.context)
                    let demandIDs = demandEvents.values.filter { $0.needID == needID || $0.replaces.contains(needID) }.map(\.id)
                    let allEvidence = evidence.union(checkoutIDs).union(restoreIDs).union(demandIDs)
                    let id = PersonalCartCoding.stableID("presence", repository.session.shopperID.uuidString,
                        needID.uuidString, allEvidence.map(\.uuidString).sorted().joined(separator: ","))
                    let event = HouseholdPresenceEvent(id: id, shopperID: repository.session.shopperID,
                        householdID: reference.householdID, listID: reference.listID, needID: needID,
                        quantity: entry?.quantity, generation: entry?.id ?? reference.id,
                        evidence: allEvidence, removed: entry == nil)
                    try repository.publish(event, id: id, kind: "presence", householdID: reference.householdID)
                }
            }
        }
    }
}
