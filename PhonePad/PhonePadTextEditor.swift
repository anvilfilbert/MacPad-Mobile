import PhonePadCore
import SwiftUI
import UIKit

struct CommittedEditorDocument: Equatable, Sendable {
    let documentID: DocumentID
    let text: String
}

@MainActor
final class PhonePadEditorTransitionController {
    private weak var textView: UITextView?
    private weak var coordinator: PhonePadEditorCoordinator?

    init() {}

    func commitMarkedText() throws -> CommittedEditorDocument {
        guard let textView,
              let coordinator else {
            throw PhonePadEditorTransitionError.editorUnavailable
        }
        textView.unmarkText()
        return coordinator.synchronizeForDocumentTransition(in: textView)
    }

    fileprivate func connect(
        textView: UITextView,
        coordinator: PhonePadEditorCoordinator
    ) {
        self.textView = textView
        self.coordinator = coordinator
    }

    fileprivate func disconnect(coordinator: PhonePadEditorCoordinator) {
        guard self.coordinator === coordinator else {
            return
        }
        textView = nil
        self.coordinator = nil
    }
}

enum PhonePadEditorTransitionError: Error, LocalizedError {
    case editorUnavailable

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            "Editor is unavailable. Keep the current Document open and retry."
        }
    }
}

struct PhonePadTextEditor: View {
    private let documentID: DocumentID
    @Binding private var text: String
    private let isEditable: Bool
    private let transitionController: PhonePadEditorTransitionController

    init(
        documentID: DocumentID,
        text: Binding<String>,
        isEditable: Bool,
        transitionController: PhonePadEditorTransitionController
    ) {
        self.documentID = documentID
        _text = text
        self.isEditable = isEditable
        self.transitionController = transitionController
    }

    var body: some View {
        PhonePadTextEditorRepresentable(
            documentID: documentID,
            text: $text,
            isEditable: isEditable,
            transitionController: transitionController
        )
        .id(documentID)
    }
}

private struct PhonePadTextEditorRepresentable: UIViewRepresentable {
    let documentID: DocumentID
    @Binding var text: String
    let isEditable: Bool
    let transitionController: PhonePadEditorTransitionController

    func makeCoordinator() -> PhonePadEditorCoordinator {
        PhonePadEditorCoordinator(documentID: documentID, text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        context.coordinator.transitionController = transitionController
        textView.delegate = context.coordinator
        textView.text = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.accessibilityIdentifier = "phonepad.editor.text-view"
        transitionController.connect(
            textView: textView,
            coordinator: context.coordinator
        )
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(documentID: documentID, text: $text)
        textView.isEditable = isEditable
        textView.isSelectable = true

        if textView.markedTextRange != nil {
            context.coordinator.deferModelText(text, displayedText: textView.text ?? "")
            return
        }

        if context.coordinator.reconcileCommittedComposition(in: textView) {
            return
        }

        guard textView.text != text else {
            return
        }

        let selection = textView.selectedRange
        if let fullRange = textView.textRange(
            from: textView.beginningOfDocument,
            to: textView.endOfDocument
        ) {
            textView.replace(fullRange, withText: text)
        }
        textView.selectedRange = clampedSelection(selection, textLength: textView.textStorage.length)
    }

    private func clampedSelection(_ selection: NSRange, textLength: Int) -> NSRange {
        let location = min(selection.location, textLength)
        let availableLength = textLength - location
        return NSRange(location: location, length: min(selection.length, availableLength))
    }

    static func dismantleUIView(
        _ textView: UITextView,
        coordinator: PhonePadEditorCoordinator
    ) {
        coordinator.transitionController?.disconnect(coordinator: coordinator)
        textView.delegate = nil
    }
}

@MainActor
fileprivate final class PhonePadEditorCoordinator: NSObject, UITextViewDelegate {
    fileprivate weak var transitionController: PhonePadEditorTransitionController?
    private var documentID: DocumentID
    private var text: Binding<String>
    private var deferredModelText: String?
    private var compositionIsActive = false

    init(documentID: DocumentID, text: Binding<String>) {
        self.documentID = documentID
        self.text = text
    }

    func update(documentID: DocumentID, text: Binding<String>) {
        self.documentID = documentID
        self.text = text
    }

    func deferModelText(_ modelText: String, displayedText: String) {
        compositionIsActive = true
        guard modelText != displayedText else {
            return
        }
        deferredModelText = modelText
    }

    @discardableResult
    func reconcileCommittedComposition(in textView: UITextView) -> Bool {
        guard compositionIsActive, textView.markedTextRange == nil else {
            return false
        }

        compositionIsActive = false
        let hadDeferredModelText = deferredModelText != nil
        deferredModelText = nil

        guard hadDeferredModelText else {
            return false
        }

        synchronizeBinding(with: textView)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView.markedTextRange != nil {
            compositionIsActive = true
        } else if reconcileCommittedComposition(in: textView) {
            return
        }

        synchronizeBinding(with: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.markedTextRange != nil {
            compositionIsActive = true
            return
        }

        _ = reconcileCommittedComposition(in: textView)
    }

    func synchronizeForDocumentTransition(
        in textView: UITextView
    ) -> CommittedEditorDocument {
        compositionIsActive = false
        deferredModelText = nil
        let committedText = textView.text ?? ""
        synchronizeBinding(with: textView)
        return CommittedEditorDocument(
            documentID: documentID,
            text: committedText
        )
    }

    private func synchronizeBinding(with textView: UITextView) {
        let updatedText = textView.text ?? ""
        guard text.wrappedValue != updatedText else {
            return
        }
        text.wrappedValue = updatedText
    }
}
