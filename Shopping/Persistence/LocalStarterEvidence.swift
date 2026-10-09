import Foundation

/// Positive first-creation provenance for an untouched local starter.
struct LocalStarterEvidence: Codable, Equatable, Sendable {
    let version: Int
    let creationID: UUID
    let graph: HomeGraphIdentity
    let name: String
    let transactionNumber: Int64

}
