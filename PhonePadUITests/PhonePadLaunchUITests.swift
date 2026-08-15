import UIKit
import XCTest

final class PhonePadLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testActionMenuExposesNativeEditingCommands() {
        let app = launchPhonePad()

        let actionMenu = app.descendants(matching: .any)[
            "phonepad.action-menu"
        ].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.tap()

        let editingMenu = app.buttons["phonepad.edit.menu"]
        XCTAssertTrue(editingMenu.waitForExistence(timeout: 2))
        editingMenu.tap()

        for identifier in [
            "phonepad.edit.undo",
            "phonepad.edit.redo",
            "phonepad.edit.cut",
            "phonepad.edit.copy",
            "phonepad.edit.paste",
            "phonepad.edit.delete",
            "phonepad.edit.select-all",
        ] {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: 2),
                "Missing explicit editor command: \(identifier)"
            )
        }
    }

    @MainActor
    func testPrivacySheetExplainsPasteboardAndPrintBoundaries() {
        let app = launchPhonePad()

        let actionMenu = app.descendants(matching: .any)[
            "phonepad.action-menu"
        ].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.tap()

        let privacy = app.buttons["phonepad.action-menu.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 2))
        privacy.tap()

        let sheet = app.descendants(matching: .any)[
            "phonepad.privacy.sheet"
        ].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(
            sheet.staticTexts["phonepad.privacy.pasteboard"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            sheet.staticTexts["phonepad.privacy.print"]
                .waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testExternalOpenHostPublishesRealFileFixtures() throws {
        let host = launchExternalOpenHost()

        XCTAssertTrue(
            host.staticTexts["externalopenhost.ready"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(host.staticTexts["externalopenhost.error"].exists)

        let durable = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.durable.url",
            contentIdentifier: "externalopenhost.fixture.durable.content"
        )
        let readOnly = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.readonly.url",
            contentIdentifier: "externalopenhost.fixture.readonly.content"
        )
        let generic = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.generic.url",
            contentIdentifier: "externalopenhost.fixture.generic.content"
        )

        XCTAssertEqual(durable.url.pathExtension, "txt")
        XCTAssertEqual(durable.content, "Durable external open\n")
        XCTAssertEqual(readOnly.url.pathExtension, "txt")
        XCTAssertEqual(readOnly.content, "Read-only external open\n")
        XCTAssertEqual(generic.url.pathExtension, "dat")
        XCTAssertEqual(generic.content, "Generic data external open\n")
    }

    @MainActor
    func testColdExternalOpenCopyRequiredDurableFileRequiresSaveAs() throws {
        let host = launchExternalOpenHost()
        let fixture = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.durable.url",
            contentIdentifier: "externalopenhost.fixture.durable.content"
        )

        let app = openPhonePadCold(with: fixture.url)

        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.root"]
                .waitForExistence(timeout: 5)
        )
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(editor, value: fixture.content, timeout: 20))
        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.external-open.notice"]
                .firstMatch
                .waitForExistence(timeout: 20)
        )
        let tabs = tabItems(in: app)
        XCTAssertTrue(waitForCount(tabs, count: 1, timeout: 10))
        XCTAssertEqual(tabs.firstMatch.label, "durable.txt")

        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"]
            .firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 2))
        actionMenu.tap()
        let save = app.buttons["phonepad.action-menu.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.save-as.sheet"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testColdExternalOpenReadOnlyFileRequiresSaveAs() throws {
        let host = launchExternalOpenHost()
        let fixture = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.readonly.url",
            contentIdentifier: "externalopenhost.fixture.readonly.content"
        )

        let app = openPhonePadCold(with: fixture.url)

        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.root"]
                .waitForExistence(timeout: 5)
        )
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(editor, value: fixture.content, timeout: 10))
        let tabs = tabItems(in: app)
        XCTAssertTrue(waitForCount(tabs, count: 1, timeout: 10))
        XCTAssertEqual(tabs.firstMatch.label, "read-only.txt")

        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"]
            .firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 2))
        actionMenu.tap()
        let save = app.buttons["phonepad.action-menu.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.save-as.sheet"]
                .firstMatch
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testColdExternalOpenAcceptsGenericDataFixture() throws {
        let host = launchExternalOpenHost()
        let fixture = try externalOpenFixture(
            in: host,
            urlIdentifier: "externalopenhost.fixture.generic.url",
            contentIdentifier: "externalopenhost.fixture.generic.content"
        )

        let app = openPhonePadCold(with: fixture.url)

        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.root"]
                .waitForExistence(timeout: 5)
        )
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(editor, value: fixture.content, timeout: 10))
        let tabs = tabItems(in: app)
        XCTAssertTrue(waitForCount(tabs, count: 1, timeout: 10))
        XCTAssertEqual(tabs.firstMatch.label, "generic.dat")
    }

    @MainActor
    func testFileConflictUsesStableExplicitResolutionIdentifiers() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["PHONEPAD_UI_TEST_FILE_CONFLICT"] = "1"
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let conflictSheet = app.descendants(matching: .any)[
            "phonepad.file-conflict.sheet"
        ].firstMatch
        XCTAssertTrue(conflictSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["phonepad.file-conflict.reason"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.buttons["phonepad.file-conflict.reload-current"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.buttons["phonepad.file-conflict.save-as"]
                .waitForExistence(timeout: 2)
        )
        let cancel = app.buttons["phonepad.file-conflict.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))

        cancel.tap()

        XCTAssertFalse(conflictSheet.exists)
        XCTAssertTrue(
            app.staticTexts["phonepad.file-conflict.banner"]
                .waitForExistence(timeout: 5)
        )
        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"]
            .firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 2))
        actionMenu.tap()
        let save = app.buttons["phonepad.action-menu.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        save.tap()

        XCTAssertTrue(conflictSheet.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLongFileTitleKeepsTabDragControlReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["PHONEPAD_UI_TEST_FILE_CONFLICT"] = "1"
        app.launch()

        let conflictSheet = app.descendants(matching: .any)[
            "phonepad.file-conflict.sheet"
        ].firstMatch
        XCTAssertTrue(conflictSheet.waitForExistence(timeout: 10))
        let cancel = app.buttons["phonepad.file-conflict.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertFalse(conflictSheet.exists)

        let tabs = tabItems(in: app)
        XCTAssertEqual(tabs.count, 1)
        let tab = tabs.element(boundBy: 0)
        XCTAssertGreaterThan(tab.label.count, 100)
        let tabSuffix = String(
            tab.identifier.dropFirst("phonepad.tab.item.".count)
        )
        let select = app.buttons["phonepad.tab.select.\(tabSuffix)"]
        let drag = app.descendants(matching: .any)[
            "phonepad.tab.drag.\(tabSuffix)"
        ].firstMatch
        XCTAssertTrue(waitForHittable(select, timeout: 5))
        XCTAssertTrue(waitForHittable(drag, timeout: 5))
        XCTAssertLessThanOrEqual(select.frame.width, 220.01)
    }

    @MainActor
    func testRecoveryRequiresExplicitUserActionAcrossFreshLaunches() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))

        let tabs = tabItems(in: app)
        XCTAssertEqual(tabs.count, 1)
        let activeTab = tabs.firstMatch
        XCTAssertEqual(activeTab.label, "Untitled")

        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let privatePhrase = "Private recovery \(UUID().uuidString)"
        editor.typeText(privatePhrase)

        XCTAssertEqual(editor.value as? String, privatePhrase)
        XCTAssertTrue(waitForValue(activeTab, value: "Edits protected", timeout: 10))
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
        let tabs = tabItems(in: app)
        XCTAssertEqual(tabs.count, 1)
        let activeTab = tabs.firstMatch
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Discard after explicit confirmation")
        XCTAssertTrue(waitForValue(activeTab, value: "Edits protected", timeout: 10))
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
    func testSaveAsValidatesConfigurationBeforeOpeningFolderPicker() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.tap()

        let saveButton = app.buttons["phonepad.action-menu.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 2))
        saveButton.tap()

        let saveAsSheet = app.descendants(matching: .any)["phonepad.save-as.sheet"]
            .firstMatch
        XCTAssertTrue(saveAsSheet.waitForExistence(timeout: 5))
        let fileNameField = app.textFields["phonepad.save-as.filename"]
        XCTAssertTrue(fileNameField.waitForExistence(timeout: 2))
        let encodingPicker = app.descendants(matching: .any)["phonepad.save-as.encoding"]
            .firstMatch
        XCTAssertTrue(encodingPicker.waitForExistence(timeout: 2))
        encodingPicker.tap()
        let encodingIdentifiers = [
            "phonepad.save-as.encoding.utf8",
            "phonepad.save-as.encoding.utf8-with-bom",
            "phonepad.save-as.encoding.utf16-little-endian-with-bom",
            "phonepad.save-as.encoding.utf16-big-endian-with-bom",
            "phonepad.save-as.encoding.windows-1252",
            "phonepad.save-as.encoding.iso-8859-1",
        ]
        for identifier in encodingIdentifiers {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].firstMatch
                    .waitForExistence(timeout: 2)
            )
        }
        app.descendants(matching: .any)["phonepad.save-as.encoding.utf8"]
            .firstMatch
            .tap()
        fileNameField.tap()
        fileNameField.typeText("/")

        let chooseFolderButton = app.buttons["phonepad.save-as.choose-folder"]
        XCTAssertTrue(chooseFolderButton.waitForExistence(timeout: 2))
        chooseFolderButton.tap()

        let validationError = app.staticTexts["phonepad.save-as.validation-error"]
        XCTAssertTrue(validationError.waitForExistence(timeout: 2))
        XCTAssertTrue(saveAsSheet.exists)

        let cancelButton = app.buttons["phonepad.save-as.configuration-cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.tap()
        XCTAssertFalse(saveAsSheet.exists)
    }

    @MainActor
    func testExplicitSaveAsUsesStableConfigurationAndFolderPickerIdentifiers() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.tap()

        let saveAsAction = app.buttons["phonepad.action-menu.save-as"]
        XCTAssertTrue(saveAsAction.waitForExistence(timeout: 2))
        saveAsAction.tap()

        let saveAsSheet = app.descendants(matching: .any)["phonepad.save-as.sheet"]
            .firstMatch
        XCTAssertTrue(saveAsSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.textFields["phonepad.save-as.filename"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["phonepad.save-as.encoding"]
                .firstMatch
                .waitForExistence(timeout: 2)
        )
        let chooseFolder = app.buttons["phonepad.save-as.choose-folder"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 2))
        chooseFolder.tap()

        let folderPicker = app.descendants(matching: .any)[
            "phonepad.save-as.folder-picker"
        ].firstMatch
        XCTAssertTrue(folderPicker.waitForExistence(timeout: 5))
    }

    @MainActor
    func testOpenActionPresentsNativeFilePickerWithoutChangingDocument() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let protectedText = "Keep this text while choosing a File"
        editor.typeText(protectedText)
        XCTAssertEqual(editor.value as? String, protectedText)

        let actionMenu = app.descendants(matching: .any)["phonepad.action-menu"].firstMatch
        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        actionMenu.tap()
        let openButton = app.buttons["phonepad.action-menu.open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 2))
        openButton.tap()

        let picker = app.descendants(matching: .any)["phonepad.open.picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, protectedText)
    }

    @MainActor
    func testGoToLineMovesRealEditorSelectionAndUpdatesStatus() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("first\nsecond\nthird")

        let editorMenu = app.descendants(matching: .any)["phonepad.editor.menu"]
            .firstMatch
        XCTAssertTrue(editorMenu.waitForExistence(timeout: 2))
        editorMenu.tap()
        let goToLine = app.buttons["phonepad.editor.go-to-line"]
        XCTAssertTrue(goToLine.waitForExistence(timeout: 2))
        goToLine.tap()

        let input = app.textFields["phonepad.go-to-line.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("3")
        let confirm = app.buttons["phonepad.go-to-line.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()

        let position = app.staticTexts["phonepad.status.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, "Ln 3, Col 1")
    }

    @MainActor
    func testRecoveryUnavailableBannerKeepsTextSelectableAndOffersSafeActions() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_FAILURE"] = "1"
        app.launch()

        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("U")

        let banner = app.descendants(matching: .any)[
            "phonepad.recovery-unavailable"
        ].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "U")
        XCTAssertTrue(editor.isEnabled)

        let message = app.staticTexts[
            "phonepad.recovery-unavailable.message"
        ]
        XCTAssertTrue(message.label.contains("no verified checkpoint"))
        XCTAssertTrue(
            app.buttons["phonepad.recovery-unavailable.retry"].exists
        )
        XCTAssertFalse(
            app.buttons["phonepad.recovery-unavailable.save"].isEnabled
        )
        XCTAssertTrue(
            app.buttons["phonepad.recovery-unavailable.save-as"].isEnabled
        )

        app.buttons["phonepad.recovery-unavailable.retry"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 3))

        app.buttons["phonepad.recovery-unavailable.discard"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "")
    }

    @MainActor
    func testMultipleTabsSelectAndReorderUsingStableIdentifiers() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let newTab = app.buttons["phonepad.toolbar.new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let tabs = tabItems(in: app)
        XCTAssertEqual(tabs.count, 1)

        editor.tap()
        editor.typeText("First Tab State")
        newTab.tap()
        XCTAssertTrue(waitForCount(tabs, count: 2, timeout: 5))

        editor.tap()
        editor.typeText("Second Tab State")
        newTab.tap()
        XCTAssertTrue(waitForCount(tabs, count: 3, timeout: 5))

        editor.tap()
        editor.typeText("Third Tab State")

        let initialIdentifiers = tabs.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(initialIdentifiers.count, 3)
        XCTAssertEqual(Set(initialIdentifiers).count, 3)
        for identifier in initialIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("phonepad.tab.item."))
        }

        let firstSuffix = String(
            initialIdentifiers[0].dropFirst("phonepad.tab.item.".count)
        )
        let secondSuffix = String(
            initialIdentifiers[1].dropFirst("phonepad.tab.item.".count)
        )
        let thirdSuffix = String(
            initialIdentifiers[2].dropFirst("phonepad.tab.item.".count)
        )
        let firstSelect = app.buttons["phonepad.tab.select.\(firstSuffix)"]
        let tabStrip = app.scrollViews["phonepad.tab-strip"]
        XCTAssertTrue(tabStrip.waitForExistence(timeout: 2))

        let secondDrag = app.descendants(matching: .any)[
            "phonepad.tab.drag.\(secondSuffix)"
        ].firstMatch
        let thirdDrag = app.descendants(matching: .any)[
            "phonepad.tab.drag.\(thirdSuffix)"
        ].firstMatch
        XCTAssertTrue(secondDrag.waitForExistence(timeout: 2))
        XCTAssertTrue(thirdDrag.waitForExistence(timeout: 2))
        tabStrip.swipeLeft()
        XCTAssertTrue(waitForHittable(secondDrag, timeout: 5))
        XCTAssertTrue(waitForHittable(thirdDrag, timeout: 5))
        XCTAssertTrue(secondDrag.isEnabled)
        XCTAssertTrue(thirdDrag.isEnabled)
        XCTAssertLessThan(secondDrag.frame.midX, thirdDrag.frame.midX)
        secondDrag.press(
            forDuration: 1,
            thenDragTo: thirdDrag,
            withVelocity: .slow,
            thenHoldForDuration: 1
        )

        XCTAssertTrue(
            waitForTabOrder(
                tabs,
                expectedIdentifiers: [
                    initialIdentifiers[0],
                    initialIdentifiers[2],
                    initialIdentifiers[1]
                ],
                timeout: 5
            )
        )
        XCTAssertEqual(editor.value as? String, "Third Tab State")

        XCTAssertTrue(firstSelect.waitForExistence(timeout: 2))
        tabStrip.swipeRight()
        XCTAssertTrue(waitForHittable(firstSelect, timeout: 5))
        firstSelect.tap()
        XCTAssertTrue(waitForValue(editor, value: "First Tab State", timeout: 5))

        let thirdSelect = app.buttons["phonepad.tab.select.\(thirdSuffix)"]
        tabStrip.swipeLeft()
        XCTAssertTrue(waitForHittable(thirdSelect, timeout: 5))
        XCTAssertEqual(thirdSelect.frame.height, 44, accuracy: 0.01)
        XCTAssertEqual(thirdDrag.frame.height, 44, accuracy: 0.01)
        XCTAssertFalse(thirdSelect.frame.intersects(thirdDrag.frame))
        thirdSelect.tap()
        XCTAssertTrue(waitForValue(editor, value: "Third Tab State", timeout: 5))
    }

    @MainActor
    func testUnsavedTabCloseCancelAndDiscardUseStableIdentifiers() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let editor = app.textViews["phonepad.editor.text-view"]
        let newTab = app.buttons["phonepad.toolbar.new-tab"]
        let tabs = tabItems(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(newTab.waitForExistence(timeout: 2))
        XCTAssertEqual(tabs.count, 1)

        newTab.tap()
        XCTAssertTrue(waitForCount(tabs, count: 2, timeout: 5))
        editor.tap()
        editor.typeText("Unsaved close state")

        let tabIdentifiers = tabs.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(tabIdentifiers.count, 2)
        let firstTabIdentifier = tabIdentifiers[0]
        let closingTabIdentifier = tabIdentifiers[1]
        let closingSuffix = String(
            closingTabIdentifier.dropFirst("phonepad.tab.item.".count)
        )
        let closeButton = app.buttons["phonepad.tab.close.\(closingSuffix)"]
        let dragHandle = app.descendants(matching: .any)[
            "phonepad.tab.drag.\(closingSuffix)"
        ].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        XCTAssertTrue(dragHandle.waitForExistence(timeout: 2))
        XCTAssertEqual(closeButton.frame.width, 44, accuracy: 0.01)
        XCTAssertFalse(closeButton.frame.intersects(dragHandle.frame))

        closeButton.tap()
        let prompt = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "phonepad.tab-close.prompt."
            )
        ).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let cancel = app.buttons["phonepad.tab-close.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tabs[closingTabIdentifier].exists)
        XCTAssertTrue(
            waitForValue(editor, value: "Unsaved close state", timeout: 5)
        )

        closeButton.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let discard = app.buttons["phonepad.tab-close.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 2))
        discard.tap()
        XCTAssertTrue(waitForCount(tabs, count: 1, timeout: 5))
        XCTAssertFalse(tabs[closingTabIdentifier].exists)
        XCTAssertTrue(tabs[firstTabIdentifier].exists)

        let firstSuffix = String(
            firstTabIdentifier.dropFirst("phonepad.tab.item.".count)
        )
        let cleanClose = app.buttons["phonepad.tab.close.\(firstSuffix)"]
        XCTAssertTrue(cleanClose.waitForExistence(timeout: 2))
        cleanClose.tap()
        XCTAssertTrue(waitForCount(tabs, count: 1, timeout: 5))
        XCTAssertFalse(tabs[firstTabIdentifier].exists)
    }

    @MainActor
    func testTabStripGrowsForAccessibilityContentSize() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        ]
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let tab = tabItems(in: app).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(tab.frame.height, 44)
    }

    @MainActor
    func testTabStripKeepsStandardGeometryAtLargestStandardContentSize() {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.extraExtraExtraLarge.rawValue
        ]
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let tab = tabItems(in: app).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        XCTAssertEqual(tab.frame.height, 44, accuracy: 0.5)
    }

    @MainActor
    func testOpenControlAdaptsToDeviceWidthClass() {
        let app = launchPhonePad()
        let toolbarOpen = app.buttons["phonepad.toolbar.open"]
        let actionMenu = app.descendants(matching: .any)[
            "phonepad.action-menu"
        ].firstMatch

        XCTAssertTrue(actionMenu.waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(toolbarOpen.waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(toolbarOpen.exists)
        }
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

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func tabItems(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "phonepad.tab.item.")
        )
    }

    @MainActor
    private func launchPhonePad() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID()
            .uuidString
        app.launch()
        return app
    }

    @MainActor
    private func launchExternalOpenHost() -> XCUIApplication {
        let host = XCUIApplication(
            bundleIdentifier: "com.anvilfilbert.PhonePad.ExternalOpenHost"
        )
        host.launch()
        return host
    }

    @MainActor
    private func externalOpenFixture(
        in host: XCUIApplication,
        urlIdentifier: String,
        contentIdentifier: String
    ) throws -> ExternalOpenHostFixture {
        let ready = host.staticTexts["externalopenhost.ready"]
        guard ready.waitForExistence(timeout: 5) else {
            let error = host.staticTexts["externalopenhost.error"]
            throw ExternalOpenHostUITestError.hostNotReady(
                errorValue: error.value as? String
            )
        }
        let urlElement = host.staticTexts[urlIdentifier]
        guard urlElement.waitForExistence(timeout: 2),
              let urlValue = urlElement.value as? String,
              let url = URL(string: urlValue),
              url.isFileURL else {
            throw ExternalOpenHostUITestError.invalidFixtureURL(
                identifier: urlIdentifier,
                value: urlElement.value as? String
            )
        }
        let contentElement = host.staticTexts[contentIdentifier]
        guard contentElement.waitForExistence(timeout: 2),
              let content = contentElement.value as? String else {
            throw ExternalOpenHostUITestError.missingFixtureContent(
                identifier: contentIdentifier
            )
        }
        return ExternalOpenHostFixture(url: url, content: content)
    }

    @MainActor
    private func openPhonePadCold(with url: URL) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.anvilfilbert.PhonePad")
        app.launchEnvironment["PHONEPAD_UI_TEST_RECOVERY_NAMESPACE"] = UUID().uuidString
        app.terminate()
        app.open(url)
        return app
    }

    @MainActor
    private func waitForTabOrder(
        _ query: XCUIElementQuery,
        expectedIdentifiers: [String],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let identifiers = query.allElementsBoundByIndex.map(\.identifier)
            if identifiers == expectedIdentifiers {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

}

private struct ExternalOpenHostFixture {
    let url: URL
    let content: String
}

private enum ExternalOpenHostUITestError: Error {
    case hostNotReady(errorValue: String?)
    case invalidFixtureURL(identifier: String, value: String?)
    case missingFixtureContent(identifier: String)
}
