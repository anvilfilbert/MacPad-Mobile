import SwiftUI
import UIKit
import XCTest
@testable import PhonePad

@MainActor
private final class EditorTestModel: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

@MainActor
private struct EditorHarness: View {
    @ObservedObject var model: EditorTestModel

    var body: some View {
        PhonePadTextEditor(text: $model.text)
    }
}

@MainActor
private struct HostedEditor {
    let model: EditorTestModel
    let controller: UIHostingController<EditorHarness>
    let window: UIWindow
    let textView: UITextView
}

private enum EditorHarnessError: Error {
    case missingForegroundWindowScene
    case missingTextView
    case couldNotBecomeFirstResponder
}

final class PhonePadTextEditorTests: XCTestCase {
    @MainActor
    func testInitialBindingAndInsertPreserveSelectionAndUndoAcrossModelUpdate() throws {
        let fixture = try makeHostedEditor(text: "abcd")
        defer { destroy(fixture) }

        XCTAssertEqual(fixture.textView.text, "abcd")

        fixture.textView.selectedRange = NSRange(location: 2, length: 0)
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        undoManager.removeAllActions()

        fixture.textView.insertText("X")
        render(fixture.controller)

        XCTAssertEqual(fixture.model.text, "abXcd")
        XCTAssertEqual(fixture.textView.text, "abXcd")
        XCTAssertEqual(fixture.textView.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertTrue(undoManager.canUndo)

        let selectionBeforeUpdate = fixture.textView.selectedRange
        fixture.model.text = "abXcd!"
        render(fixture.controller)

        let currentTextView = try requireTextView(in: fixture.controller.view)
        XCTAssertTrue(currentTextView === fixture.textView)
        XCTAssertEqual(currentTextView.text, "abXcd!")
        XCTAssertEqual(currentTextView.selectedRange, selectionBeforeUpdate)
        XCTAssertTrue(undoManager.canUndo)
    }

    @MainActor
    func testModelUpdateDoesNotOverwriteMarkedText() throws {
        let fixture = try makeHostedEditor(text: "ab")
        defer { destroy(fixture) }

        fixture.textView.selectedRange = NSRange(location: 2, length: 0)
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        undoManager.removeAllActions()
        fixture.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0)
        )
        render(fixture.controller)

        let displayedComposition = try XCTUnwrap(fixture.textView.text)
        let markedBeforeUpdate = try XCTUnwrap(fixture.textView.markedTextRange)
        let markedRangeBeforeUpdate = textRange(markedBeforeUpdate, in: fixture.textView)
        let selectionBeforeUpdate = fixture.textView.selectedRange

        fixture.model.text = "programmatic replacement"
        render(fixture.controller)

        let currentTextView = try requireTextView(in: fixture.controller.view)
        XCTAssertTrue(currentTextView === fixture.textView)
        XCTAssertEqual(currentTextView.text, displayedComposition)
        let markedAfterUpdate = try XCTUnwrap(currentTextView.markedTextRange)
        XCTAssertEqual(textRange(markedAfterUpdate, in: currentTextView), markedRangeBeforeUpdate)
        XCTAssertEqual(currentTextView.selectedRange, selectionBeforeUpdate)

        currentTextView.unmarkText()
        render(fixture.controller)

        XCTAssertNil(currentTextView.markedTextRange)
        XCTAssertEqual(currentTextView.text, displayedComposition)
        XCTAssertEqual(fixture.model.text, displayedComposition)
        XCTAssertEqual(currentTextView.selectedRange, selectionBeforeUpdate)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        render(fixture.controller)

        XCTAssertEqual(currentTextView.text, "ab")
        XCTAssertEqual(fixture.model.text, "ab")
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        render(fixture.controller)

        XCTAssertEqual(currentTextView.text, displayedComposition)
        XCTAssertEqual(fixture.model.text, displayedComposition)
    }

    @MainActor
    private func makeHostedEditor(text: String) throws -> HostedEditor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            throw EditorHarnessError.missingForegroundWindowScene
        }

        let model = EditorTestModel(text: text)
        let controller = UIHostingController(rootView: EditorHarness(model: model))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        render(controller)

        let textView = try requireTextView(in: controller.view)
        guard textView.becomeFirstResponder() else {
            throw EditorHarnessError.couldNotBecomeFirstResponder
        }
        render(controller)

        return HostedEditor(
            model: model,
            controller: controller,
            window: window,
            textView: textView
        )
    }

    @MainActor
    private func destroy(_ fixture: HostedEditor) {
        fixture.textView.resignFirstResponder()
        fixture.window.isHidden = true
    }

    @MainActor
    private func render(_ controller: UIHostingController<EditorHarness>) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        controller.view.layoutIfNeeded()
    }

    @MainActor
    private func requireTextView(in root: UIView) throws -> UITextView {
        guard let textView = descendantTextView(in: root) else {
            throw EditorHarnessError.missingTextView
        }
        return textView
    }

    @MainActor
    private func descendantTextView(in root: UIView) -> UITextView? {
        if let textView = root as? UITextView,
           textView.accessibilityIdentifier == "phonepad.editor.text-view" {
            return textView
        }
        for subview in root.subviews {
            if let textView = descendantTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    @MainActor
    private func textRange(_ range: UITextRange, in textView: UITextView) -> NSRange {
        let location = textView.offset(from: textView.beginningOfDocument, to: range.start)
        let length = textView.offset(from: range.start, to: range.end)
        return NSRange(location: location, length: length)
    }
}
