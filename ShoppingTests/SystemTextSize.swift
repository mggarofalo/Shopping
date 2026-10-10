import XCTest

/// Exercises real system text-size changes through the supported Simulator driver.
/// Runtime observations remain independent and come from the retained app.
final class SystemTextSize {
    enum Size {
        case large, accessibilityXXXL
        var category: String {
            switch self {
            case .large: return "UICTContentSizeCategoryL"
            case .accessibilityXXXL: return "UICTContentSizeCategoryAccessibilityXXXL"
            }
        }
    }
    private struct Metadata: Codable {
        let nonce: String
        let sequence: UInt64
        let observedUptime: TimeInterval
        let process: String
        let category: String
    }
    private enum Failure: Error { case metadata, timeout, appStopped }
    private unowned let test: XCTestCase
    private let app: XCUIApplication
    private let driver: SimulatorTextSizeDriver
    private let nonce: String
    private let fileURL: URL
    private let original: Metadata

    static func configure(_ app: XCUIApplication) {
        app.launchEnvironment["SHOPPING_UI_TEST_RUNTIME_METADATA"] = UUID().uuidString
    }

    init(test: XCTestCase, app: XCUIApplication) throws {
        self.test = test
        self.app = app
        driver = try SimulatorTextSizeDriver()
        guard let nonce = app.launchEnvironment["SHOPPING_UI_TEST_RUNTIME_METADATA"] else { throw Failure.metadata }
        self.nonce = nonce
        guard let storePath = app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] else { throw Failure.metadata }
        let metadataURL = URL(fileURLWithPath: storePath).deletingLastPathComponent().appendingPathComponent("runtime-\(nonce).json")
        fileURL = metadataURL
        let metadataReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Self.readMetadata(fileURL: metadataURL, nonce: nonce)) != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [metadataReady], timeout: 8) == .completed else {
            let evidence = XCTAttachment(string: "Runtime metadata unavailable at \(metadataURL.path)\n\(String(describing: try? String(contentsOf: metadataURL, encoding: .utf8)))\n\(app.debugDescription)")
            evidence.name = "Runtime metadata unavailable"
            evidence.lifetime = .keepAlways
            test.add(evidence)
            XCTFail("The isolated app must publish nonce-matching runtime metadata")
            throw Failure.metadata
        }
        original = try Self.readMetadata(fileURL: metadataURL, nonce: nonce)
        let captured = try driver.request("acquire")
        attach("Original system text size", text: "host=\(captured.observed ?? "missing") UIKit=\(original.category)")
        // The host owns the original global category before the first mutation;
        // it also restores abandoned leases if teardown cannot complete.
        test.addTeardownBlock { [self] in
            do {
                // Restore the OS even when the retained app has unexpectedly
                // stopped; that still fails the behavioral proof below.
                var backgroundFailure: Error?
                do { try backgroundRetainedApp() } catch { backgroundFailure = error }
                let restored = try driver.request("restore")
                guard restored.observed == captured.original else {
                    XCTFail("Restoration must match the original global system category")
                    throw Failure.metadata
                }
                if let backgroundFailure { throw backgroundFailure }
                let observed = try activateRetainedApp(category: original.category)
                attach("Restored system text size", text: "host=\(restored.observed ?? "missing")\n" + String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
            } catch {
                XCTFail("Could not restore original system text size: \(error)")
            }
        }
        guard SimulatorTextSizeDriver.uiKitCategory(for: captured.original) == original.category else {
            XCTFail("Initial Shopping category must match the global Simulator category")
            throw Failure.metadata
        }
        try set(.large)
    }

    func set(_ size: Size) throws {
        try backgroundRetainedApp()
        let category = size == .large ? "large" : "accessibility-extra-extra-extra-large"
        let response = try driver.request("set", category: category)
        guard response.observed == category else {
            XCTFail("The host must read back the exact requested system category")
            throw Failure.metadata
        }
        let observed = try activateRetainedApp(category: size.category)
        attach("System text size \(size)", text: "host=\(response.observed ?? "missing")\n" + String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
    }

    private func backgroundRetainedApp() throws {
        guard app.state != .notRunning else {
            attach("Stopped app during system text-size transition", text: "appState=\(app.state.rawValue)")
            throw Failure.appStopped
        }
        XCUIDevice.shared.press(.home)
        try wait("Shopping must remain running in the background during the system change") {
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        }
    }

    private func activateRetainedApp(category: String) throws -> Metadata {
        guard app.state != .notRunning else {
            XCTFail("The app stopped during the system text-size roundtrip; activation must not relaunch it")
            throw Failure.appStopped
        }
        let previous = try Self.readMetadata(fileURL: fileURL, nonce: nonce)
        let activationStarted = ProcessInfo.processInfo.systemUptime
        app.activate()
        var accepted: Metadata?
        try wait("Fresh UIKit category observation from the retained process; activation began at \(activationStarted)") {
            guard let metadata = try? Self.readMetadata(fileURL: self.fileURL, nonce: self.nonce),
                  self.app.state == .runningForeground,
                  metadata.process == self.original.process, metadata.category == category,
                  metadata.sequence > previous.sequence, metadata.observedUptime >= activationStarted
            else { return false }
            accepted = metadata
            return true
        }
        guard let accepted else { throw Failure.metadata }
        return accepted
    }

    private static func readMetadata(fileURL: URL, nonce: String) throws -> Metadata {
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: fileURL))
        guard metadata.nonce == nonce, UUID(uuidString: metadata.process) != nil, metadata.sequence > 0 else { throw Failure.metadata }
        return metadata
    }

    private func wait(_ description: String, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
            attach("Runtime observation at timeout", text: "\(description)\nappState=\(app.state.rawValue)\n\(String(describing: try? String(contentsOf: fileURL, encoding: .utf8)))")
            // Propagate first so teardown can restore the OS before XCTest
            // reports failure under continueAfterFailure = false.
            throw Failure.timeout
        }
    }

    private func attach(_ name: String, text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
