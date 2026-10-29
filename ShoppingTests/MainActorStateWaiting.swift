import XCTest

extension XCTestCase {
    /// Waits for hosted main-actor state and takes the verdict from that state.
    ///
    /// `XCTNSPredicateExpectation` reports through XCTest's waiter. When the host
    /// stalls, that waiter can time out after the predicate was already satisfied
    /// (SHOPPING-259). This loop checks the condition again after every sleep,
    /// including a sleep that outlasts the deadline, before it records a failure.
    @MainActor
    func waitForState(_ description: String, timeout: Duration = .seconds(5),
                      file: StaticString = #filePath, line: UInt = #line,
                      until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting for \(description)", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
