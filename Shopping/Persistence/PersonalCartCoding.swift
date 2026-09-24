import CryptoKit
import Foundation

enum PersonalCartCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
        guard let data else { throw PersonalCartError.incompleteImport }
        return try JSONDecoder().decode(type, from: data)
    }

    static func stableID(_ components: String...) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(components.joined(separator: "|").utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // Set encoding order is unspecified. Semantic JSON equality canonicalizes nested arrays
    // only where the typed value declares them as Set, by round-tripping through Equatable.
    static func equivalent<T: Codable & Equatable>(_ value: T, _ data: Data?) throws -> Bool {
        try decode(T.self, data) == value
    }
}
