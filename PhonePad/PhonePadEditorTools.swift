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
    case selectionRequired
    case undoUnavailable
    case redoUnavailable
    case commandUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            return "Editor is unavailable. Keep the current Document open and retry."
        case .editorIsReadOnly:
            return "Current Document is read-only. Choose Save As before changing its text."
        case .markedTextActive:
            return "Finish the current marked-text composition before using this editor tool."
        case .selectionRequired:
            return "Select text before using this editor command."
        case .undoUnavailable:
            return "No editor change is available to undo."
        case .redoUnavailable:
            return "No editor change is available to redo."
        case let .commandUnavailable(command):
            return "The editor cannot perform \(command) right now. Check the selection or system pasteboard content and retry."
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

    func undo() throws {
        let editor = try requireMutableEditor()
        guard let undoManager = editor.undoManager,
              undoManager.canUndo else {
            throw PhonePadEditorToolError.undoUnavailable
        }
        undoManager.undo()
    }

    func redo() throws {
        let editor = try requireMutableEditor()
        guard let undoManager = editor.undoManager,
              undoManager.canRedo else {
            throw PhonePadEditorToolError.redoUnavailable
        }
        undoManager.redo()
    }

    func cutSelection() throws {
        let editor = try requireMutableEditor()
        try requireSelection(in: editor)
        try perform(
            command: "Cut",
            selector: #selector(UIResponderStandardEditActions.cut(_:)),
            in: editor
        ) {
            editor.cut(nil)
        }
    }

    func copySelection() throws {
        let editor = try requireEditor()
        try requireSelection(in: editor)
        try perform(
            command: "Copy",
            selector: #selector(UIResponderStandardEditActions.copy(_:)),
            in: editor
        ) {
            editor.copy(nil)
        }
    }

    func paste() throws {
        let editor = try requireMutableEditor()
        guard UIPasteboard.general.hasStrings,
              let pastedText = UIPasteboard.general.string else {
            throw PhonePadEditorToolError.commandUnavailable("Paste")
        }
        editor.insertText(pastedText)
    }

    func deleteSelection() throws {
        let editor = try requireMutableEditor()
        try requireSelection(in: editor)
        editor.deleteBackward()
    }

    func selectAll() throws {
        let editor = try requireEditor()
        try perform(
            command: "Select All",
            selector: #selector(UIResponderStandardEditActions.selectAll(_:)),
            in: editor
        ) {
            editor.selectAll(nil)
        }
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

    private func requireMutableEditor() throws -> UITextView {
        let editor = try requireEditor()
        guard editor.isEditable else {
            throw PhonePadEditorToolError.editorIsReadOnly
        }
        return editor
    }

    private func requireSelection(in editor: UITextView) throws {
        guard editor.selectedRange.length > 0 else {
            throw PhonePadEditorToolError.selectionRequired
        }
    }

    private func perform(
        command: String,
        selector: Selector,
        in editor: UITextView,
        action: () -> Void
    ) throws {
        guard editor.canPerformAction(selector, withSender: nil) else {
            throw PhonePadEditorToolError.commandUnavailable(command)
        }
        action()
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
