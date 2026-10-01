import UIKit
import XCTest
@testable import Shopping

@MainActor
final class HomeInvitationActivitySourceTests: XCTestCase {
    func testMessageAndMailContainInvitationPurposeAndOriginalPrivateURL() throws {
        let url = try XCTUnwrap(URL(string: "https://www.icloud.com/share/private-token?invitation=one-time"))
        let items = HomeInvitationActivitySource.items(url: url)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        for activity in [UIActivity.ActivityType.message, .mail, .airDrop] {
            XCTAssertEqual(items[0].activityViewController(controller, itemForActivityType: activity) as? String,
                "Join my home on Milk and Bananas.")
            XCTAssertEqual(items[1].activityViewController(controller, itemForActivityType: activity) as? URL, url)
        }
    }

    func testCopyAndReadingListReceiveOnlyTheUnchangedURL() throws {
        let url = try XCTUnwrap(URL(string: "https://www.icloud.com/share/private-token"))
        let items = HomeInvitationActivitySource.items(url: url)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        for activity in [UIActivity.ActivityType.copyToPasteboard, .addToReadingList] {
            XCTAssertNil(items[0].activityViewController(controller, itemForActivityType: activity))
            XCTAssertEqual(items[1].activityViewController(controller, itemForActivityType: activity) as? URL, url)
        }
    }

    func testSheetMetadataExplainsInvitationWithoutReplacingItsURL() throws {
        let url = try XCTUnwrap(URL(string: "https://www.icloud.com/share/private-token"))
        let items = HomeInvitationActivitySource.items(url: url)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        XCTAssertNil(items[0].activityViewControllerLinkMetadata(controller))
        let metadata = try XCTUnwrap(items[1].activityViewControllerLinkMetadata(controller))
        XCTAssertEqual(metadata.title, "Milk and Bananas invitation")
        XCTAssertEqual(metadata.url, url)
        XCTAssertEqual(metadata.originalURL, url)
        XCTAssertNotNil(metadata.iconProvider)
    }
}
