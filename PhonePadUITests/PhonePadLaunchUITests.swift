import XCTest

final class PhonePadLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecoveryRequiresExplicitUserActionAcrossFreshLaunches() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))

        let tabs = app.descendants(matching: .any).matching(identifier: "phonepad.tab.item")
        XCTAssertEqual(tabs.count, 1)
        let activeTab = tabs.firstMatch
        XCTAssertEqual(activeTab.label, "Untitled")

        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let privatePhrase = "Private recovery \(UUID().uuidString)"
        editor.typeText(privatePhrase)

        XCTAssertEqual(editor.value as? String, privatePhrase)
        XCTAssertTrue(waitForValue(activeTab, value: "Edits protected", timeout: 5))
        app.terminate()

        app.launch()
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.element(boundBy: 0).label, "Untitled")
        XCTAssertEqual(editor.value as? String, "")

        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(actionMenu, value: "1 preserved work items", timeout: 5)
        )

        actionMenu.tap()
        let recoveryMenuItem = app.buttons["phonepad.action-menu.document-recovery"]
        XCTAssertTrue(recoveryMenuItem.waitForExistence(timeout: 2))
        recoveryMenuItem.tap()

        let recoverySheet = app.descendants(matching: .any)["phonepad.recovery.sheet"]
            .firstMatch
        XCTAssertTrue(recoverySheet.waitForExistence(timeout: 5))
        let recoveryRows = recoverySheet.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "phonepad.recovery.item.")
        )
        XCTAssertEqual(recoveryRows.count, 1)
        let sheetText = recoverySheet.staticTexts.allElementsBoundByIndex
            .flatMap { [$0.label, $0.value as? String ?? ""] }
            .joined(separator: " ")
        XCTAssertFalse(sheetText.contains(privatePhrase))

        let recoverButtons = recoverySheet.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "phonepad.recovery.recover.")
        )
        XCTAssertEqual(recoverButtons.count, 1)
        recoverButtons.element(boundBy: 0).tap()

        XCTAssertTrue(waitForCount(tabs, count: 2, timeout: 5))
        XCTAssertFalse(recoverySheet.exists)
        XCTAssertEqual(editor.value as? String, privatePhrase)
    }

    @MainActor
    func testDiscardRequiresStableExplicitConfirmationAndRemovesRecovery() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let tabs = app.descendants(matching: .any).matching(identifier: "phonepad.tab.item")
        XCTAssertEqual(tabs.count, 1)
        let activeTab = tabs.firstMatch
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Discard after explicit confirmation")
        XCTAssertTrue(waitForValue(activeTab, value: "Edits protected", timeout: 5))
        app.terminate()

        app.launch()
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(actionMenu, value: "1 preserved work items", timeout: 5)
        )
        actionMenu.tap()
        let recoveryMenuItem = app.buttons["phonepad.action-menu.document-recovery"]
        XCTAssertTrue(recoveryMenuItem.waitForExistence(timeout: 2))
        recoveryMenuItem.tap()

        let recoverySheet = app.descendants(matching: .any)["phonepad.recovery.sheet"]
            .firstMatch
        XCTAssertTrue(recoverySheet.waitForExistence(timeout: 5))
        let recoveryRows = recoverySheet.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "phonepad.recovery.item.")
        )
        XCTAssertEqual(recoveryRows.count, 1)
        let discardButtons = recoverySheet.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "phonepad.recovery.discard.")
        )
        XCTAssertEqual(discardButtons.count, 1)
        discardButtons.firstMatch.tap()

        let cancelButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "phonepad.recovery.discard-cancel."
            )
        )
        XCTAssertEqual(cancelButtons.count, 1)
        cancelButtons.firstMatch.tap()
        XCTAssertTrue(recoverySheet.waitForExistence(timeout: 2))
        XCTAssertEqual(recoveryRows.count, 1)

        discardButtons.firstMatch.tap()
        let confirmButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "phonepad.recovery.discard-confirm."
            )
        )
        XCTAssertEqual(confirmButtons.count, 1)
        confirmButtons.firstMatch.tap()

        XCTAssertTrue(waitForCount(recoveryRows, count: 0, timeout: 5))
        let doneButton = recoverySheet.buttons["phonepad.recovery.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 2))
        doneButton.tap()
        XCTAssertFalse(recoverySheet.exists)
        XCTAssertTrue(
            waitForValue(actionMenu, value: "No preserved work", timeout: 5)
        )
    }

    @MainActor
    private func waitForCount(
        _ query: XCUIElementQuery,
        count: Int,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "count == %d", count)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: query)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForValue(
        _ element: XCUIElement,
        value: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

}
