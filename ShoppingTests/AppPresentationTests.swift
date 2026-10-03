import SwiftUI
import UIKit
import XCTest
@testable import Shopping

final class AppPresentationTests: XCTestCase {
    @MainActor
    func testGroceryAccentSharesTheGlobalAdaptivePalette() throws {
        let palettes: [(UIUserInterfaceStyle, CGFloat, CGFloat, CGFloat)] = [
            (.light, 0.10, 0.32, 0.23),
            (.dark, 0.35, 0.72, 0.55)
        ]
        for (style, expectedRed, expectedGreen, expectedBlue) in palettes {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let globalAccent = try XCTUnwrap(UIColor(named: "AccentColor", in: .main, compatibleWith: traits))
            let explicitAccent = UIColor(Color.groceryAccent)
            for color in [globalAccent, explicitAccent] {
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                XCTAssertTrue(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                XCTAssertEqual(red, expectedRed, accuracy: 0.001)
                XCTAssertEqual(green, expectedGreen, accuracy: 0.001)
                XCTAssertEqual(blue, expectedBlue, accuracy: 0.001)
                XCTAssertEqual(alpha, 1, accuracy: 0.001)
            }
        }
    }

    func testAppVersionUsesSourceCommitInsteadOfBuildNumber() {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "2.4.1",
            "CFBundleVersion": "37"
        ], sourceCommit: commit + "\n")

        XCTAssertEqual(version.sourceCommit, commit)
        XCTAssertEqual(version.displayValue, "2.4.1 (01234567)")
        XCTAssertEqual(
            AppVersion(infoDictionary: nil, sourceCommit: commit + "-dirty").displayValue,
            "01234567-dirty"
        )
    }

    func testAppVersionGracefullyHandlesMissingBundleValues() {
        XCTAssertEqual(AppVersion(infoDictionary: nil).displayValue, "Unknown")
        XCTAssertEqual(AppVersion(infoDictionary: ["CFBundleVersion": "37"]).displayValue, "Unknown")
        for commit in [nil, "", "37", "not-a-commit", String(repeating: "g", count: 40)] {
            XCTAssertEqual(
                AppVersion(infoDictionary: ["CFBundleShortVersionString": "2.4.1"], sourceCommit: commit).displayValue,
                "2.4.1 (Unknown commit)"
            )
        }
    }

    func testBuiltAppContainsSourceCommit() {
        XCTAssertNotNil(AppVersion.current.sourceCommit)
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
    func testSuccessActionHasTimeToReadAndNavigateBeforeAutomaticDismissal() async throws {
        let scheduled = expectation(description: "Action dismissal scheduled")
        let release = AsyncGate()
        var scheduledDelay: TimeInterval?
        var navigated = false
        let center = ShoppingToastCenter { delay in
            scheduledDelay = delay
            scheduled.fulfill()
            await release.wait()
        }
        center.show("Added 1.", duration: .success, action: ShoppingToastAction(
            title: "View", accessibilityIdentifier: "view"
        ) {
            navigated = true
            return true
        })
        await fulfillment(of: [scheduled], timeout: 1)
        XCTAssertEqual(scheduledDelay, 10)
        let toast = try XCTUnwrap(center.toasts.first)
        XCTAssertEqual(toast.message, "Added 1.")
        center.performAction(for: toast)
        XCTAssertTrue(navigated)
        XCTAssertTrue(center.toasts.isEmpty)
        await release.open()
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

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
