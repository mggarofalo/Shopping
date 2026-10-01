import Foundation

/// Immutable advisory data and the generation authorizing publication have
/// separate roles when recovering records written by earlier app versions.
struct PersonalCartPresencePublication {
    let event: HouseholdPresenceEvent
    let authorityGeneration: UUID
    let legacyGeneration: UUID

    init(session: ShopperSession, reference: PersonalCartEntrySnapshot,
         entry: PersonalCartEntrySnapshot?, generation: UUID, evidence: Set<UUID>) {
        authorityGeneration = generation
        legacyGeneration = entry?.id ?? reference.id
        let id = PersonalCartCoding.stableID("presence", session.shopperID.uuidString,
            reference.needID.uuidString, evidence.map(\.uuidString).sorted().joined(separator: ","))
        event = HouseholdPresenceEvent(id: id, shopperID: session.shopperID,
            householdID: reference.householdID, listID: reference.listID, needID: reference.needID,
            quantity: entry?.quantity, generation: generation, evidence: evidence, removed: entry == nil)
    }

    func retaining(_ existing: HouseholdPresenceEvent?) throws -> HouseholdPresenceEvent {
        guard let existing else { return event }
        let legacy = HouseholdPresenceEvent(id: event.id, shopperID: event.shopperID,
            householdID: event.householdID, listID: event.listID, needID: event.needID,
            quantity: event.quantity, generation: legacyGeneration, evidence: event.evidence, removed: event.removed)
        // Only the exact historical producer variant is compatible. Never rewrite
        // an immutable record or relax validation of any other payload field.
        guard existing == event || existing == legacy else { throw PersonalCartError.corruptRecord }
        return existing
    }
}
