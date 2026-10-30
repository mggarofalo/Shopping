import os

/// Records Siri action outcomes without grocery text, so a device capture can show
/// whether a request reached the app and how it ended. Notice level is kept in
/// sysdiagnose archives; info level is often not (SHOPPING-266).
enum SiriActionLog {
    static let logger = Logger(subsystem: "com.mggarofalo.shopping", category: "Siri")

    static func started(_ action: String) {
        logger.notice("\(action, privacy: .public) started")
    }

    static func finished(_ action: String, _ outcome: String) {
        logger.notice("\(action, privacy: .public) finished: \(outcome, privacy: .public)")
    }

    static func failed(_ action: String, _ error: Error) {
        logger.error("\(action, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
    }
}
