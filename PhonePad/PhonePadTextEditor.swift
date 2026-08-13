import SwiftUI
import UIKit

struct PhonePadTextEditor: UIViewRepresentable {
    @Binding private var text: String

    init(text: Binding<String>) {
        _text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.accessibilityIdentifier = "phonepad.editor.text-view"
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(text: $text)

        guard textView.markedTextRange == nil, textView.text != text else {
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

        init(text: Binding<String>) {
            self.text = text
        }

        func update(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            let updatedText = textView.text ?? ""
            guard text.wrappedValue != updatedText else {
                return
            }
            text.wrappedValue = updatedText
        }
    }
}
