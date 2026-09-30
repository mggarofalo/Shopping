import XCTest

/// Exercises the real Settings controls. Runtime observations arrive through
/// the existing isolated fixture directory, without changing the app's UI.
final class SystemTextSizeSettings {
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
    private enum Failure: Error { case missingControls, metadata, timeout, appStopped }
    private unowned let test: XCTestCase
    private let app: XCUIApplication
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let nonce: String
    private let fileURL: URL
    private let original: Metadata
    private var toggleMatches: XCUIElementQuery { settings.switches.matching(identifier: "LARGER_DYNAMIC_TYPE_SWITCH") }
    private var sliderCells: XCUIElementQuery { settings.cells.matching(identifier: "DYNAMIC_TYPE_SLIDER") }
    private var toggle: XCUIElement { toggleMatches.element }
    private var switchControl: XCUIElement { toggle.switches.element(boundBy: 0) }
    private var slider: XCUIElement { sliderCells.element.sliders.element(boundBy: 0) }

    static func configure(_ app: XCUIApplication) {
        app.launchEnvironment["SHOPPING_UI_TEST_RUNTIME_METADATA"] = UUID().uuidString
    }

    init(test: XCTestCase, app: XCUIApplication) throws {
        self.test = test
        self.app = app
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
        settings.launch()
        if !settings.navigationBars["Larger Text"].exists {
            let accessibility = settings.buttons["com.apple.settings.accessibility"]
            guard accessibility.existsOrAppears(timeout: 5), accessibility.isHittable else {
                XCTFail("Settings control unavailable: com.apple.settings.accessibility")
                throw Failure.missingControls
            }
            accessibility.tap()
            try openSettingsRow(identifier: "DISPLAY_AND_TEXT", source: "Accessibility", destination: "Display & Text Size")
            try openSettingsRow(identifier: "LARGER_TEXT", source: "Display & Text Size", destination: "Larger Text")
        }
        // Observe both controls before the verdict: a missing range switch
        // must not prevent the same run from diagnosing the slider's shape.
        let navigationReady = settings.navigationBars["Larger Text"].existsOrAppears(timeout: 5)
        let toggleCount = toggleMatches.count
        let switchCount = toggleCount == 1 ? toggle.switches.count : nil
        let sliderCellCount = sliderCells.count
        let sliderCount = sliderCellCount == 1 ? sliderCells.element.sliders.count : nil
        let toggleValue = toggleCount == 1 ? toggle.value as? String : nil
        let sliderValue = sliderCount == 1 ? slider.value as? String : nil
        attach("Larger Text control inventory", text:
            "navigationReady=\(navigationReady) toggles=\(toggleCount) nestedSwitches=\(String(describing: switchCount)) " +
            "sliderCells=\(sliderCellCount) sliders=\(String(describing: sliderCount)) " +
            "toggleValue=\(String(describing: toggleValue)) sliderValue=\(String(describing: sliderValue))\n" +
            settings.debugDescription)
        guard navigationReady, toggleCount == 1, switchCount == 1,
              sliderCellCount == 1, sliderCount == 1,
              let originalToggle = toggleValue, let originalValue = sliderValue
        else { XCTFail("Larger Text must expose one switch and slider"); throw Failure.missingControls }
        let originalPosition = slider.normalizedSliderPosition
        attach("Original Settings text size", text: "switch=\(originalToggle) slider=\(originalPosition) value=\(originalValue) category=\(original.category)")
        // Registered before either global Settings control is changed.
        test.addTeardownBlock { [self] in
            do {
                settings.activate()
                try setControls(toggleValue: originalToggle, position: originalPosition)
                try wait("Restore the exact original displayed slider value") { self.slider.value as? String == originalValue }
                let restoredControls = "switch=\(toggle.value as? String ?? "missing") slider=\(slider.normalizedSliderPosition) value=\(slider.value as? String ?? "missing")"
                let observed = try activateRetainedApp(category: original.category)
                attach("Restored Settings text size", text: restoredControls + "\n" + String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
            } catch {
                XCTFail("Could not restore original Settings text size: \(error)")
            }
        }
        try set(.large)
    }

    private func openSettingsRow(identifier: String, source: String, destination: String) throws {
        guard settings.navigationBars[source].existsOrAppears(timeout: 5) else {
            XCTFail("Settings must reach \(source) before opening \(destination)")
            throw Failure.missingControls
        }
        let buttons = settings.buttons.matching(identifier: identifier)
        // These navigation rows expose StaticText in cells on iOS 18.5 and
        // buttons on iOS 26.5. Resolve each row by identity, not its label.
        let cells = settings.cells.containing(.staticText, identifier: identifier)
        try wait("Settings must expose one hittable \(identifier) control") {
            if buttons.count == 1 { return buttons.element.isHittable }
            return buttons.count == 0 && cells.count == 1 && cells.element.isHittable
        }
        let control = buttons.count == 1 ? buttons.element : cells.element
        control.tap()
        guard settings.navigationBars[destination].existsOrAppears(timeout: 5) else {
            XCTFail("Settings must reach \(destination) after the single navigation tap")
            throw Failure.missingControls
        }
    }

    func set(_ size: Size) throws {
        settings.activate()
        // Keep one range throughout the workflow. Large is the fourth of the
        // twelve system sizes; XXXL is the final accessibility size. The slider
        // API is best effort, so actual UIKit observations remain authoritative.
        try setControls(toggleValue: "1", position: size == .large ? CGFloat(3) / 11 : 1)
        let controls = "switch=\(toggle.value as? String ?? "missing") slider=\(slider.normalizedSliderPosition) value=\(slider.value as? String ?? "missing")"
        attach("Settings controls for \(size)", text: controls)
        let observed = try activateRetainedApp(category: size.category)
        attach("System text size \(size)", text: String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
    }

    private func setControls(toggleValue: String, position: CGFloat) throws {
        try wait("Larger Text controls must be reachable after Settings activation") {
            self.switchControl.exists && self.switchControl.isHittable && self.slider.exists && self.slider.isHittable
        }
        if toggle.value as? String != toggleValue { switchControl.tap() }
        try wait("Settings range switch") { self.toggle.value as? String == toggleValue }
        slider.adjust(toNormalizedSliderPosition: position)
        try wait("Settings text size slider") { abs(self.slider.normalizedSliderPosition - position) <= 0.001 }
    }

    private func activateRetainedApp(category: String) throws -> Metadata {
        guard app.state != .notRunning else {
            XCTFail("The app stopped during the Settings roundtrip; activation must not relaunch it")
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
            XCTFail(description)
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
