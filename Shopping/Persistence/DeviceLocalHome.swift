import Foundation

/// The device-local route is independent of whichever account is currently open.
/// Account adoption and a later selected graph carry different proofs.
enum DeviceLocalHome: Equatable, Sendable {
    case adopted(HomeAdoptionJournal.Record)
    case selected(DeviceLocalHomeSelection)

    var sourceURL: URL? {
        switch self {
        case .adopted(let record): record.sourceURL
        case .selected(let source): source.sourceURL
        }
    }

    var storeIdentifier: String? {
        switch self {
        case .adopted(let record): record.proposal.sourceStoreIdentifier
        case .selected(let source): source.graph.storeIdentifier
        }
    }

    var householdID: UUID? {
        switch self {
        case .adopted(let record): record.householdID
        case .selected(let source): source.graph.householdID
        }
    }

    var listID: UUID? {
        switch self {
        case .adopted(let record): record.listID
        case .selected(let source): source.graph.listID
        }
    }

    var homeName: String {
        switch self {
        case .adopted(let record): record.homeName
        case .selected(let source): source.homeName
        }
    }

    var session: ShopperSession {
        switch self {
        case .adopted(let record): record.session
        case .selected(let source): source.session
        }
    }

    var conversionID: UUID? {
        if case .selected(let source) = self { return source.conversionID }
        return nil
    }

    var adoptionRecordID: UUID? {
        if case .adopted(let record) = self { return record.id }
        return nil
    }
}

/// Captured before an invitation connection or an explicit copy retires the
/// local presentation. A conversion ID is approval to copy, never to join.
struct DeviceLocalHomeSelection: Codable, Equatable, Sendable {
    let sourceURL: URL
    let graph: HomeGraphIdentity
    let homeName: String
    let session: ShopperSession
    var conversionID: UUID?
}
