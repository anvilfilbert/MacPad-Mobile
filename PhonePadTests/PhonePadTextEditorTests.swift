import PhonePadCore
import SwiftUI
import UIKit
import XCTest
@testable import PhonePad

@MainActor
private final class EditorTestModel: ObservableObject {
    @Published var documentID: DocumentID
    @Published var text: String
    @Published var isEditable: Bool
    @Published var renderGeneration: UInt64

    init(documentID: DocumentID, text: String, isEditable: Bool) {
        self.documentID = documentID
        self.text = text
        self.isEditable = isEditable
        renderGeneration = 0
    }
}

@MainActor
private struct EditorHarness: View {
    @ObservedObject var model: EditorTestModel
    let transitionController: PhonePadEditorTransitionController

    var body: some View {
        let _ = model.renderGeneration
        PhonePadTextEditor(
            documentID: model.documentID,
            text: $model.text,
            isEditable: model.isEditable,
            transitionController: transitionController
        )
    }
}

@MainActor
private struct HostedEditor {
    let model: EditorTestModel
    let controller: UIHostingController<EditorHarness>
    let transitionController: PhonePadEditorTransitionController
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
        let fixture = try makeHostedEditor(text: "abcd", isEditable: true)
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
        let fixture = try makeHostedEditor(text: "ab", isEditable: true)
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
    func testTransitionCommitSynchronouslyPublishesMarkedTextBeforeDocumentChange() throws {
        let fixture = try makeHostedEditor(text: "ab", isEditable: true)
        defer { destroy(fixture) }

        fixture.textView.selectedRange = NSRange(location: 2, length: 0)
        fixture.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0)
        )
        render(fixture.controller)
        let displayedComposition = try XCTUnwrap(fixture.textView.text)

        fixture.model.text = "stale model text"
        render(fixture.controller)
        XCTAssertNotEqual(fixture.model.text, displayedComposition)
        XCTAssertNotNil(fixture.textView.markedTextRange)

        let committedDocument = try fixture.transitionController.commitMarkedText()

        XCTAssertNil(fixture.textView.markedTextRange)
        XCTAssertEqual(fixture.model.text, displayedComposition)
        XCTAssertEqual(committedDocument.documentID, fixture.model.documentID)
        XCTAssertEqual(committedDocument.text, displayedComposition)
    }

    @MainActor
    func testDocumentSwitchIsolatesUndoWhileSameDocumentRenderPreservesComposition() throws {
        let fixture = try makeHostedEditor(text: "First", isEditable: true)
        defer { destroy(fixture) }

        fixture.textView.selectedRange = NSRange(location: 5, length: 0)
        fixture.textView.insertText(" document")
        fixture.textView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0)
        )
        render(fixture.controller)
        let markedText = fixture.textView.text

        fixture.model.renderGeneration += 1
        render(fixture.controller)

        let reorderedTextView = try requireTextView(in: fixture.controller.view)
        XCTAssertTrue(reorderedTextView === fixture.textView)
        XCTAssertNotNil(reorderedTextView.markedTextRange)
        XCTAssertEqual(reorderedTextView.text, markedText)

        fixture.model.text = "Second"
        fixture.model.documentID = DocumentID(rawValue: UUID())
        render(fixture.controller)

        let switchedTextView = try requireTextView(in: fixture.controller.view)
        XCTAssertFalse(switchedTextView === fixture.textView)
        XCTAssertEqual(switchedTextView.text, "Second")
        XCTAssertFalse(try XCTUnwrap(switchedTextView.undoManager).canUndo)
    }

    @MainActor
    func testReadOnlyEditorOffersCopyWithoutEditingActions() throws {
        let fixture = try makeHostedEditor(text: "Copy this text", isEditable: true)
        defer { destroy(fixture) }

        fixture.model.isEditable = false
        render(fixture.controller)

        XCTAssertFalse(fixture.textView.isEditable)
        XCTAssertTrue(fixture.textView.isSelectable)
        XCTAssertTrue(fixture.textView.isUserInteractionEnabled)

        fixture.textView.selectedRange = NSRange(location: 0, length: 4)
        XCTAssertEqual(fixture.textView.selectedRange, NSRange(location: 0, length: 4))
        XCTAssertTrue(
            fixture.textView.canPerformAction(
                #selector(UIResponderStandardEditActions.copy(_:)),
                withSender: nil
            )
        )
        XCTAssertFalse(
            fixture.textView.canPerformAction(
                #selector(UIResponderStandardEditActions.cut(_:)),
                withSender: nil
            )
        )
        XCTAssertFalse(
            fixture.textView.canPerformAction(
                #selector(UIResponderStandardEditActions.paste(_:)),
                withSender: nil
            )
        )

        XCTAssertEqual(fixture.textView.text, "Copy this text")
        XCTAssertEqual(fixture.model.text, "Copy this text")
    }

    @MainActor
    private func makeHostedEditor(text: String, isEditable: Bool) throws -> HostedEditor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            throw EditorHarnessError.missingForegroundWindowScene
        }

        let model = EditorTestModel(
            documentID: DocumentID(rawValue: UUID()),
            text: text,
            isEditable: isEditable
        )
        let transitionController = PhonePadEditorTransitionController()
        let controller = UIHostingController(
            rootView: EditorHarness(
                model: model,
                transitionController: transitionController
            )
        )
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
            transitionController: transitionController,
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
