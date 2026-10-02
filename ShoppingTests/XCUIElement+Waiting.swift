import XCTest

extension XCUIElement {
    /// Check the current hierarchy before entering XCTest's polling wait.
    /// Existence alone does not establish hittability or a settled interface.
    func existsOrAppears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}

extension XCUIApplication {
    /// Workflow fixtures explicitly cross first launch before testing list behavior.
    func createFirstHomeForWorkflow(file: StaticString = #filePath, line: UInt = #line) {
        let create = buttons["shopping.home.createFirst"]
        XCTAssertTrue(create.existsOrAppears(timeout: 8), file: file, line: line)
        XCTAssertTrue(create.isHittable, file: file, line: line)
        create.tap()
        XCTAssertTrue(navigationBars["Groceries"].existsOrAppears(timeout: 8), file: file, line: line)
    }
}
