import CoreData
import XCTest
@testable import Shopping

final class PersonalCartActivationTests: XCTestCase {
    private enum Interruption: Error { case simulatedCrash }

    func testApprovedImportPreservesSourceAndNeverOverwritesLaterAccountData() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Local.sqlite")
        try append("legacy", to: source)
        let account = try session("alice")
        let base = root.appendingPathComponent("Accounts")
        let configuration = try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true
        )
        let target = try privateURL(configuration)
        XCTAssertEqual(try values(at: source), ["legacy"])
        XCTAssertEqual(try values(at: target), ["legacy"])
        try append("new account edit", to: target)

        XCTAssertEqual(try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true
        ), configuration)
        XCTAssertEqual(try values(at: target), ["legacy", "new account edit"])
        XCTAssertEqual(try values(at: source), ["legacy"])
        let originalMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: source, options: nil
        )
        XCTAssertNil(originalMetadata["ShoppingPersonalCartAccountBinding"])
    }

    func testRecordedApprovalResumesEveryCopyBoundaryWithoutNewApprovalOrBlankStore() throws {
        for point in [PersonalCartActivation.Checkpoint.intentSaved, .stagingCopied, .destinationCopied] {
            let root = try directory()
            let source = root.appendingPathComponent("Local.sqlite")
            try append("saved groceries", to: source)
            let base = root.appendingPathComponent("Accounts")
            let account = try session("alice")
            XCTAssertThrowsError(try PersonalCartActivation.activate(
                sourceURL: source, session: account, baseDirectory: base, importLegacy: true,
                checkpoint: { if $0 == point { throw Interruption.simulatedCrash } }
            ))
            let resumed = try PersonalCartActivation.activate(
                sourceURL: nil, session: account, baseDirectory: base, importLegacy: false
            )
            XCTAssertEqual(try values(at: privateURL(resumed)), ["saved groceries"])
            XCTAssertEqual(try values(at: source), ["saved groceries"])
            XCTAssertEqual(try PersonalCartActivation.activate(
                sourceURL: nil, session: account, baseDirectory: base, importLegacy: false
            ), resumed)
        }
    }

    func testLegacySourceCannotBeClaimedByAnotherAccountAfterIntentOrCompletion() throws {
        for interrupted in [true, false] {
            let root = try directory()
            let source = root.appendingPathComponent("Local.sqlite")
            try append("unattributed", to: source)
            let base = root.appendingPathComponent("Accounts")
            do {
                _ = try PersonalCartActivation.activate(
                    sourceURL: source, session: session("alice"), baseDirectory: base, importLegacy: true,
                    checkpoint: { if interrupted && $0 == .intentSaved { throw Interruption.simulatedCrash } }
                )
            } catch Interruption.simulatedCrash {}
            XCTAssertThrowsError(try PersonalCartActivation.activate(
                sourceURL: source, session: session("bob"), baseDirectory: base, importLegacy: true
            )) { error in
                XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .sourceAlreadyActivated)
            }
            let bob = try PersonalCartActivation.activate(
                sourceURL: nil, session: session("bob"), baseDirectory: base, importLegacy: false
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: try privateURL(bob).path))
        }
    }

    func testExistingAccountStoreIsNotReplacedByLegacyImport() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Local.sqlite")
        try append("legacy", to: source)
        let base = root.appendingPathComponent("Accounts")
        let account = try session("alice")
        let configuration = try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: false
        )
        let target = try privateURL(configuration)
        try append("already imported from cloud", to: target)
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true
        )) { error in
            XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .destinationExists)
        }
        XCTAssertEqual(try values(at: target), ["already imported from cloud"])
        XCTAssertEqual(try values(at: source), ["legacy"])
    }

    func testChangedSourceIdentityAndCorruptLedgerFailClosed() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Local.sqlite")
        try append("original", to: source)
        let base = root.appendingPathComponent("Accounts")
        let account = try session("alice")
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true,
            checkpoint: { if $0 == .intentSaved { throw Interruption.simulatedCrash } }
        ))
        try destroy(source)
        try append("different database", to: source)
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: nil, session: account, baseDirectory: base, importLegacy: false
        )) { error in
            XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .invalidSource)
        }
        let ledgerDirectory = base.appendingPathComponent("ActivationLedger")
        let ledger = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: ledgerDirectory, includingPropertiesForKeys: nil
        ).first)
        try Data("corrupt".utf8).write(to: ledger)
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: nil, session: account, baseDirectory: base, importLegacy: false
        )) { error in
            XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .invalidLedger)
        }
        XCTAssertEqual(try values(at: source), ["different database"])
    }

    func testMissingCompletedDestinationIsNotSilentlyRecreated() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Local.sqlite")
        try append("legacy", to: source)
        let base = root.appendingPathComponent("Accounts")
        let account = try session("alice")
        let configuration = try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true
        )
        try destroy(privateURL(configuration))
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: nil, session: account, baseDirectory: base, importLegacy: false
        )) { error in
            XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .destinationMismatch)
        }
        XCTAssertEqual(try values(at: source), ["legacy"])
    }

    func testCloudMetadataIsRejectedAndNoImportDoesNotReadOrCopySource() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Local.sqlite")
        try append("legacy", to: source)
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: source, options: nil
        )
        metadata["NSPersistentCloudKitContainerMetadata"] = "previous account"
        try NSPersistentStoreCoordinator.setMetadata(
            metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: source, options: nil
        )
        let base = root.appendingPathComponent("Accounts")
        let account = try session("alice")
        XCTAssertThrowsError(try PersonalCartActivation.activate(
            sourceURL: source, session: account, baseDirectory: base, importLegacy: true
        )) { error in
            XCTAssertEqual(error as? PersonalCartActivation.ActivationError, .sourceNotLocal)
        }
        let configuration = try PersonalCartActivation.activate(
            sourceURL: root.appendingPathComponent("Missing.sqlite"), session: account,
            baseDirectory: base, importLegacy: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try privateURL(configuration).path))
        XCTAssertTrue(configuration.isManaged)
    }

    // A tiny independent Core Data model exercises opaque store copy, not Shopping's migration/schema.
    private func coordinator() -> NSPersistentStoreCoordinator {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "ActivationFixture"
        entity.managedObjectClassName = "NSManagedObject"
        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .stringAttributeType
        value.isOptional = true
        entity.properties = [value]
        model.entities = [entity]
        return NSPersistentStoreCoordinator(managedObjectModel: model)
    }

    private func append(_ value: String, to url: URL) throws {
        let coordinator = coordinator()
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSPersistentHistoryTrackingKey: true]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "ActivationFixture", into: context)
            row.setValue(value, forKey: "value")
            try context.save()
            context.reset()
        }
        try coordinator.remove(store)
    }

    private func values(at url: URL) throws -> [String] {
        let coordinator = coordinator()
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let result = try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "ActivationFixture"))
                .compactMap { $0.value(forKey: "value") as? String }.sorted()
        }
        try coordinator.remove(store)
        return result
    }

    private func destroy(_ url: URL) throws {
        try coordinator().destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
    }

    private func privateURL(_ configuration: PersistenceConfiguration) throws -> URL {
        try XCTUnwrap(configuration.stores.first(where: { $0.role == .ownerPrivate })?.url)
    }

    private func session(_ name: String) throws -> ShopperSession {
        try ShopperSession.authenticated(
            containerIdentifier: "iCloud.com.example.activation", environment: "Development", accountRecordName: name
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
