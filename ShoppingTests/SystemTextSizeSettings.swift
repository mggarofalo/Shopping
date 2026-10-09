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
    private struct Controls {
        let rangeValueElement: XCUIElement
        let rangeSwitch: XCUIElement
        let slider: XCUIElement

        var rangeValue: String? { Self.readRangeValue(from: rangeValueElement) }

        static func readRangeValue(from element: XCUIElement?) -> String? {
            // XCUIElement.value has a variable raw type. Accept only the two
            // observed switch states, represented as text or a number.
            switch element?.value {
            case let value as String where value == "0" || value == "1": return value
            case let value as NSNumber where value == 0: return "0"
            case let value as NSNumber where value == 1: return "1"
            default: return nil
            }
        }

        var description: String {
            "switch=\(rangeValue ?? "missing") slider=\(slider.normalizedSliderPosition) value=\(slider.value as? String ?? "missing")"
        }
    }
    private enum Failure: Error { case missingControls, metadata, timeout, appStopped }
    private unowned let test: XCTestCase
    private let app: XCUIApplication
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let nonce: String
    private let fileURL: URL
    private let original: Metadata

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
            if !settings.navigationBars["Display & Text Size"].exists {
                let accessibility = settings.buttons["com.apple.settings.accessibility"]
                guard accessibility.existsOrAppears(timeout: 5), accessibility.isHittable else {
                    XCTFail("Settings control unavailable: com.apple.settings.accessibility")
                    throw Failure.missingControls
                }
                accessibility.tap()
                try openSettingsRow(identifier: "DISPLAY_AND_TEXT", source: "Accessibility", destination: "Display & Text Size")
            }
            try openSettingsRow(identifier: "LARGER_TEXT", source: "Display & Text Size", destination: "Larger Text")
        }
        let controls = try readControls(captureInventory: true)
        guard let originalToggle = controls.rangeValue, let originalValue = controls.slider.value as? String else {
            throw Failure.missingControls
        }
        let originalPosition = controls.slider.normalizedSliderPosition
        attach("Original Settings text size", text: controls.description + " category=\(original.category)")
        // Registered before either global Settings control is changed.
        test.addTeardownBlock { [self] in
            do {
                settings.activate()
                try setControls(toggleValue: originalToggle, position: originalPosition)
                let restored = try readControls()
                try wait("Restore the exact original displayed slider value") { restored.slider.value as? String == originalValue }
                let restoredControls = restored.description
                let observed = try activateRetainedApp(category: original.category)
                attach("Restored Settings text size", text: restoredControls + "\n" + String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
            } catch {
                XCTFail("Could not restore original Settings text size: \(error)")
            }
        }
        try set(.large)
    }

    private func readControls(captureInventory: Bool = false) throws -> Controls {
        var snapshot = controlSnapshot()
        do {
            if snapshot.controls == nil {
                try wait("Larger Text must expose one range switch and slider with readable values") {
                    snapshot = self.controlSnapshot()
                    return snapshot.controls != nil
                }
            }
        } catch {
            attach("Larger Text control inventory", text: snapshot.details + "\n" + settings.debugDescription)
            throw error
        }
        if captureInventory {
            attach("Larger Text control inventory", text: snapshot.details + "\n" + settings.debugDescription)
        }
        guard let controls = snapshot.controls else { throw Failure.missingControls }
        return controls
    }

    private func controlSnapshot() -> (controls: Controls?, details: String) {
        // Observe both routes and both controls before deciding readiness.
        // iOS 26.5 identifies the outer Switch; iOS 18.5 identifies StaticText
        // in the containing Cell. Both expose one nested Switch actuator.
        let navigationCount = settings.navigationBars.matching(identifier: "Larger Text").count
        let navigationReady = navigationCount == 1
        let identifiedRanges = settings.switches.matching(identifier: "LARGER_DYNAMIC_TYPE_SWITCH")
        let rangeCells = settings.cells.containing(.staticText, identifier: "LARGER_DYNAMIC_TYPE_SWITCH")
        let identifiedRangeCount = identifiedRanges.count
        let rangeCellCount = rangeCells.count
        let rangeContainer: XCUIElement?
        if identifiedRangeCount == 1 {
            rangeContainer = identifiedRanges.element
        } else if identifiedRangeCount == 0 && rangeCellCount == 1 {
            rangeContainer = rangeCells.element
        } else {
            rangeContainer = nil
        }
        let rangeSwitchCount = rangeContainer.map { $0.switches.count }
        let rangeSwitch = rangeSwitchCount == 1 ? rangeContainer?.switches.element : nil
        // Preserve the proven iOS 26.5 value owner; the iOS 18.5 actuator
        // itself exposes the 0/1 value in both retained hierarchies.
        let rangeValueElement = identifiedRangeCount == 1 ? rangeContainer : rangeSwitch
        let rangeValue = Controls.readRangeValue(from: rangeValueElement)

        let sliderCells = settings.cells.matching(identifier: "DYNAMIC_TYPE_SLIDER")
        let sliderCellCount = sliderCells.count
        let identifiedSliderCount = sliderCellCount == 1 ? sliderCells.element.sliders.count : nil
        let pageSliders = settings.sliders
        let pageSliderCount = pageSliders.count
        let slider: XCUIElement?
        if sliderCellCount == 1 && identifiedSliderCount == 1 {
            slider = sliderCells.element.sliders.element
        } else if sliderCellCount == 0 && pageSliderCount == 1 {
            // The iOS 18.5 slider has no identifier. This route is valid only
            // on the proven Larger Text page with exactly one slider.
            slider = pageSliders.element
        } else {
            slider = nil
        }
        let sliderValue = slider?.value as? String
        let details = "navigationReady=\(navigationReady) navigationBars=\(navigationCount) identifiedRanges=\(identifiedRangeCount) " +
            "rangeCells=\(rangeCellCount) rangeSwitches=\(String(describing: rangeSwitchCount)) " +
            "sliderCells=\(sliderCellCount) identifiedSliders=\(String(describing: identifiedSliderCount)) " +
            "pageSliders=\(pageSliderCount) rangeValue=\(String(describing: rangeValue)) sliderValue=\(String(describing: sliderValue))"
        guard navigationReady, let rangeValueElement, let rangeSwitch, let slider,
              rangeValue == "0" || rangeValue == "1", sliderValue != nil
        else { return (nil, details) }
        return (Controls(rangeValueElement: rangeValueElement, rangeSwitch: rangeSwitch, slider: slider), details)
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
        let controls = try readControls()
        attach("Settings controls for \(size)", text: controls.description)
        let observed = try activateRetainedApp(category: size.category)
        attach("System text size \(size)", text: String(decoding: try JSONEncoder().encode(observed), as: UTF8.self))
    }

    private func setControls(toggleValue: String, position: CGFloat) throws {
        if settings.navigationBars["Display & Text Size"].exists {
            try openSettingsRow(identifier: "LARGER_TEXT", source: "Display & Text Size", destination: "Larger Text")
        }
        let controls = try readControls()
        try wait("Larger Text controls must be reachable after Settings activation") {
            controls.rangeSwitch.exists && controls.rangeSwitch.isHittable && controls.slider.exists && controls.slider.isHittable
        }
        if controls.rangeValue != toggleValue { controls.rangeSwitch.tap() }
        try wait("Settings range switch") { controls.rangeValue == toggleValue }
        // Changing the range may rebuild the slider. Re-resolve its unique
        // query and bounded readiness before the one adjustment.
        let adjusted = try readControls()
        try wait("Settings slider must be hittable after the range change") { adjusted.slider.isHittable }
        adjusted.slider.adjust(toNormalizedSliderPosition: position)
        try wait("Settings text size slider") { abs(adjusted.slider.normalizedSliderPosition - position) <= 0.001 }
    }

    private func activateRetainedApp(category: String) throws -> Metadata {
        guard app.state != .notRunning else {
            XCTFail("The app stopped during the Settings roundtrip; activation must not relaunch it")
            throw Failure.appStopped
        }
        // Complete the native Settings edit before switching apps. Leaving
        // during continuous slider updates can retain an intermediate size.
        let back = settings.navigationBars["Larger Text"].buttons["Display & Text Size"]
        try wait("Larger Text back button must be reachable") { back.exists && back.isHittable }
        back.tap()
        try wait("Settings must finish the Larger Text edit") {
            self.settings.navigationBars["Display & Text Size"].exists
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
