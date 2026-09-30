import Foundation

/// Announce meaningful transitions while this screen is visible, rather than
/// every event, timestamp or pending-operation count update.
struct HomeSharingStatusAnnouncements {
    private var lastTitle: String?

    mutating func observe(title: String) -> String? {
        defer { lastTitle = title }
        guard let lastTitle, lastTitle != title else { return nil }
        return title
    }
}
