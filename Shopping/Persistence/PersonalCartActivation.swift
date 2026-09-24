import CoreData
import Foundation

enum PersonalCartActivation {
    enum Checkpoint { case intentSaved, stagingCopied, destinationCopied }

    enum ActivationError: Error, Equatable, LocalizedError {
        case missingSource, invalidSource, sourceNotLocal, sourceAlreadyActivated
        case destinationExists, destinationMismatch, invalidLedger

        var errorDescription: String? {
            switch self {
            case .missingSource: return "The local grocery store is unavailable. It has not been replaced."
            case .invalidSource: return "The local grocery store could not be identified safely."
            case .sourceNotLocal: return "This store has account or cloud metadata and cannot be imported as unowned local groceries."
            case .sourceAlreadyActivated: return "These local groceries were already assigned to another account."
            case .destinationExists: return "This account already has local data. Import cannot overwrite it."
            case .destinationMismatch: return "The account store does not match its saved activation. Existing data is retained."
            case .invalidLedger: return "The saved activation could not be verified. Existing data is retained."
            }
        }
    }

    private struct Intent: Codable {
        enum Phase: String, Codable { case pending, complete }
        let version: Int
        let operationID: UUID
        let sourceStoreID: UUID
        let sourceURL: URL
        let accountBinding: String
        let containerIdentifier: String
        let environment: String
        var phase: Phase
    }

    private static let lock = NSLock()
    private static let operationKey = "ShoppingPersonalCartActivationID"
    private static let accountKey = "ShoppingPersonalCartAccountBinding"
    private static let sourceKey = "ShoppingPersonalCartSourceStoreID"
    private static let options: [AnyHashable: Any] = [
        NSPersistentHistoryTrackingKey: true,
        NSPersistentStoreRemoteChangeNotificationPostOptionKey: true
    ]

    /// The app must save and detach its known local-only source before calling this helper.
    /// Only `importLegacy: true` starts an import. A persisted intent is already approved and
    /// may resume on relaunch with false. Neither this copy nor its metadata claims cart ownership.
    static func activate(
        sourceURL: URL?, session: ShopperSession, baseDirectory: URL, importLegacy: Bool,
        checkpoint: (Checkpoint) throws -> Void = { _ in }
    ) throws -> PersistenceConfiguration {
        try lock.withLock {
            let directory = try session.storeDirectory(in: baseDirectory)
            let destination = directory.appendingPathComponent("Private.sqlite")
            let shared = directory.appendingPathComponent("Shared.sqlite")
            let ledgerDirectory = baseDirectory.appendingPathComponent("ActivationLedger", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
            let intents = try readIntents(in: ledgerDirectory)
            let owned = intents.filter { $0.accountBinding == session.accountBinding }
            guard owned.count <= 1 else { throw ActivationError.invalidLedger }

            if importLegacy {
                guard let sourceURL, sourceURL.isFileURL,
                      sourceURL.standardizedFileURL.resolvingSymlinksInPath() !=
                        destination.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw ActivationError.missingSource
                }
                let metadata = try sourceMetadata(at: sourceURL)
                let sourceID = try storeID(metadata)
                if let existing = intents.first(where: { $0.sourceStoreID == sourceID }) {
                    guard existing.accountBinding == session.accountBinding else {
                        throw ActivationError.sourceAlreadyActivated
                    }
                    try resume(existing, session: session, directory: directory,
                               ledgerDirectory: ledgerDirectory, checkpoint: checkpoint)
                } else {
                    guard owned.isEmpty, !storeExists(at: destination), !storeExists(at: shared) else {
                        throw ActivationError.destinationExists
                    }
                    let intent = Intent(
                        version: 1, operationID: UUID(), sourceStoreID: sourceID,
                        sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
                        accountBinding: session.accountBinding, containerIdentifier: session.containerIdentifier,
                        environment: session.environment, phase: .pending
                    )
                    try save(intent, in: ledgerDirectory)
                    try checkpoint(.intentSaved)
                    try resume(intent, session: session, directory: directory,
                               ledgerDirectory: ledgerDirectory, checkpoint: checkpoint)
                }
            } else if let existing = owned.first {
                // Do not open a blank account store after a crash between intent and copy.
                try resume(existing, session: session, directory: directory,
                           ledgerDirectory: ledgerDirectory, checkpoint: checkpoint)
            } else if storeExists(at: destination) {
                let metadata = try metadata(at: destination)
                if let owner = metadata[accountKey] as? String, owner != session.accountBinding {
                    throw ActivationError.destinationMismatch
                }
                // A marked imported store without its ledger is not an unclaimed blank store.
                guard metadata[operationKey] == nil else { throw ActivationError.invalidLedger }
            }
            return .managed(privateURL: destination, sharedURL: shared,
                            containerIdentifier: session.containerIdentifier)
        }
    }

    private static func resume(
        _ saved: Intent, session: ShopperSession, directory: URL, ledgerDirectory: URL,
        checkpoint: (Checkpoint) throws -> Void
    ) throws {
        guard saved.version == 1, saved.accountBinding == session.accountBinding,
              saved.containerIdentifier == session.containerIdentifier,
              saved.environment == session.environment, saved.sourceURL.isFileURL else {
            throw ActivationError.invalidLedger
        }
        let destination = directory.appendingPathComponent("Private.sqlite")
        if storeExists(at: destination) {
            do {
                try validateCopiedMetadata(try metadata(at: destination), intent: saved)
            } catch {
                // Core Data destruction can leave a truncated file, not just a missing URL.
                // Neither state permits replay to overwrite the account's former store.
                throw ActivationError.destinationMismatch
            }
        } else {
            guard saved.phase == .pending else { throw ActivationError.destinationMismatch }
            guard !storeExists(at: directory.appendingPathComponent("Shared.sqlite")) else {
                throw ActivationError.destinationExists
            }
            let staging = directory.appendingPathComponent("Activation-\(saved.operationID.uuidString).sqlite")
            // Replacement operates on opaque stores; loading/migrating the app model happens later.
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            if !storeExists(at: staging) {
                let source = try sourceMetadata(at: saved.sourceURL)
                guard try storeID(source) == saved.sourceStoreID else { throw ActivationError.invalidSource }
                try coordinator.replacePersistentStore(
                    at: staging, destinationOptions: options, withPersistentStoreFrom: saved.sourceURL,
                    sourceOptions: options, ofType: NSSQLiteStoreType
                )
                try checkpoint(.stagingCopied)
            }
            var stagingMetadata = try metadata(at: staging)
            guard try storeID(stagingMetadata) == saved.sourceStoreID else {
                throw ActivationError.destinationMismatch
            }
            if stagingMetadata[operationKey] != nil {
                try validateCopiedMetadata(stagingMetadata, intent: saved)
            } else {
                // A crash immediately after staging copy may precede the metadata save.
                try rejectAccountMetadata(stagingMetadata)
                stagingMetadata[operationKey] = saved.operationID.uuidString
                stagingMetadata[accountKey] = saved.accountBinding
                stagingMetadata[sourceKey] = saved.sourceStoreID.uuidString
                try NSPersistentStoreCoordinator.setMetadata(
                    stagingMetadata, forPersistentStoreOfType: NSSQLiteStoreType, at: staging, options: options
                )
            }
            guard !storeExists(at: destination) else { throw ActivationError.destinationExists }
            try coordinator.replacePersistentStore(
                at: destination, destinationOptions: options, withPersistentStoreFrom: staging,
                sourceOptions: options, ofType: NSSQLiteStoreType
            )
            try checkpoint(.destinationCopied)
            try validateCopiedMetadata(try metadata(at: destination), intent: saved)
        }
        var complete = saved
        complete.phase = .complete
        try save(complete, in: ledgerDirectory)
        // Staging is retained as recovery evidence; it is never used to overwrite an existing target.
    }

    private static func validateCopiedMetadata(_ metadata: [String: Any], intent: Intent) throws {
        guard try storeID(metadata) == intent.sourceStoreID,
              metadata[operationKey] as? String == intent.operationID.uuidString,
              metadata[accountKey] as? String == intent.accountBinding,
              metadata[sourceKey] as? String == intent.sourceStoreID.uuidString else {
            throw ActivationError.destinationMismatch
        }
    }

    private static func sourceMetadata(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ActivationError.missingSource }
        let result = try metadata(at: url)
        try rejectAccountMetadata(result)
        return result
    }

    private static func rejectAccountMetadata(_ metadata: [String: Any]) throws {
        // Public metadata has no authoritative "never used CloudKit" flag. Caller provenance is
        // required; this conservative extra check rejects known cloud/account traces, not certifies absence.
        guard metadata[accountKey] == nil, metadata[operationKey] == nil,
              !metadata.keys.contains(where: {
                  $0.localizedCaseInsensitiveContains("cloudkit") ||
                  $0.localizedCaseInsensitiveContains("ubiquitous")
              }) else { throw ActivationError.sourceNotLocal }
    }

    private static func metadata(at url: URL) throws -> [String: Any] {
        try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: url, options: options
        )
    }

    private static func storeID(_ metadata: [String: Any]) throws -> UUID {
        guard let value = metadata[NSStoreUUIDKey] as? String, let id = UUID(uuidString: value) else {
            throw ActivationError.invalidSource
        }
        return id
    }

    private static func storeExists(at url: URL) -> Bool {
        [url.path, url.path + "-wal", url.path + "-shm"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private static func readIntents(in directory: URL) throws -> [Intent] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                do {
                    let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: url))
                    guard intent.version == 1, url.lastPathComponent == intent.sourceStoreID.uuidString + ".json" else {
                        throw ActivationError.invalidLedger
                    }
                    return intent
                } catch { throw ActivationError.invalidLedger }
            }
    }

    private static func save(_ intent: Intent, in directory: URL) throws {
        try JSONEncoder().encode(intent).write(
            to: directory.appendingPathComponent(intent.sourceStoreID.uuidString + ".json"), options: .atomic
        )
    }
}
