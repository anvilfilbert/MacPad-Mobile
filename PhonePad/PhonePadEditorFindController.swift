import UIKit

enum PhonePadEditorFindError: Error, Equatable, LocalizedError {
    case editorUnavailable
    case findSessionUnavailable
    case editorReadOnly
    case markedTextActive

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            return "Editor is unavailable. Keep this Document open and retry Find."
        case .findSessionUnavailable:
            return "Find is not active. Open Find, enter a search term, and retry."
        case .editorReadOnly:
            return "This Document is read-only. Use Find without replacement."
        case .markedTextActive:
            return "Finish the current text composition before replacing matches."
        }
    }
}

@MainActor
final class PhonePadEditorFindController {
    private weak var textView: UITextView?

    init() {}

    func presentFind() throws {
        let interaction = try requireFindInteraction()
        interaction.presentFindNavigator(showingReplace: false)
    }

    func presentReplace() throws {
        let interaction = try requireFindInteraction()
        interaction.presentFindNavigator(showingReplace: true)
    }

    func findNext() throws {
        let interaction = try requireActiveFindInteraction()
        interaction.findNext()
    }

    func findPrevious() throws {
        let interaction = try requireActiveFindInteraction()
        interaction.findPrevious()
    }

    func replaceCurrent() throws {
        let replacement = try requireReplacementSession()
        guard !replacement.query.isEmpty else {
            return
        }
        replacement.session.performSingleReplacement(
            query: replacement.query,
            replacementString: replacement.replacementText,
            options: nil
        )
    }

    func replaceAll() throws {
        let replacement = try requireReplacementSession()
        guard !replacement.query.isEmpty else {
            return
        }
        replacement.session.replaceAll(
            searchQuery: replacement.query,
            replacementString: replacement.replacementText,
            options: nil
        )
    }

    func connect(textView: UITextView) {
        self.textView = textView
    }

    func disconnect(textView: UITextView) {
        guard self.textView === textView else {
            return
        }
        self.textView = nil
    }

    private func requireFindInteraction() throws -> UIFindInteraction {
        guard let textView,
              let interaction = textView.findInteraction else {
            throw PhonePadEditorFindError.editorUnavailable
        }
        return interaction
    }

    private func requireActiveFindInteraction() throws -> UIFindInteraction {
        let interaction = try requireFindInteraction()
        guard interaction.activeFindSession != nil else {
            throw PhonePadEditorFindError.findSessionUnavailable
        }
        return interaction
    }

    private func requireReplacementSession() throws -> (
        session: UIFindSession,
        query: String,
        replacementText: String
    ) {
        guard let textView else {
            throw PhonePadEditorFindError.editorUnavailable
        }
        guard textView.isEditable else {
            throw PhonePadEditorFindError.editorReadOnly
        }
        guard textView.markedTextRange == nil else {
            throw PhonePadEditorFindError.markedTextActive
        }
        let interaction = try requireFindInteraction()
        guard let session = interaction.activeFindSession else {
            throw PhonePadEditorFindError.findSessionUnavailable
        }
        return (
            session: session,
            query: interaction.searchText ?? "",
            replacementText: interaction.replacementText ?? ""
        )
    }
}
