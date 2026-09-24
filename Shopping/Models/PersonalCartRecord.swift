import CoreData

/// No managed relationships: this graph must never be associated with a household share.
@objc(PersonalCartRecord)
final class PersonalCartRecord: IdentifiedManagedObject {
    @NSManaged var accountBinding: String
    @NSManaged var kind: String
    @NSManaged var command: Data?
    @NSManaged var payload: Data?
}
