import CoreData

struct PersonalCartRepository {
    let persistence: PersistenceController
    let context: NSManagedObjectContext
    let session: ShopperSession

    func privateRecords(kind: String? = nil) throws -> [PersonalCartRecord] {
        let request = NSFetchRequest<PersonalCartRecord>(entityName: "PersonalCartRecord")
        request.predicate = NSPredicate(format: "accountBinding == %@", session.accountBinding)
        request.affectedStores = persistence.primaryStore.map { [$0] }
        return try context.fetch(request).filter { kind == nil || $0.kind == kind }
    }

    func values<T: Codable & Equatable>(_ type: T.Type, kind: String) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for record in try privateRecords(kind: kind) {
            guard record.id != PersistenceModel.unsetID else { throw PersonalCartError.incompleteImport }
            let value = try PersonalCartCoding.decode(type, record.payload)
            if let previous = result[record.id], previous != value { throw PersonalCartError.corruptRecord }
            result[record.id] = value
        }
        return result
    }

    func insert<T: Codable & Equatable, C: Codable & Equatable>(
        id: UUID, kind: String, command: C, value: T
    ) throws {
        guard id != PersistenceModel.unsetID else { throw PersonalCartError.corruptRecord }
        let matches = try privateRecords().filter { $0.id == id }
        if !matches.isEmpty {
            guard try matches.allSatisfy({
                try $0.kind == kind && PersonalCartCoding.equivalent(command, $0.command)
                    && PersonalCartCoding.equivalent(value, $0.payload)
            }) else { throw PersonalCartError.reusedOperationID }
            return
        }
        guard let store = persistence.primaryStore else { throw PersonalCartError.unavailable }
        let record = PersonalCartRecord(context: context)
        context.assign(record, to: store)
        record.id = id
        record.accountBinding = session.accountBinding
        record.kind = kind
        record.command = try PersonalCartCoding.encode(command)
        record.payload = try PersonalCartCoding.encode(value)
    }

    func replay<C: Codable & Equatable, T: Codable & Equatable>(
        id: UUID, kind: String, command: C, as type: T.Type
    ) throws -> T? {
        let records = try privateRecords().filter { $0.id == id }
        guard let first = records.first else { return nil }
        guard try records.allSatisfy({
            try $0.kind == kind && PersonalCartCoding.equivalent(command, $0.command)
        }) else { throw PersonalCartError.reusedOperationID }
        let value = try PersonalCartCoding.decode(type, first.payload)
        guard try records.allSatisfy({ try PersonalCartCoding.equivalent(value, $0.payload) }) else {
            throw PersonalCartError.corruptRecord
        }
        return value
    }

    func household(_ id: UUID) throws -> Household {
        let request = Household.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let records = try context.fetch(request)
        guard records.count == 1 else { throw PersonalCartError.unavailable }
        return records[0]
    }

    func need(_ id: UUID, householdID: UUID, listID: UUID) throws -> Need? {
        let request = Need.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let matches = try context.fetch(request)
        guard matches.count <= 1 else { throw PersonalCartError.corruptRecord }
        guard let need = matches.first else { return nil }
        guard need.list != nil, need.list?.household != nil else { return nil }
        guard need.list?.id == listID, need.list?.household?.id == householdID else {
            throw PersonalCartError.scopeChanged
        }
        return need
    }

    static func sharedValues<T: Codable & Equatable>(
        _ type: T.Type, kind: String, householdID: UUID, in context: NSManagedObjectContext
    ) throws -> [UUID: T] {
        let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
        request.predicate = NSPredicate(format: "kind == %@ AND household.id == %@", kind, householdID as CVarArg)
        var values: [UUID: T] = [:]
        for record in try context.fetch(request) {
            guard record.id != PersistenceModel.unsetID else { throw PersonalCartError.incompleteImport }
            let value = try PersonalCartCoding.decode(type, record.payload)
            if let old = values[record.id], old != value { throw PersonalCartError.corruptRecord }
            values[record.id] = value
        }
        return values
    }

    func publish<T: Codable & Equatable>(_ value: T, id: UUID, kind: String, householdID: UUID) throws {
        let household = try household(householdID)
        if let cloud = persistence.container as? NSPersistentCloudKitContainer,
           !cloud.canUpdateRecord(forManagedObjectWith: household.objectID) {
            throw PersonalCartError.permissionDenied
        }
        let request = NSFetchRequest<HouseholdCartRecord>(entityName: "HouseholdCartRecord")
        request.predicate = NSPredicate(format: "id == %@ AND household == %@", id as CVarArg, household)
        let existing = try context.fetch(request)
        if !existing.isEmpty {
            guard try existing.allSatisfy({ try $0.kind == kind && PersonalCartCoding.equivalent(value, $0.payload) }) else {
                throw PersonalCartError.corruptRecord
            }
            return
        }
        guard let store = household.objectID.persistentStore else { throw PersonalCartError.unavailable }
        let record = HouseholdCartRecord(context: context)
        context.assign(record, to: store)
        record.id = id
        record.kind = kind
        record.payload = try PersonalCartCoding.encode(value)
        record.household = household
    }
}
