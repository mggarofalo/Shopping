import CoreData

@objc(LegacyCartReview)
final class LegacyCartReview: IdentifiedManagedObject {
    @NSManaged var payload: Data?
    @NSManaged var decision: String
    @NSManaged var claimedAccount: String
}
