import XCTest

extension XCUIElement {
    /// Edit the visible field once and verify the resulting draft.
    func replaceText(with text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(isHittable, file: file, line: line)
        tap()
        typeKey("a", modifierFlags: .command)
        typeKey(.delete, modifierFlags: [])
        if let remaining = value as? String, !remaining.isEmpty, remaining != placeholderValue {
            typeKey(.rightArrow, modifierFlags: .command)
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.count))
        }
        if !text.isEmpty { typeText(text) }
        XCTAssertEqual(value as? String, text.isEmpty ? placeholderValue : text, file: file, line: line)
    }

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
