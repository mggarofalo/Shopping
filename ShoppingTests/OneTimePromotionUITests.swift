import XCTest

final class OneTimePromotionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPromotionCancelAndExplicitCreatePreserveOccurrenceAfterRelaunch() {
        let app = launchApp()
        createOneTime("Green tea", in: app)
        let originalID = row("Green tea", in: app).identifier
        row("Green tea", in: app).tap()
        startPromotion(in: app)
        replace(app.textFields["shopping.grocery.name"], with: "Canceled tea")
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(row("Green tea", in: app).existsOrAppears(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered items"].existsOrAppears(timeout: 2))
        app.tabBars.buttons["Groceries"].tap()
        row("Green tea", in: app).tap()
        startPromotion(in: app)
        let catalogNotes = app.textFields["shopping.grocery.catalogNotes"]
        reveal(catalogNotes, in: app)
        catalogNotes.tap()
        catalogNotes.typeText("Loose leaf")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.buttons[originalID].existsOrAppears(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[originalID].existsOrAppears(timeout: 5))
        app.buttons[originalID].tap()
        XCTAssertTrue(app.navigationBars["Edit item"].existsOrAppears(timeout: 2))
        XCTAssertEqual(app.textFields["shopping.grocery.catalogNotes"].value as? String, "Loose leaf")
        XCTAssertEqual(app.textFields["shopping.grocery.purchaseNotes"].value as? String, "Buy this week")
        let quantity = quantityControls(in: app).value
        XCTAssertEqual(quantity.value as? String, "2")
        XCTAssertEqual(app.switches["shopping.grocery.urgency"].value as? String, "1")
        screenshot("Explicitly remembered grocery", app: app)
        app.buttons["shopping.grocery.cancel"].tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["Green tea"].existsOrAppears(timeout: 3))
        XCTAssertFalse(app.staticTexts["Canceled tea"].exists)
    }

    func testLinkExistingUsesSavedRulesWithoutOverwritingCatalog() {
        let app = launchApp(fixture: "promotionLinkExisting")
        XCTAssertTrue(row("Breakfast cereal", in: app).existsOrAppears(timeout: 3))
        let originalID = row("Breakfast cereal", in: app).identifier
        row("Breakfast cereal", in: app).tap()
        startPromotion(in: app)
        chooseExisting("Granola", in: app)
        app.buttons["shopping.grocery.save"].tap()
        let original = app.buttons[originalID]
        reveal(original, in: app)
        XCTAssertTrue(original.label.contains("Granola"))
        original.tap()
        XCTAssertTrue(app.navigationBars["Edit item"].existsOrAppears(timeout: 2))
        let purchaseNotes = app.textFields["shopping.grocery.purchaseNotes"]
        reveal(purchaseNotes, in: app)
        XCTAssertEqual(purchaseNotes.value as? String, "Buy this week")
        let quantity = quantityControls(in: app).value
        XCTAssertEqual(quantity.value as? String, "2")
        let urgency = app.switches["shopping.grocery.urgency"]
        reveal(urgency, in: app)
        XCTAssertEqual(urgency.value as? String, "1")
        let anyStore = app.buttons["shopping.purchase.anyStore"]
        reveal(anyStore, in: app)
        XCTAssertEqual(anyStore.value as? String, "Not selected")
        let costco = purchaseStorePill(named: "Costco", app: app)
        reveal(costco, in: app)
        XCTAssertEqual(costco.value as? String, "Selected")
        app.buttons["shopping.grocery.cancel"].tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 3))
        XCTAssertTrue(app.staticTexts["Granola"].existsOrAppears(timeout: 3))
        XCTAssertFalse(app.staticTexts["Breakfast cereal"].exists)
        // Additive diagnostic after every original promotion/preservation assertion.
        runNativeSystemResizeIfEnabled(originalApp: app)
    }

    func testCollisionAndActiveConflictRequireExplicitDistinctChoice() {
        let app = launchApp(fixture: "promotionConflict")
        let oneTime = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND value CONTAINS[c] %@",
                "shopping.grocery.row.", "Granola", "One-time"
            )
        ).firstMatch
        reveal(oneTime, in: app)
        let originalID = oneTime.identifier
        oneTime.tap()
        startPromotion(in: app)
        app.buttons["shopping.grocery.save"].tap()
        let collision = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "shopping.grocery.promotion.collision."
            )
        ).firstMatch
        reveal(collision, in: app)
        collision.tap()
        app.buttons["shopping.grocery.save"].tap()
        let conflict = app.buttons["shopping.grocery.promotion.viewConflict"]
        reveal(conflict, in: app)
        XCTAssertTrue(conflict.exists)
        app.buttons["shopping.grocery.cancel"].tap()
        XCTAssertTrue(app.buttons[originalID].existsOrAppears(timeout: 3))
        XCTAssertTrue(
            (app.buttons[originalID].value as? String ?? "").localizedCaseInsensitiveContains("One-time"))
        app.buttons[originalID].tap()
        startPromotion(in: app)
        app.buttons["shopping.grocery.save"].tap()
        let distinct = app.buttons["shopping.grocery.createDistinct"]
        reveal(distinct, in: app)
        distinct.tap()
        XCTAssertTrue(app.buttons[originalID].existsOrAppears(timeout: 3))
        XCTAssertFalse(
            (app.buttons[originalID].value as? String ?? "").localizedCaseInsensitiveContains("One-time"))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    "shopping.grocery.row.", "Granola"
                )
            ).count, 2)
    }

    private func launchApp(fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingPromotionUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].existsOrAppears(timeout: 5))
        app.launchEnvironment.removeValue(forKey: "SHOPPING_UI_TEST_FIXTURE")
        return app
    }

    private func createOneTime(_ name: String, in app: XCUIApplication) {
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 2))
        let addOneTime = app.buttons["shopping.grocery.addOneTime"]
        reveal(addOneTime, in: app)
        XCTAssertTrue(addOneTime.existsOrAppears(timeout: 2))
        addOneTime.tap()
        XCTAssertTrue(app.navigationBars["Add item"].existsOrAppears(timeout: 2))
        let remembered = app.switches["shopping.grocery.remembered"]
        setSwitch(remembered, on: false, in: app)
        let field = app.textFields["shopping.grocery.name"]
        field.tap()
        field.typeText(name)
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        let quantity = quantityControls(in: app)
        quantity.increment.tap()
        XCTAssertEqual(quantity.value.value as? String, "2")
        setSwitch(app.switches["shopping.grocery.urgency"], on: true, in: app)
        setPill(app.buttons["shopping.purchase.anyStore"], selected: true, in: app)
        let notes = app.textFields["shopping.grocery.purchaseNotes"]
        for _ in 0..<10 where !notes.exists { app.swipeDown() }
        reveal(notes, in: app)
        notes.tap()
        notes.typeText("Buy this week")
        app.buttons["shopping.grocery.save"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 3))
        reveal(row(name, in: app), in: app)
    }

    private func startPromotion(in app: XCUIApplication) {
        let start = app.buttons["shopping.grocery.promotion.start"]
        reveal(start, in: app)
        start.tap()
        XCTAssertTrue(app.segmentedControls["shopping.grocery.promotion.choice"].existsOrAppears(timeout: 2))
    }

    private func chooseExisting(_ name: String, in app: XCUIApplication) {
        app.segmentedControls["shopping.grocery.promotion.choice"].buttons["Use existing"].tap()
        let search = app.textFields["shopping.grocery.promotion.search"]
        reveal(search, in: app)
        search.tap()
        search.typeText(name)
        search.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        let match = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.grocery.promotion.item.", name
            )
        ).firstMatch
        reveal(match, in: app)
        match.tap()
    }

    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "shopping.grocery.row.", name
            )
        ).firstMatch
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func setSwitch(_ element: XCUIElement, on: Bool, in app: XCUIApplication) {
        reveal(element, in: app)
        if (element.value as? String == "1") != on {
            let inner = element.switches.firstMatch
            (inner.exists ? inner : element).tap()
        }
        XCTAssertEqual(element.value as? String, on ? "1" : "0")
    }

    private func setPill(_ pill: XCUIElement, selected: Bool, in app: XCUIApplication) {
        reveal(pill, in: app)
        if (pill.value as? String == "Selected") != selected { pill.tap() }
        XCTAssertEqual(pill.value as? String, selected ? "Selected" : "Not selected")
    }

    private func purchaseStorePill(named name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "shopping.purchase.store.", name
        )).firstMatch
    }

    private func quantityControls(in app: XCUIApplication) -> (value: XCUIElement, increment: XCUIElement) {
        let quantity = app.steppers["shopping.grocery.quantity"]
        if !quantity.exists {
            let addQuantity = app.buttons["shopping.grocery.quantity.add"]
            reveal(addQuantity, in: app)
            XCTAssertTrue(addQuantity.isHittable)
            addQuantity.tap()
            XCTAssertTrue(quantity.existsOrAppears(timeout: 2))
        }
        let increments = quantity.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "shopping.grocery.quantity-Increment", "Increment"
        ))
        // iOS 18 exposes the Stepper's actionable children as hittable, while
        // the fully visible value container itself is not a tap target.
        let increment = increments.firstMatch
        reveal(increment, in: app)
        XCTAssertEqual(increments.count, 1)
        XCTAssertTrue(quantity.exists)
        return (quantity, increment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            let appFrame = app.frame
            let navigationBar = app.navigationBars.firstMatch
            let navigationFrame = navigationBar.frame
            guard usable(appFrame), usable(navigationFrame) else { continue }
            let targetIsInNavigationBar = contains(element, in: navigationBar)
            let fixedScope = app.otherElements["shopping.grocery.fixedScope"]
            let targetIsInFixedScope = contains(element, in: fixedScope)
            let fixedScopeFrame = fixedScope.exists && fixedScope.isHittable
                && !targetIsInNavigationBar && !targetIsInFixedScope ? fixedScope.frame : nil
            if let fixedScopeFrame, !usable(fixedScopeFrame) { continue }
            let contentTop = max(navigationFrame.maxY, fixedScopeFrame?.maxY ?? navigationFrame.maxY)
            let top = targetIsInNavigationBar ? appFrame.minY : contentTop
            let keyboard = app.keyboards.firstMatch
            let keyboardFrame = keyboard.exists ? keyboard.frame : nil
            if let keyboardFrame, !usable(keyboardFrame) { continue }
            let tabBar = app.tabBars.firstMatch
            let tabBarFrame = tabBar.exists && tabBar.isHittable ? tabBar.frame : nil
            if let tabBarFrame, !usable(tabBarFrame) { continue }
            let lowerSystemBound = keyboardFrame.map { $0.minY - 60 }
                ?? tabBarFrame.map(\.minY) ?? appFrame.maxY
            let feedback = app.otherElements["shopping.grocery.feedback"]
            let targetIsInFeedback = contains(element, in: feedback)
            let feedbackFrame = feedback.exists && feedback.isHittable && !targetIsInFeedback
                ? feedback.frame : nil
            if let feedbackFrame, !usable(feedbackFrame) { continue }
            let bottom = min(lowerSystemBound, feedbackFrame?.minY ?? lowerSystemBound)
            guard bottom - top > 48 else { continue }
            let elementFrame = element.exists ? element.frame : nil
            if let elementFrame, !usable(elementFrame) { continue }
            if let elementFrame, element.isHittable && elementFrame.minY >= top
                && elementFrame.maxY <= bottom
            {
                return
            }
            let x = appFrame.midX
            let viewportHeight = bottom - top
            let upper = top + viewportHeight / 4
            let lower = top + viewportHeight * 3 / 4
            let maximumTravel = lower - upper
            let minimumTravel = min(60, maximumTravel)
            if let elementFrame, elementFrame.minY < top {
                let travel = min(max(top - elementFrame.minY + 12, minimumTravel), maximumTravel)
                drag(in: app, x: x, from: upper, to: upper + travel)
            } else if let elementFrame, elementFrame.maxY > bottom {
                let travel = min(max(elementFrame.maxY - bottom + 12, minimumTravel), maximumTravel)
                drag(in: app, x: x, from: lower, to: lower - travel)
            } else {
                drag(in: app, x: x, from: lower, to: upper)
            }
        }
        XCTFail("Could not reveal \(element.identifier) above the keyboard and tab bar")
        XCTAssertTrue(element.existsOrAppears(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func contains(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        guard element.exists, usable(element.frame), container.exists else { return false }
        return container.descendants(matching: element.elementType).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", element.identifier, element.label
        )).firstMatch.exists
    }

    private func drag(in app: XCUIApplication, x: CGFloat, from startY: CGFloat, to endY: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: startY))
        let end = origin.withOffset(CGVector(dx: x, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty
            && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    // Temporary SHOPPING-131 diagnostic; append inside OneTimePromotionUITests.
    // Original promotion assertions finish before this method is called.
    private func runNativeSystemResizeIfEnabled(originalApp: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        guard let nonce = environment["SHOPPING_NATIVE_RESIZE_NONCE"],
              let originalCategory = environment["SHOPPING_NATIVE_RESIZE_ORIGINAL"] else { return }
        let previousContinue = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = previousContinue }
        let manager = FileManager.default
        let channel = manager.temporaryDirectory.appendingPathComponent("shopping-native-system-resize-\(nonce)")
        let app = XCUIApplication()
        let deep = app.staticTexts["native.audit.list.deep"]
        let deepCopy = "Saved work remains on this device."
        var samples: [[String: Any]] = []
        var failures: [String] = []

        struct ProbeFailure: Error, CustomStringConvertible {
            let description: String
        }
        func write(_ value: [String: Any], to name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: channel.appendingPathComponent(name), options: .atomic)
        }
        func wait(_ description: String, timeout: TimeInterval = 10, condition: @escaping () -> Bool) throws {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
                throw ProbeFailure(description: description)
            }
        }
        func phase(_ sequence: Int, category: String) throws {
            let stem = "native-list-\(sequence)"
            try write(["version": 1, "nonce": nonce, "probe": "native-list", "sequence": sequence,
                       "category": category], to: stem + ".request.json")
            let response = channel.appendingPathComponent(stem + ".response.json")
            try wait("No matching host readback for \(category)", timeout: 15) {
                guard let data = try? Data(contentsOf: response),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return result["version"] as? Int == 1 && result["nonce"] as? String == nonce
                    && result["probe"] as? String == "native-list" && result["sequence"] as? Int == sequence
                    && result["observed"] as? String == category && result["success"] as? Bool == true
            }
        }
        func viewport() -> CGRect { app.frame.insetBy(dx: 0, dy: 80) }
        func frameJSON(_ frame: CGRect) -> [String: Any] {
            func number(_ value: CGFloat) -> Any { value.isFinite ? value as Any : NSNull() }
            return ["x": number(frame.minX), "y": number(frame.minY),
                    "width": number(frame.width), "height": number(frame.height)]
        }
        func visibleTexts(in visibleViewport: CGRect) -> [XCUIElement] {
            app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "native.audit.list."))
                .allElementsBoundByIndex.filter { element in
                    element.exists && element.isHittable && element.frame.intersects(visibleViewport)
                }
        }
        func capture(_ phase: String) {
            let visibleViewport = viewport()
            let visible = visibleTexts(in: visibleViewport)
            var sample: [String: Any] = ["phase": phase, "foreground": app.state == .runningForeground,
                "visibleNativeTexts": visible.map { ["id": $0.identifier, "label": $0.label, "frame": frameJSON($0.frame)] },
                "deepExists": deep.exists, "deepFullyVisible": deep.exists && deep.isHittable && visibleViewport.contains(deep.frame)]
            if deep.exists { sample["deepFrame"] = frameJSON(deep.frame); sample["deepLabel"] = deep.label }
            samples.append(sample)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Native system resize \(phase)"
            image.lifetime = .keepAlways
            self.add(image)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Native system resize \(phase) hierarchy"
            hierarchy.lifetime = .keepAlways
            self.add(hierarchy)
        }
        func settleVisibleContent() throws {
            let visibleViewport = viewport()
            var anchor: XCUIElement?
            var prior: CGRect?
            try wait("No stable reachable native text after the system size change", timeout: 8) {
                guard app.state == .runningForeground else { prior = nil; return false }
                if let current = anchor {
                    guard current.exists, current.isHittable else { anchor = nil; prior = nil; return false }
                    let frame = current.frame
                    guard frame.intersects(visibleViewport) else { anchor = nil; prior = nil; return false }
                    defer { prior = frame }
                    return frame == prior
                }
                // Select one actually visible native label, then re-query its stable ID.
                // Full-list evidence remains in capture; repeating it inside this
                // eight-second waiter exhausted the pinned runner's query budget.
                let candidates = app.staticTexts.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "native.audit.list.")
                ).allElementsBoundByIndex
                for candidate in candidates {
                    guard candidate.exists, candidate.isHittable else { continue }
                    let frame = candidate.frame
                    guard frame.intersects(visibleViewport) else { continue }
                    anchor = app.staticTexts[candidate.identifier]
                    prior = frame
                    return false
                }
                prior = nil
                return false
            }
        }
        func revealDeep() throws {
            for _ in 0..<20 {
                guard app.state == .runningForeground else { throw ProbeFailure(description: "Control left foreground") }
                if deep.exists && deep.isHittable && viewport().contains(deep.frame) { return }
                let footer = app.staticTexts["native.audit.list.footer"]
                if (deep.exists && deep.frame.minY < viewport().minY) || (!deep.exists && footer.isHittable) {
                    app.swipeDown()
                } else {
                    app.swipeUp()
                }
            }
            throw ProbeFailure(description: "Deep native text was not fully reachable within the scroll bound")
        }
        func stableDeepFrame(satisfying: @escaping (CGRect) -> Bool) throws -> CGRect {
            var previous: CGRect?
            var result = CGRect.zero
            try wait("Expected stable deep-label frame was not observed", timeout: 8) {
                guard app.state == .runningForeground, deep.exists, deep.isHittable,
                      deep.label == deepCopy, viewport().contains(deep.frame), satisfying(deep.frame) else { return false }
                result = deep.frame
                defer { previous = result }
                return previous == result
            }
            return result
        }
        func recordFailure(_ error: Error, phase: String) {
            let description = "\(phase): \(error)"
            failures.append(description)
            XCTFail("Native system-resize diagnostic failed: \(description)")
            if app.state == .runningForeground { capture(phase + " failure") }
        }

        do {
            try manager.createDirectory(at: channel, withIntermediateDirectories: true)
            originalApp.terminate()
            try phase(1, category: "large")
            let marker = UUID().uuidString
            app.launchEnvironment = [
                "SHOPPING_UI_TEST_NATIVE_AUDIT_CONTROL": "list",
                "SHOPPING_UI_TEST_NATIVE_AUDIT_NONCE": marker,
                "SHOPPING_UI_TEST_STORE_PATH": manager.temporaryDirectory.appendingPathComponent("NativeAudit-\(marker).sqlite").path
            ]
            // Crucial: NO fixed content-size launch argument; host changes actual system preference.
            app.launchArguments = []
            app.launch()
            let headline = app.staticTexts["native.audit.list.headline"]
            guard headline.existsOrAppears(timeout: 5) else { throw ProbeFailure(description: "Exact native List did not launch") }
            try settleVisibleContent()
            try revealDeep()
            let baseline = try stableDeepFrame { $0.width > 0 && $0.height > 0 }
            capture("large baseline deep")
            for (sequence, category) in [(2, "accessibility-extra-extra-extra-large"), (3, "large")] {
                do {
                    try phase(sequence, category: category)
                    // Preserve raw viewport behavior before any attempt to recover/reveal the target.
                    capture("\(category) immediately after readback before scrolling")
                    try settleVisibleContent()
                    capture("\(category) settled before scrolling")
                    try revealDeep()
                    _ = try stableDeepFrame { frame in
                        sequence == 2 ? frame.height > baseline.height + 1
                            : abs(frame.height - baseline.height) <= 1 && abs(frame.width - baseline.width) <= 1
                    }
                    capture("\(category) deep reachable")
                } catch {
                    recordFailure(error, phase: category)
                    // Still attempt large restoration; later recovery never erases this failure.
                }
            }
        } catch {
            recordFailure(error, phase: "setup")
        }
        do { try phase(4, category: originalCategory) } catch { recordFailure(error, phase: "original setting restoration") }
        app.terminate()
        let evidence: [String: Any] = ["version": 1, "nonce": nonce, "probe": "native-list",
                                      "success": failures.isEmpty, "failures": failures, "samples": samples]
        do {
            try write(evidence, to: "native-list.done.json")
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Native system-resize complete evidence"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        } catch {
            XCTFail("Could not persist native system-resize evidence: \(error)")
            // Missing completion is independently a controller failure.
        }
    }

}
