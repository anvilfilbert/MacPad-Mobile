import XCTest

final class PhonePadLaunchUITests: XCTestCase {
    @MainActor
    func testOrdinaryLaunchShowsOneFreshTabAndAcceptsText() {
        let app = XCUIApplication()
        app.launch()

        let root = app.descendants(matching: .any)["phonepad.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))

        let tabs = app.descendants(matching: .any).matching(identifier: "phonepad.tab.item")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.element(boundBy: 0).label, "Untitled")

        let editor = app.textViews["phonepad.editor.text-view"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Hello from PhonePad")

        XCTAssertEqual(editor.value as? String, "Hello from PhonePad")
    }
}
