import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum PhonePadFolderPickerError: Error, LocalizedError {
    case invalidSelectionCount(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidSelectionCount(count):
            return "Files returned \(count) folders. Select exactly one folder and retry."
        }
    }
}

enum PhonePadFilePickerError: Error, LocalizedError {
    case invalidSelectionCount(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidSelectionCount(count):
            return "Files returned \(count) items. Select exactly one text File and retry."
        }
    }
}

@MainActor
struct PhonePadFolderPicker: UIViewControllerRepresentable {
    private let onSelection: @MainActor (URL) -> Void
    private let onCancellation: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(
        onSelection: @escaping @MainActor (URL) -> Void,
        onCancellation: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.onSelection = onSelection
        self.onCancellation = onCancellation
        self.onFailure = onFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onCancellation: onCancellation,
            onFailure: onFailure
        )
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "phonepad.save-as.folder-picker"
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: @MainActor (URL) -> Void
        private let onCancellation: @MainActor () -> Void
        private let onFailure: @MainActor (Error) -> Void

        init(
            onSelection: @escaping @MainActor (URL) -> Void,
            onCancellation: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor (Error) -> Void
        ) {
            self.onSelection = onSelection
            self.onCancellation = onCancellation
            self.onFailure = onFailure
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard urls.count == 1,
                  let selectedURL = urls.first else {
                onFailure(PhonePadFolderPickerError.invalidSelectionCount(urls.count))
                return
            }
            onSelection(selectedURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancellation()
        }
    }
}

@MainActor
struct PhonePadFilePicker: UIViewControllerRepresentable {
    private let onSelection: @MainActor (URL) -> Void
    private let onCancellation: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(
        onSelection: @escaping @MainActor (URL) -> Void,
        onCancellation: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.onSelection = onSelection
        self.onCancellation = onCancellation
        self.onFailure = onFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            onCancellation: onCancellation,
            onFailure: onFailure
        )
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.plainText, .data],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        picker.view.accessibilityIdentifier = "phonepad.open.picker"
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: @MainActor (URL) -> Void
        private let onCancellation: @MainActor () -> Void
        private let onFailure: @MainActor (Error) -> Void

        init(
            onSelection: @escaping @MainActor (URL) -> Void,
            onCancellation: @escaping @MainActor () -> Void,
            onFailure: @escaping @MainActor (Error) -> Void
        ) {
            self.onSelection = onSelection
            self.onCancellation = onCancellation
            self.onFailure = onFailure
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard urls.count == 1,
                  let selectedURL = urls.first else {
                onFailure(PhonePadFilePickerError.invalidSelectionCount(urls.count))
                return
            }
            onSelection(selectedURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancellation()
        }
    }
}
