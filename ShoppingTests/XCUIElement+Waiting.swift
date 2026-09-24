import XCTest

extension XCUIElement {
    /// Check the current hierarchy before entering XCTest's polling wait.
    /// Existence alone does not establish hittability or a settled interface.
    func existsOrAppears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}
