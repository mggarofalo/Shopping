import CoreData

/// When a command's household effects run. The private causal command is always
/// saved before returning and remains recoverable by resumePending(). Deferral
/// leaves advisory presence to the caller's PersonalCartPresencePublisher, where
/// the caller marks the need dirty, and leaves Checkout and Restore receipts to
/// the checkout outbox (SHOPPING-287).
enum PersonalCartEffectPolicy: Sendable {
    case immediate
    case deferred
}

/// A command's own durable result, read in its writer transaction, so a caller
/// can show it without waiting for a later full read. A nil entry means the need
/// is not in this shopper's cart. `successor` is the membership this operation's
/// own edit wrote, so a caller can tell it from one another device wrote.
struct PersonalCartReceipt: Equatable, Sendable {
    let needID: UUID
    let entry: PersonalCartEntrySnapshot?
    var successor: PersonalCartEntryToken? = nil
}

extension PersonalCartService {
    @discardableResult
    func cart(needID: UUID, householdID: UUID, listID: UUID, operationID: UUID = UUID(), presencePolicy: PersonalCartEffectPolicy = .immediate) throws -> PersonalCartReceipt {
        try add(needID: needID, householdID: householdID, listID: listID, quantityOverride: nil, expectedStoreID: nil, operationID: operationID, presencePolicy: presencePolicy)
    }

    @discardableResult
    func cart(needID: UUID, householdID: UUID, listID: UUID, initialQuantity: Int64?, expectedStoreID: UUID? = nil, operationID: UUID = UUID(), presencePolicy: PersonalCartEffectPolicy = .immediate) throws -> PersonalCartReceipt {
        if let initialQuantity, !(1...99).contains(initialQuantity) { throw PersonalCartError.invalidQuantity }
        return try add(needID: needID, householdID: householdID, listID: listID, quantityOverride: .some(initialQuantity), expectedStoreID: expectedStoreID, operationID: operationID, presencePolicy: presencePolicy)
    }

    private func add(needID: UUID, householdID: UUID, listID: UUID, quantityOverride: Int64??, expectedStoreID: UUID?, operationID: UUID, presencePolicy: PersonalCartEffectPolicy) throws -> PersonalCartReceipt {
        let command: PersonalCartCommand
        if let quantity = quantityOverride {
            command = .cartWithQuantity(needID: needID, householdID: householdID, listID: listID, quantity: quantity, expectedStoreID: expectedStoreID)
        } else {
            command = .cart(needID: needID, householdID: householdID, listID: listID)
        }
        let receipt = try transact { repository -> PersonalCartReceipt in
            if let replay = try repository.replay(id: operationID, kind: "cart", command: command, as: PersonalCartCommandResult.self) {
                return try self.receipt(for: needID, householdID: householdID, listID: listID, successor: replay.edit, repository)
            }
            let home = try repository.household(householdID)
            let access = try repository.homeEffectAccess(householdID: householdID, listID: listID)
            let native = repository.ledgerNativeCommandAccess(for: home, access: access)
            guard native != .readOnly, native != .lost else { throw PersonalCartError.quarantined }
            let authority = access.capturedAuthority
            guard access.permitsPublication(authority) else { throw PersonalCartError.quarantined }
            // Membership is private: a half-imported shared record degrades only its
            // own household projection, never this command.
            let existing = try self.displayEntries(householdID: householdID, listID: listID, repository: repository)
            if existing.contains(where: { $0.needID == needID }) {
                try repository.insert(id: operationID, kind: "cart", command: command,
                                      value: PersonalCartCommandResult(edit: nil, skipped: false))
                return try self.receipt(for: needID, householdID: householdID, listID: listID, repository)
            }
            guard let need = try repository.need(needID, householdID: householdID, listID: listID), !need.archived else {
                throw PersonalCartError.unavailable
            }
            let ancestors = try self.evidence(needID: needID, repository: repository)
            let snapshot = try PersonalCartSnapshotBuilder.make(need: need, session: repository.session,
                generation: UUID(), evidence: ancestors.union([operationID]), quantity: quantityOverride ?? need.quantity,
                homeEffectAuthority: authority)
            guard snapshot.purchaseRulesResolved else { throw PersonalCartError.unavailable }
            if let expectedStoreID {
                let household = try repository.household(householdID)
                guard (household.stores ?? []).contains(where: { $0.id == expectedStoreID && !$0.isArchived }),
                      PersonalCartSnapshotBuilder.eligible(snapshot, storeID: expectedStoreID),
                      try !PersonalDemandProjection.shopperFulfilledNeedIDs(householdID: householdID,
                        persistence: self.persistence, in: repository.context, session: repository.session).contains(needID) else { throw PersonalCartError.staleEntry }
            }
            let edit = PersonalCartEdit(id: operationID, action: .add, snapshot: snapshot, ancestors: ancestors)
            try repository.insert(id: operationID, kind: "cart", command: command,
                                  value: PersonalCartCommandResult(edit: edit, skipped: false))
            return try self.receipt(for: needID, householdID: householdID, listID: listID, successor: edit, repository)
        }
        if presencePolicy == .immediate { republishPresence(each: [needID]) }
        return receipt
    }

    @discardableResult
    func uncart(_ token: PersonalCartEntryToken, operationID: UUID = UUID(), presencePolicy: PersonalCartEffectPolicy = .immediate) throws -> PersonalCartReceipt {
        try change(token, quantity: nil, removing: true, operationID: operationID, presencePolicy: presencePolicy)
    }

    @discardableResult
    func setQuantity(_ quantity: Int64?, token: PersonalCartEntryToken, operationID: UUID = UUID(), presencePolicy: PersonalCartEffectPolicy = .immediate) throws -> PersonalCartReceipt {
        if let quantity, !(1...99).contains(quantity) { throw PersonalCartError.invalidQuantity }
        return try change(token, quantity: quantity, removing: false, operationID: operationID, presencePolicy: presencePolicy)
    }

    private func change(_ token: PersonalCartEntryToken, quantity: Int64?, removing: Bool, operationID: UUID, presencePolicy: PersonalCartEffectPolicy) throws -> PersonalCartReceipt {
        let command: PersonalCartCommand = removing ? .uncart(token) : .quantity(token, quantity)
        let receipt = try transact { repository -> PersonalCartReceipt? in
            guard token.accountBinding == repository.session.accountBinding else { throw PersonalCartError.accountChanged }
            if let replay = try repository.replay(id: operationID, kind: "cart", command: command, as: PersonalCartCommandResult.self) {
                return replay.skipped ? nil : try self.receipt(for: token.needID, householdID: token.householdID,
                    listID: token.listID, successor: replay.edit, repository)
            }
            let current = try self.entries(householdID: token.householdID, listID: token.listID, repository: repository, includeShared: false)
            guard let entry = current.first(where: { $0.token == token }) else {
                try repository.insert(id: operationID, kind: "cart", command: command,
                                      value: PersonalCartCommandResult(edit: nil, skipped: true))
                return nil
            }
            // An explicit same-value quantity is still a causal edit: another
            // replica may concurrently change the quantity from this token.
            let priorAuthority = token.homeEffectAuthority ?? .legacy
            let access = try repository.homeEffectAccess(householdID: token.householdID, listID: token.listID)
            let retainedAuthority = HomeEffectAuthority(observedBlockIDs: priorAuthority.observedBlockIDs.union(access.blockIDs),
                grantID: priorAuthority.grantID,
                observedRestrictionIDs: priorAuthority.observedRestrictionIDs.union(access.restrictionIDs))
            let updated = PersonalCartEntrySnapshot(title: entry.title, quantity: removing ? entry.quantity : quantity,
                notes: entry.notes, categoryID: entry.categoryID, categoryName: entry.categoryName,
                categoryOrder: entry.categoryOrder, urgency: entry.urgency, anyStore: entry.anyStore,
                storeIDs: entry.storeIDs, purchaseRulesResolved: entry.purchaseRulesResolved,
                token: PersonalCartEntryToken(accountBinding: token.accountBinding, householdID: token.householdID,
                    listID: token.listID, needID: token.needID, generation: token.generation,
                    evidence: token.evidence.union([operationID]), homeEffectAuthority: retainedAuthority),
                purchaseNotices: entry.purchaseNotices, demandAvailable: entry.demandAvailable)
            let edit = PersonalCartEdit(id: operationID, action: removing ? .remove : .quantity,
                                        snapshot: updated, ancestors: token.evidence)
            try repository.insert(id: operationID, kind: "cart", command: command,
                                  value: PersonalCartCommandResult(edit: edit, skipped: false))
            return try self.receipt(for: token.needID, householdID: token.householdID, listID: token.listID,
                                    successor: edit, repository)
        }
        guard let receipt else { throw PersonalCartError.staleEntry }
        if presencePolicy == .immediate { republishPresence(each: [token.needID]) }
        return receipt
    }

    private func receipt(for needID: UUID, householdID: UUID, listID: UUID, successor edit: PersonalCartEdit? = nil,
                         _ repository: PersonalCartRepository) throws -> PersonalCartReceipt {
        PersonalCartReceipt(needID: needID, entry: try displayEntries(householdID: householdID, listID: listID,
            repository: repository).first { $0.needID == needID }, successor: edit?.snapshot.token)
    }
}
