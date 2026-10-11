import Foundation

struct HomeReplacementOriginJournal: Sendable {
    let base: URL
    let session: ShopperSession
    private var url: URL { get throws { try session.storeDirectory(in: base).appendingPathComponent("home-replacement-origin.json") } }

    func save(_ origin: HomeReplacementOrigin) throws {
        guard origin.source.session == session else { throw HomeReplacementError.invalidProposal }
        let destination = try url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(origin).write(to: destination, options: .atomic)
    }

    func load() throws -> HomeReplacementOrigin? {
        let source = try url
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let origin = try JSONDecoder().decode(HomeReplacementOrigin.self, from: Data(contentsOf: source))
        guard origin.source.session == session else { throw HomeReplacementError.invalidProposal }
        return origin
    }
}
