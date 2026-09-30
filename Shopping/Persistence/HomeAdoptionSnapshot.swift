import CoreData
import CryptoKit
import Foundation

/// Exact persisted domain data, independent of account/CloudKit store metadata.
/// Copy verification must run before managed opening or legacy-review mutation.
struct HomeAdoptionSnapshot: Codable, Equatable, Sendable {
    enum Value: Codable, Equatable, Sendable {
        case null, string(String), integer(Int64), boolean(Bool), uuid(UUID), data(Data)
        case dateBits(UInt64), doubleBits(UInt64), floatBits(UInt32), decimal(String), uri(String)
    }

    struct Attribute: Codable, Equatable, Sendable {
        let name: String
        let type: UInt
        let value: Value
    }

    struct Relationship: Codable, Equatable, Sendable {
        let name: String
        let toMany: Bool
        let ordered: Bool
        let targets: [String]
    }

    struct Record: Codable, Equatable, Sendable {
        let entity: String
        let objectURI: String
        let attributes: [Attribute]
        let relationships: [Relationship]
    }

    enum Failure: Error, Equatable, LocalizedError {
        case unsavedChanges, unidentifiedStore, temporaryObject, unsupportedAttribute(String)
        case unsupportedRelationship(String), invalidEntity, mismatch

        var errorDescription: String? {
            "The copied groceries could not be verified. Your original home has been retained and has not been replaced."
        }
    }

    let storeIdentifiers: [String]
    let records: [Record]

    var fingerprint: String {
        get throws {
            SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
        }
    }

    func verify(matches expected: HomeAdoptionSnapshot) throws {
        // Swift String equality normalizes canonically equivalent Unicode. Comparing
        // deterministic encoded bytes additionally preserves the original scalar values.
        guard try canonicalData() == expected.canonicalData() else { throw Failure.mismatch }
    }

    private func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Call from the adoption worker. The serial writer establishes a consistent local
    /// command boundary; only immutable values leave its queue. Never saves pending edits.
    static func capture(persistence: PersistenceController) throws -> HomeAdoptionSnapshot {
        try persistence.writer.performAndWait {
            guard !persistence.writer.hasChanges else { throw Failure.unsavedChanges }
            return try capture(in: persistence.writer)
        }
    }

    /// Synchronous worker-only helper. Opens the already-migrated current model locally,
    /// read-only, and fully detaches before returning. It never enables CloudKit.
    static func capture(at storeURL: URL) throws -> HomeAdoptionSnapshot {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: try PersistenceModel.make())
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: storeURL, options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let result = context.performAndWait { () -> Result<HomeAdoptionSnapshot, Error> in
            defer { context.reset() }
            return Result { try capture(in: context) }
        }
        try coordinator.remove(store)
        return try result.get()
    }

    private static func capture(in context: NSManagedObjectContext) throws -> HomeAdoptionSnapshot {
        guard let coordinator = context.persistentStoreCoordinator else { throw Failure.unidentifiedStore }
        let stores = try coordinator.persistentStores.map { store -> String in
            guard let identifier = coordinator.metadata(for: store)[NSStoreUUIDKey] as? String,
                  UUID(uuidString: identifier) != nil else { throw Failure.unidentifiedStore }
            return identifier
        }.sorted()
        guard !stores.isEmpty, Set(stores).count == stores.count else { throw Failure.unidentifiedStore }
        var records: [Record] = []
        for entity in coordinator.managedObjectModel.entities where !entity.isAbstract {
            guard let name = entity.name else { throw Failure.invalidEntity }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.includesSubentities = false
            request.includesPendingChanges = false
            request.shouldRefreshRefetchedObjects = true
            for object in try context.fetch(request) {
                let attributes = try entity.attributesByName.values.filter { !$0.isTransient }
                    .sorted { $0.name < $1.name }.map { attribute in
                        // Custom convenience getters can replace persisted nil UUID/quantity
                        // with sentinels. Read the stored primitive after firing its fault.
                        object.willAccessValue(forKey: attribute.name)
                        let raw = object.primitiveValue(forKey: attribute.name)
                        object.didAccessValue(forKey: attribute.name)
                        return Attribute(name: attribute.name, type: attribute.attributeType.rawValue,
                            value: try value(raw, attribute: attribute))
                    }
                let relationships = try entity.relationshipsByName.values.filter { !$0.isTransient }
                    .sorted { $0.name < $1.name }.map { relationship in
                        try relationshipValue(object.value(forKey: relationship.name), description: relationship)
                    }
                records.append(Record(entity: name, objectURI: try objectURI(object),
                    attributes: attributes, relationships: relationships))
            }
        }
        return HomeAdoptionSnapshot(storeIdentifiers: stores, records: records.sorted { $0.objectURI < $1.objectURI })
    }

    private static func objectURI(_ object: NSManagedObject) throws -> String {
        guard !object.objectID.isTemporaryID, object.objectID.persistentStore != nil else { throw Failure.temporaryObject }
        return object.objectID.uriRepresentation().absoluteString
    }

    private static func relationshipValue(_ raw: Any?, description: NSRelationshipDescription) throws -> Relationship {
        let targets: [String]
        if description.isToMany {
            if description.isOrdered, let ordered = raw as? NSOrderedSet {
                targets = try ordered.map { value in
                    guard let object = value as? NSManagedObject else { throw Failure.unsupportedRelationship(description.name) }
                    return try objectURI(object)
                }
            } else if !description.isOrdered, let unordered = raw as? NSSet {
                targets = try unordered.map { value in
                    guard let object = value as? NSManagedObject else { throw Failure.unsupportedRelationship(description.name) }
                    return try objectURI(object)
                }.sorted()
            } else if raw == nil { targets = [] }
            else { throw Failure.unsupportedRelationship(description.name) }
        } else if let object = raw as? NSManagedObject { targets = [try objectURI(object)] }
        else if raw == nil { targets = [] }
        else { throw Failure.unsupportedRelationship(description.name) }
        return Relationship(name: description.name, toMany: description.isToMany,
            ordered: description.isOrdered, targets: targets)
    }

    private static func value(_ raw: Any?, attribute: NSAttributeDescription) throws -> Value {
        // Reject unsupported schema types even when their current persisted value is nil.
        switch attribute.attributeType {
        case .stringAttributeType, .integer16AttributeType, .integer32AttributeType, .integer64AttributeType,
             .booleanAttributeType, .UUIDAttributeType, .binaryDataAttributeType, .dateAttributeType,
             .doubleAttributeType, .floatAttributeType, .decimalAttributeType, .URIAttributeType: break
        default: throw Failure.unsupportedAttribute(attribute.name)
        }
        guard let raw else { return .null }
        switch attribute.attributeType {
        case .stringAttributeType: if let value = raw as? String { return .string(value) }
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
            if let value = raw as? NSNumber { return .integer(value.int64Value) }
        case .booleanAttributeType: if let value = raw as? NSNumber { return .boolean(value.boolValue) }
        case .UUIDAttributeType: if let value = raw as? UUID { return .uuid(value) }
        case .binaryDataAttributeType: if let value = raw as? Data { return .data(value) }
        case .dateAttributeType: if let value = raw as? Date { return .dateBits(value.timeIntervalSinceReferenceDate.bitPattern) }
        case .doubleAttributeType: if let value = raw as? NSNumber { return .doubleBits(value.doubleValue.bitPattern) }
        case .floatAttributeType: if let value = raw as? NSNumber { return .floatBits(value.floatValue.bitPattern) }
        case .decimalAttributeType: if let value = raw as? NSDecimalNumber { return .decimal(value.stringValue) }
        case .URIAttributeType: if let value = raw as? URL { return .uri(value.absoluteString) }
        default: break
        }
        throw Failure.unsupportedAttribute(attribute.name)
    }
}
