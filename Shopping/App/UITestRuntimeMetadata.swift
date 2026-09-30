#if DEBUG
import UIKit

/// Observes runtime facts for explicitly opted-in, isolated UI tests. No app UI,
/// SwiftUI state, font environment, or accessibility properties are changed.
@MainActor final class UITestRuntimeMetadata: NSObject {
    private struct Observation: Encodable, Sendable {
        let nonce: String
        let process: String
        let category: String
        let sequence: UInt64
        let observedUptime: TimeInterval
    }
    private static let processID = UUID().uuidString
    private static var observer: UITestRuntimeMetadata?
    private let nonce: String
    private let fileURL: URL
    private let writer = DispatchQueue(label: "Shopping.UITestRuntimeMetadata")
    private var sequence: UInt64 = 0

    static func install(environment: [String: String]) {
        guard observer == nil,
              let nonce = environment["SHOPPING_UI_TEST_RUNTIME_METADATA"], UUID(uuidString: nonce) != nil,
              let path = environment["SHOPPING_UI_TEST_STORE_PATH"], path.hasPrefix("/"),
              UUID(uuidString: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent) != nil
        else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        observer = UITestRuntimeMetadata(nonce: nonce, fileURL: directory.appendingPathComponent("runtime-\(nonce).json"))
    }

    private init(nonce: String, fileURL: URL) {
        self.nonce = nonce
        self.fileURL = fileURL
        super.init()
        for name in [UIWindow.didBecomeKeyNotification, UIScene.didActivateNotification,
                     UIContentSizeCategory.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        refresh()
    }

    @objc private func refresh() {
        sequence += 1
        let observation = Observation(nonce: nonce, process: Self.processID,
            category: UIApplication.shared.preferredContentSizeCategory.rawValue, sequence: sequence,
            observedUptime: ProcessInfo.processInfo.systemUptime)
        let destination = fileURL
        writer.async {
            // Existing UI fixtures use this exact directory when writable.
            // Metadata never creates a shared container or remaps the path.
            guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { return }
            do {
                try JSONEncoder().encode(observation).write(to: destination, options: .atomic)
            } catch {
                // The test's bounded reader fails if observations stop arriving.
                NSLog("Runtime metadata could not be written for the isolated UI test")
            }
        }
    }
}
#endif
