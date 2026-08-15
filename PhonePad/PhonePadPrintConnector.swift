import Foundation
import UIKit

struct PhonePadPrintDocument: Equatable, Sendable {
    let title: String
    let text: String
}

enum PhonePadPrintOutcome: Equatable, Sendable {
    case completed
    case cancelled
}

enum PhonePadPrintError: Error, Equatable, LocalizedError {
    case presentationRejected
    case interactionFailed(domain: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .presentationRejected:
            return "Print could not open. Keep PhonePad visible and try again."
        case let .interactionFailed(domain, code):
            return "Print failed in the system print service (\(domain), code \(code)). Check the printer and try again."
        }
    }
}

@MainActor
final class PhonePadPrintConnector {
    typealias Completion = @MainActor (Bool, Error?) -> Void
    typealias Presenter = @MainActor (
        PhonePadPrintDocument,
        @escaping Completion
    ) -> Bool

    private let presenter: Presenter

    init(presenter: @escaping Presenter) {
        self.presenter = presenter
    }

    func present(
        document: PhonePadPrintDocument
    ) async throws -> PhonePadPrintOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = presenter(document) { completed, error in
                if let error = error as NSError? {
                    continuation.resume(
                        throwing: PhonePadPrintError.interactionFailed(
                            domain: error.domain,
                            code: error.code
                        )
                    )
                    return
                }
                continuation.resume(
                    returning: completed ? .completed : .cancelled
                )
            }
            guard accepted else {
                continuation.resume(
                    throwing: PhonePadPrintError.presentationRejected
                )
                return
            }
        }
    }
}

@MainActor
func makePhonePadPrintConnector() -> PhonePadPrintConnector {
    PhonePadPrintConnector { document, completion in
        guard let sourceView = phonePadPrintSourceView() else {
            return false
        }

        let controller = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = document.title
        printInfo.outputType = .general
        controller.printInfo = printInfo
        controller.printFormatter = UISimpleTextPrintFormatter(
            text: document.text
        )
        return controller.present(
            from: sourceView.bounds,
            in: sourceView,
            animated: true
        ) { _, completed, error in
            completion(completed, error)
        }
    }
}

@MainActor
private func phonePadPrintSourceView() -> UIView? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: { $0.isKeyWindow })?
        .rootViewController?
        .view
}
