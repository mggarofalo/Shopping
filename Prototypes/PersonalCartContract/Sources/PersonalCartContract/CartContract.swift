import Foundation

// A deliberately bounded executable specification, not the production persistence layer.
// IDs are strings to make causal histories readable in fixtures; production uses UUIDs.
struct CartEdit: Codable, Equatable {
    enum Kind: String, Codable { case add, quantity, remove }
    let id: String
    let owner: String
    let occurrence: String
    let generation: String
    let ancestors: Set<String>
    let kind: Kind
    let quantity: Int?
}

struct DemandEdit: Codable, Equatable {
    let id: String
    let occurrence: String
    let replacesOccurrence: String?

    init(id: String, occurrence: String, replacesOccurrence: String? = nil) {
        self.id = id
        self.occurrence = occurrence
        self.replacesOccurrence = replacesOccurrence
    }
}

struct CheckoutIntent: Codable, Equatable {
    let id: String
    let owner: String
    let occurrence: String
    let generation: String
    let cartEvidence: Set<String>
    let demandEvidence: Set<String>
    let buyAnyway: Bool
}

struct PurchaseReceipt: Codable, Equatable {
    let intent: CheckoutIntent
}

struct CartSnapshot: Equatable {
    let generation: String
    let quantity: Int?
    let alreadyPurchased: Bool
}

enum ContractError: Error, Equatable {
    case wrongOwner, reusedID, invalidQuantity, incompleteHistory, staleCapture, purchaseNotice
}

struct CartContract: Codable {
    // In production this is an authenticated, account-bound session, not a caller argument.
    let authenticatedOwner: String
    private(set) var cartEdits: [String: CartEdit] = [:]
    private(set) var demandEdits: [String: DemandEdit] = [:]
    private(set) var intents: [String: CheckoutIntent] = [:]
    private(set) var receipts: [String: PurchaseReceipt] = [:]
    private(set) var privateRestores: Set<String> = []
    private(set) var advisoryRetractions: Set<String> = []
    private(set) var completed: Set<String> = []
    private(set) var presence: [String: Int?] = [:]

    mutating func edit(_ edit: CartEdit) throws {
        guard edit.owner == authenticatedOwner else { throw ContractError.wrongOwner }
        if let quantity = edit.quantity, !(1...99).contains(quantity) {
            throw ContractError.invalidQuantity
        }
        if let old = cartEdits[edit.id] {
            guard old == edit else { throw ContractError.reusedID }
            return
        }
        guard edit.ancestors == cartEvidence(edit.occurrence) else {
            throw ContractError.incompleteHistory
        }
        if edit.kind != .add {
            guard snapshot(edit.occurrence)?.generation == edit.generation else {
                throw ContractError.staleCapture
            }
        }
        cartEdits[edit.id] = edit
    }

    mutating func demand(_ edit: DemandEdit) throws {
        if let old = demandEdits[edit.id], old != edit { throw ContractError.reusedID }
        demandEdits[edit.id] = edit
    }

    func capture(id: String, occurrence: String, buyAnyway: Bool = false) throws -> CheckoutIntent {
        guard let entry = snapshot(occurrence) else { throw ContractError.staleCapture }
        guard !entry.alreadyPurchased || buyAnyway else { throw ContractError.purchaseNotice }
        return CheckoutIntent(
            id: id, owner: authenticatedOwner, occurrence: occurrence,
            generation: entry.generation, cartEvidence: cartEvidence(occurrence),
            demandEvidence: demandEvidence(occurrence), buyAnyway: buyAnyway
        )
    }

    // Private durable save A. Retrying exactly the same command replays its outcome.
    mutating func confirm(_ intent: CheckoutIntent) throws {
        guard intent.owner == authenticatedOwner else { throw ContractError.wrongOwner }
        if let old = intents[intent.id] {
            guard old == intent else { throw ContractError.reusedID }
            return
        }
        guard snapshot(intent.occurrence)?.generation == intent.generation,
              cartEvidence(intent.occurrence) == intent.cartEvidence,
              demandEvidence(intent.occurrence) == intent.demandEvidence else {
            throw ContractError.staleCapture
        }
        guard !isPurchased(intent.occurrence) || intent.buyAnyway else {
            throw ContractError.purchaseNotice
        }
        intents[intent.id] = intent
    }

    // Shared durable save B. A receipt records a purchase, not an unconditional delete.
    mutating func publish(_ id: String) throws {
        guard let intent = intents[id] else { throw ContractError.staleCapture }
        let receipt = PurchaseReceipt(intent: intent)
        if let old = receipts[id], old != receipt { throw ContractError.reusedID }
        receipts[id] = receipt
    }

    // Private durable save C. An import can invalidate cart removal later, but not the purchase.
    mutating func finish(_ id: String) throws {
        guard intents[id] != nil, receipts[id] != nil else { throw ContractError.staleCapture }
        completed.insert(id)
    }

    mutating func resume() throws {
        for id in intents.keys.sorted() {
            try publish(id)
            try finish(id)
        }
    }

    mutating func restore(_ id: String) throws {
        guard intents[id]?.owner == authenticatedOwner else { throw ContractError.wrongOwner }
        privateRestores.insert(id)
        advisoryRetractions.insert(id)
    }

    // Transport imports private data only from this account; household receipt imports are advisory.
    // Merge uses a trial value so invalid ID reuse cannot leave a partial imported batch.
    mutating func merge(_ other: CartContract) throws {
        var result = self
        if authenticatedOwner == other.authenticatedOwner {
            try Self.union(&result.cartEdits, other.cartEdits)
            try Self.union(&result.intents, other.intents)
            result.completed.formUnion(other.completed)
            result.privateRestores.formUnion(other.privateRestores)
        }
        try Self.union(&result.demandEdits, other.demandEdits)
        try Self.union(&result.receipts, other.receipts)
        result.advisoryRetractions.formUnion(other.advisoryRetractions)
        self = result
    }

    func snapshot(_ occurrence: String) -> CartSnapshot? {
        let edits = cartEdits.values.filter { $0.occurrence == occurrence }
        guard edits.allSatisfy({ $0.ancestors.isSubset(of: Set(edits.map(\.id))) }) else {
            return nil // Incomplete import is unavailable, never interpreted as removal.
        }
        let tips = edits.filter { edit in !edits.contains { $0.ancestors.contains(edit.id) } }
        // Concurrent explicit remove wins. A later add observes it and starts a new generation.
        guard !tips.contains(where: { $0.kind == .remove }) else { return nil }
        guard let winner = tips.max(by: { $0.id < $1.id }) else { return nil }
        let cleared = completed.contains { id in
            guard let intent = intents[id] else { return false }
            let canRestore = privateRestores.contains(id)
                && !isSuperseded(occurrence)
                && intent.demandEvidence == demandEvidence(occurrence)
            guard !canRestore else { return false }
            return intent.occurrence == occurrence && intent.generation == winner.generation
                && intent.cartEvidence == cartEvidence(occurrence)
        }
        guard !cleared else { return nil }
        return CartSnapshot(generation: winner.generation, quantity: winner.quantity,
                            alreadyPurchased: isPurchased(occurrence))
    }

    // Shared graph writers can forge this projection; it must never restore a private cart.
    mutating func importAdvisoryRetraction(_ receiptID: String) {
        advisoryRetractions.insert(receiptID)
    }

    func isPurchased(_ occurrence: String) -> Bool {
        receipts.contains { !advisoryRetractions.contains($0.key) && $0.value.intent.occurrence == occurrence }
    }

    func isSuperseded(_ occurrence: String) -> Bool {
        demandEdits.values.contains { $0.replacesOccurrence == occurrence }
    }

    func isOutstanding(_ occurrence: String) -> Bool {
        guard !isSuperseded(occurrence) else { return false }
        return !receipts.contains { id, receipt in
            !advisoryRetractions.contains(id) && receipt.intent.occurrence == occurrence
                && receipt.intent.demandEvidence == demandEvidence(occurrence)
        }
    }

    func cartEvidence(_ occurrence: String) -> Set<String> {
        Set(cartEdits.values.filter { $0.occurrence == occurrence }.map(\.id))
    }

    func demandEvidence(_ occurrence: String) -> Set<String> {
        Set(demandEdits.values.filter { $0.occurrence == occurrence }.map(\.id))
    }

    // Advisory damage has no path back into the command state. One bounded explicit pass.
    mutating func damagePresence() { presence = [:] }

    @discardableResult
    mutating func republishPresence() -> Bool {
        var desired: [String: Int?] = [:]
        for occurrence in Set(cartEdits.values.map(\.occurrence)) {
            if let entry = snapshot(occurrence) { desired[occurrence] = .some(entry.quantity) }
        }
        guard desired != presence else { return false }
        presence = desired
        return true
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func reopen(_ url: URL) throws -> CartContract {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    private static func union<T: Equatable>(_ target: inout [String: T], _ source: [String: T]) throws {
        for (key, value) in source {
            if let old = target[key], old != value { throw ContractError.reusedID }
            target[key] = value
        }
    }
}
