import XCTest

/// Test-only transport to the supervising host's supported `simctl ui` driver.
/// It never overrides app preferences or writes the app's runtime observations.
final class SimulatorTextSizeDriver {
    struct Response: Decodable {
        let id: String
        let token: String
        let lease: String
        let device: String
        let deviceSet: String
        let operation: String
        let category: String?
        let original: String?
        let observed: String?
        let error: String?
    }
    private struct Request: Encodable {
        let id: String
        let token: String
        let lease: String
        let device: String
        let deviceSet: String
        let operation: String
        let category: String?
        let expires: TimeInterval
    }
    private enum Failure: Error { case unavailable, timeout, invalidResponse, host(String) }
    private let root: URL
    private let token: String
    private let device: String
    private let deviceSet: String
    private let timeout: TimeInterval
    private let lease = UUID().uuidString

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SHOPPING_SYSTEM_TEXT_SIZE_ROOT"],
              let token = environment["SHOPPING_SYSTEM_TEXT_SIZE_TOKEN"],
              let device = environment["SIMULATOR_UDID"], UUID(uuidString: device) != nil,
              let resources = environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"],
              let timeoutValue = environment["SHOPPING_SYSTEM_TEXT_SIZE_TIMEOUT"],
              let timeout = TimeInterval(timeoutValue), timeout.isFinite, timeout > 0 else {
            XCTFail("Run system text-size UI tests through .github/scripts/with-system-text-size.py -- xcodebuild …")
            throw Failure.unavailable
        }
        root = URL(fileURLWithPath: path, isDirectory: true)
        self.token = token
        self.timeout = timeout
        self.device = device
        let data = URL(fileURLWithPath: resources, isDirectory: true)
        guard data.lastPathComponent == "data",
              data.deletingLastPathComponent().lastPathComponent == device else {
            XCTFail("Runner simulator resources must identify its own device")
            throw Failure.unavailable
        }
        deviceSet = data.deletingLastPathComponent().deletingLastPathComponent().path
    }

    static func uiKitCategory(for category: String?) -> String? {
        let names = [
            "extra-small": "XS", "small": "S", "medium": "M", "large": "L",
            "extra-large": "XL", "extra-extra-large": "XXL", "extra-extra-extra-large": "XXXL",
            "accessibility-medium": "AccessibilityM", "accessibility-large": "AccessibilityL",
            "accessibility-extra-large": "AccessibilityXL",
            "accessibility-extra-extra-large": "AccessibilityXXL",
            "accessibility-extra-extra-extra-large": "AccessibilityXXXL"
        ]
        guard let category, let suffix = names[category] else { return nil }
        return "UICTContentSizeCategory" + suffix
    }

    func request(_ operation: String, category: String? = nil) throws -> Response {
        let id = UUID().uuidString
        let request = Request(id: id, token: token, lease: lease, device: device, deviceSet: deviceSet,
                              operation: operation, category: category,
                              expires: Date().timeIntervalSince1970 + timeout)
        let requestURL = root.appendingPathComponent("\(id).request.json")
        let responseURL = root.appendingPathComponent("\(id).response.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: responseURL.path)
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: timeout + 1) == .completed else {
            XCTFail("Host system text-size request timed out: \(operation), \(device), \(id)")
            throw Failure.timeout
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: responseURL))
        try FileManager.default.removeItem(at: responseURL)
        guard response.id == id, response.token == token, response.lease == lease,
              response.device == device, response.deviceSet == deviceSet, response.operation == operation,
              response.category == category else {
            XCTFail("Host system text-size response identity mismatch")
            throw Failure.invalidResponse
        }
        if let error = response.error {
            XCTFail("Host system text-size operation failed: \(error)")
            throw Failure.host(error)
        }
        guard response.original != nil, response.observed != nil else {
            XCTFail("Host system text-size response has no exact category readback")
            throw Failure.invalidResponse
        }
        return response
    }
}
