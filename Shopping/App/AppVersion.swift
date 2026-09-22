import Foundation

struct AppVersion: Equatable {
    let marketingVersion: String?
    let sourceCommit: String?

    init(infoDictionary: [String: Any]?, sourceCommit: String? = nil) {
        marketingVersion = infoDictionary?["CFBundleShortVersionString"] as? String
        let commit = sourceCommit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sha = commit?.replacingOccurrences(of: "-dirty", with: "")
        if let sha, sha.count == 40, sha.allSatisfy({ "0123456789abcdef".contains($0) }),
           commit == sha || commit == "\(sha)-dirty" {
            self.sourceCommit = commit
        } else {
            self.sourceCommit = nil
        }
    }

    var displayValue: String {
        let identifier = sourceCommit.map {
            String($0.prefix(8)) + ($0.hasSuffix("-dirty") ? "-dirty" : "")
        }
        switch (marketingVersion, identifier) {
        case let (.some(version), .some(commit)):
            return "\(version) (\(commit))"
        case let (.some(version), .none):
            return "\(version) (Unknown commit)"
        case let (.none, .some(commit)):
            return commit
        case (.none, .none):
            return "Unknown"
        }
    }

    static let current = AppVersion(
        infoDictionary: Bundle.main.infoDictionary,
        sourceCommit: Bundle.main.url(forResource: "BuildCommit", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    )
}
