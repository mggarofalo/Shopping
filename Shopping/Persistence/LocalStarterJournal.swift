import Foundation

/// Provenance is retained independently of the acknowledged creation request.
struct LocalStarterJournal {
    let storeURL: URL
    private var url: URL { storeURL.appendingPathExtension("starter.json") }

    func load() throws -> LocalStarterEvidence? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(LocalStarterEvidence.self, from: Data(contentsOf: url))
        guard value.version == 1, value.creationID != PersistenceModel.unsetID,
              value.transactionNumber > 0 else { throw HomeDeletionError.scopeChanged }
        return value
    }

    func save(_ evidence: LocalStarterEvidence) throws {
        try JSONEncoder().encode(evidence).write(to: url, options: .atomic)
    }
}
