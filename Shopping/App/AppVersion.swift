import Foundation

struct AppVersion: Equatable {
    let marketingVersion: String?
    let buildNumber: String?

    init(infoDictionary: [String: Any]?) {
        marketingVersion = infoDictionary?["CFBundleShortVersionString"] as? String
        buildNumber = infoDictionary?["CFBundleVersion"] as? String
    }

    var displayValue: String {
        switch (marketingVersion, buildNumber) {
        case let (.some(version), .some(build)):
            "\(version) (\(build))"
        case let (.some(version), .none):
            version
        case let (.none, .some(build)):
            "Build \(build)"
        case (.none, .none):
            "Unknown"
        }
    }

    static let current = AppVersion(infoDictionary: Bundle.main.infoDictionary)
}
