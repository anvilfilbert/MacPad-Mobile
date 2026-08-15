import Combine
import Foundation
import PhonePadCore
import SwiftUI
import UIKit

struct PhonePadEditorSelection: Equatable, Sendable {
    let documentID: DocumentID
    let position: EditorTextPosition
}

enum PhonePadEditorToolError: Error, Equatable, LocalizedError {
    case editorUnavailable
    case editorIsReadOnly
    case markedTextActive

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            return "Editor is unavailable. Keep the current Document open and retry."
        case .editorIsReadOnly:
            return "Current Document is read-only. Choose Save As before inserting Time/Date."
        case .markedTextActive:
            return "Finish the current marked-text composition before using this editor tool."
        }
    }
}

@MainActor
final class PhonePadEditorToolController: ObservableObject {
    @Published private(set) var selection: PhonePadEditorSelection?

    private weak var textView: UITextView?
    private var documentID: DocumentID?

    init() {
        selection = nil
        documentID = nil
    }

    func goToLine(oneBasedLine: Int) throws {
        let editor = try requireEditor()
        let offset = try editorUTF16OffsetForLine(
            text: editor.text ?? "",
            oneBasedLine: oneBasedLine
        )
        editor.selectedRange = NSRange(location: offset, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange)
        try publishSelection(
            text: editor.text ?? "",
            utf16Offset: offset
        )
    }

    @discardableResult
    func insertTimeAndDate(
        date: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) throws -> String {
        let editor = try requireEditor()
        guard editor.isEditable else {
            throw PhonePadEditorToolError.editorIsReadOnly
        }
        guard editor.markedTextRange == nil else {
            throw PhonePadEditorToolError.markedTextActive
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let insertedText = formatter.string(from: date)
        editor.insertText(insertedText)
        return insertedText
    }

    func connect(
        textView: UITextView,
        documentID: DocumentID
    ) {
        self.textView = textView
        self.documentID = documentID
    }

    func updateDocumentID(_ documentID: DocumentID) {
        self.documentID = documentID
    }

    func updateSelection(
        documentID: DocumentID,
        text: String,
        utf16Offset: Int
    ) {
        let position: EditorTextPosition
        do {
            position = try editorTextPosition(
                text: text,
                utf16Offset: utf16Offset
            )
        } catch {
            preconditionFailure(error.localizedDescription)
        }
        selection = PhonePadEditorSelection(
            documentID: documentID,
            position: position
        )
    }

    func disconnect(textView: UITextView) {
        guard self.textView === textView else {
            return
        }
        self.textView = nil
        documentID = nil
        selection = nil
    }

    private func requireEditor() throws -> UITextView {
        guard let textView, documentID != nil else {
            throw PhonePadEditorToolError.editorUnavailable
        }
        return textView
    }

    private func publishSelection(
        text: String,
        utf16Offset: Int
    ) throws {
        guard let documentID else {
            throw PhonePadEditorToolError.editorUnavailable
        }
        selection = PhonePadEditorSelection(
            documentID: documentID,
            position: try editorTextPosition(
                text: text,
                utf16Offset: utf16Offset
            )
        )
    }
}

struct PhonePadFontPicker: UIViewControllerRepresentable {
    let onSelection: (PhonePadFontFamily) -> Void
    let onCancellation: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onCancellation: onCancellation
        )
    }

    func makeUIViewController(
        context: Context
    ) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIFontPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        private let onSelection: (PhonePadFontFamily) -> Void
        private let onCancellation: () -> Void

        init(
            onSelection: @escaping (PhonePadFontFamily) -> Void,
            onCancellation: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onCancellation = onCancellation
        }

        func fontPickerViewControllerDidPickFont(
            _ viewController: UIFontPickerViewController
        ) {
            guard let descriptor = viewController.selectedFontDescriptor else {
                onCancellation()
                return
            }
            onSelection(
                .named(postScriptName: descriptor.postscriptName)
            )
        }

        func fontPickerViewControllerDidCancel(
            _ viewController: UIFontPickerViewController
        ) {
            onCancellation()
        }
    }
}
