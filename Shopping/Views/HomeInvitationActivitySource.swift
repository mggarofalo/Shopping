import LinkPresentation
import UIKit

/// Keeps the private invitation URL intact while giving recipients its purpose.
final class HomeInvitationActivitySource: NSObject, UIActivityItemSource {
    enum Kind { case message, link }

    static let message = "Join my home on Milk and Bananas."
    static let title = "Milk and Bananas invitation"

    private let url: URL
    private let kind: Kind

    private init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    static func items(url: URL) -> [HomeInvitationActivitySource] {
        [Self(url: url, kind: .message), Self(url: url, kind: .link)]
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        kind == .link ? url as Any : Self.message as Any
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if kind == .link { return url }
        // Copy and Reading List act on the URL itself, rather than its introduction.
        if activityType == .copyToPasteboard || activityType == .addToReadingList { return nil }
        return Self.message
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        Self.title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        guard kind == .link else { return nil }
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = Self.title
        if let image = UIImage(systemName: "cart.fill") {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}
