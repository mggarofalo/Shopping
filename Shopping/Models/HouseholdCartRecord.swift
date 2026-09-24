import CoreData

/// Household evidence and advisory projections, never personal-cart authority.
@objc(HouseholdCartRecord)
final class HouseholdCartRecord: IdentifiedManagedObject {
    @NSManaged var kind: String
    @NSManaged var payload: Data?
    @NSManaged var household: Household?
}
