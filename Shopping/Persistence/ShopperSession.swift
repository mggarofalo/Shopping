import CryptoKit
import Foundation

struct ShopperSession: Codable, Equatable, Sendable {
    let accountBinding: String
    let shopperID: UUID
    let containerIdentifier: String
    let environment: String

    // This derivation provides stable identity, not authentication. Only the account provider
    // calls it with a record name obtained from the configured CloudKit container.
    static func authenticated(
        containerIdentifier: String, environment: String, accountRecordName: String
    ) throws -> ShopperSession {
        guard !accountRecordName.isEmpty else { throw ShopperSessionError.invalidIdentity }
        let payload = try JSONEncoder().encode([
            "shopping-account-v1", containerIdentifier, environment, accountRecordName
        ])
        let bytes = Array(SHA256.hash(data: payload))
        let binding = bytes.map { String(format: "%02x", $0) }.joined()
        return ShopperSession(
            accountBinding: binding, shopperID: identityUUID(bytes),
            containerIdentifier: containerIdentifier, environment: environment
        )
    }

    func storeDirectory(in baseURL: URL) throws -> URL {
        guard isWellFormed else { throw ShopperSessionError.invalidIdentity }
        return baseURL.appendingPathComponent(accountBinding, isDirectory: true)
    }

    var isWellFormed: Bool {
        guard accountBinding.count == 64,
              accountBinding.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        let characters = Array(accountBinding)
        let bytes = stride(from: 0, to: characters.count, by: 2).compactMap {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)
        }
        return bytes.count == 32 && shopperID == Self.identityUUID(bytes)
    }

    private static func identityUUID(_ digest: [UInt8]) -> UUID {
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // RFC 9562 application-defined UUID.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum ShopperSessionState: Equatable, Sendable {
    case unresolved
    case ready(ShopperSession)
    case cached(ShopperSession)
    case setupRequired(ShopperSessionError)
    case temporarilyUnavailable(String)
    case accountChanged
}

enum ShopperSessionError: String, Error, LocalizedError, Codable, Sendable {
    case setupRequired
    case accountChanged
    case noAccount
    case restricted
    case temporarilyUnavailable
    case invalidConfiguration
    case invalidIdentity
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .setupRequired: return "Connect to iCloud to set up your personal cart."
        case .accountChanged: return "Your iCloud account changed. Reconnect before opening a personal cart."
        case .noAccount: return "Sign in to iCloud to set up your personal cart."
        case .restricted: return "This device cannot access the iCloud account."
        case .temporarilyUnavailable: return "Your iCloud account is temporarily unavailable. Try again later."
        case .invalidConfiguration: return "The app’s CloudKit account configuration is unavailable."
        case .invalidIdentity: return "The iCloud account could not be identified."
        case .cacheUnavailable: return "The saved account binding could not be read or saved. Your grocery data is retained."
        }
    }
}

protocol ShopperSessionProviding: Sendable {
    func currentSession() throws -> ShopperSession
}
