import Foundation

struct WatchCommandToken: Codable {
    let authorityID: String
    let accountBinding: String
    let householdID: UUID
    let listID: UUID
    let needID: UUID
    let storeID: UUID?
    let membership: PersonalCartEntryToken?
    let acknowledgedReceipts: Set<UUID>
    let operationID: UUID
    var buyAnywayCapture: PersonalCheckoutToken? = nil
}

struct WatchCheckoutToken: Codable {
    let authorityID: String
    let capture: PersonalCheckoutToken
}

struct WatchRestoreToken: Codable {
    let authorityID: String
    let accountBinding: String
    let householdID: UUID
    let listID: UUID
    let checkoutID: UUID
    let operationID: UUID
}

enum WatchTokenCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        try JSONEncoder().encode(value).base64EncodedString()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ token: String) throws -> T {
        guard let data = Data(base64Encoded: token) else { throw PersonalCartError.staleEntry }
        return try JSONDecoder().decode(type, from: data)
    }
}
