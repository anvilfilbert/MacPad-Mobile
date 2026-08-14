import SwiftUI
import UIKit

@MainActor
final class PhonePadEditorTransitionController {
    private weak var textView: UITextView?
    private weak var coordinator: PhonePadTextEditor.Coordinator?

    init() {}

    func commitMarkedText() throws {
        guard let textView,
              let coordinator else {
            throw PhonePadEditorTransitionError.editorUnavailable
        }
        textView.unmarkText()
        coordinator.synchronizeForDocumentTransition(in: textView)
    }

    fileprivate func connect(
        textView: UITextView,
        coordinator: PhonePadTextEditor.Coordinator
    ) {
        self.textView = textView
        self.coordinator = coordinator
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

struct PhonePadTextEditor: UIViewRepresentable {
    @Binding private var text: String
    private let isEditable: Bool
    private let transitionController: PhonePadEditorTransitionController

    init(
        text: Binding<String>,
        isEditable: Bool,
        transitionController: PhonePadEditorTransitionController
    ) {
        _text = text
        self.isEditable = isEditable
        self.transitionController = transitionController
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
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
        context.coordinator.update(text: $text)
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

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var deferredModelText: String?
        private var compositionIsActive = false

        init(text: Binding<String>) {
            self.text = text
        }

        func update(text: Binding<String>) {
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

        func synchronizeForDocumentTransition(in textView: UITextView) {
            compositionIsActive = false
            deferredModelText = nil
            synchronizeBinding(with: textView)
        }

        private func synchronizeBinding(with textView: UITextView) {
            let updatedText = textView.text ?? ""
            guard text.wrappedValue != updatedText else {
                return
            }
            text.wrappedValue = updatedText
        }
    }
}
