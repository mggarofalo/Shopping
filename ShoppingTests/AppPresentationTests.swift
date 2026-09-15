import XCTest
@testable import Shopping

final class AppPresentationTests: XCTestCase {
    func testAppVersionIncludesMarketingVersionAndBuild() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "2.4.1",
            "CFBundleVersion": "37"
        ])

        XCTAssertEqual(version.displayValue, "2.4.1 (37)")
    }

    func testAppVersionGracefullyHandlesMissingBundleValues() {
        XCTAssertEqual(AppVersion(infoDictionary: nil).displayValue, "Unknown")
        XCTAssertEqual(
            AppVersion(infoDictionary: ["CFBundleVersion": "37"]).displayValue,
            "Build 37"
        )
    }

    @MainActor
    func testToastCenterUsesNormalizedDelayAndDismisses() async {
        XCTAssertEqual(ShoppingToastDuration.success.rawValue, 3)
        XCTAssertEqual(ShoppingToastDuration.attention.rawValue, 5)
        XCTAssertEqual(ShoppingToastDuration.undo.rawValue, 10)

        let scheduled = expectation(description: "Toast dismissal scheduled")
        var scheduledDelay: TimeInterval?
        let center = ShoppingToastCenter { delay in
            scheduledDelay = delay
            scheduled.fulfill()
        }
        let toastID = center.show("Review this", duration: .attention)
        XCTAssertEqual(center.toasts.map(\.id), [toastID])

        await fulfillment(of: [scheduled], timeout: 1)
        await Task.yield()

        XCTAssertEqual(scheduledDelay, 5)
        XCTAssertTrue(center.toasts.isEmpty)

        let relaunchedCenter = ShoppingToastCenter()
        XCTAssertTrue(relaunchedCenter.toasts.isEmpty)
    }

    @MainActor
    func testToastActionDismissesOnlyAfterSuccess() throws {
        var succeeds = false
        let center = ShoppingToastCenter { _ in
            try await Task.sleep(for: .seconds(60))
        }
        center.show(
            "Item removed",
            duration: .undo,
            action: ShoppingToastAction(
                title: "Undo",
                accessibilityIdentifier: "undo"
            ) {
                succeeds
            }
        )
        let toast = try XCTUnwrap(center.toasts.first)

        center.performAction(for: toast)
        XCTAssertEqual(center.toasts.count, 1)

        succeeds = true
        center.performAction(for: toast)
        XCTAssertTrue(center.toasts.isEmpty)
    }
}
