import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadPrintConnectorTests: XCTestCase {
    func testExplicitPrintPresentsCurrentUnsavedDocumentText() async throws {
        let observation = PrintPresentationObservation()
        let connector = PhonePadPrintConnector(
            presenter: observation.present
        )
        let document = PhonePadPrintDocument(
            title: "Unsaved.txt",
            text: "Current unsaved edits\n"
        )

        let outcome = try await connector.present(document: document)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(observation.presentedDocument, document)
    }

    func testPrintPresentationFailureIsTypedAndDoesNotChangeDocumentState() async throws {
        let originalState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let connector = PhonePadPrintConnector(
            presenter: { _, _ in false }
        )

        do {
            _ = try await connector.present(
                document: PhonePadPrintDocument(
                    title: originalState.activeTab.document.title,
                    text: originalState.activeTab.document.text
                )
            )
            XCTFail("Expected rejected print presentation.")
        } catch let error as PhonePadPrintError {
            XCTAssertEqual(error, .presentationRejected)
        }

        XCTAssertEqual(
            originalState,
            makeInitialPhonePadState(
                documentID: originalState.activeTab.document.id,
                tabID: originalState.activeTab.id
            )
        )
    }
}

@MainActor
private final class PrintPresentationObservation {
    private(set) var presentedDocument: PhonePadPrintDocument?

    func present(
        document: PhonePadPrintDocument,
        completion: @escaping @MainActor (Bool, Error?) -> Void
    ) -> Bool {
        presentedDocument = document
        completion(true, nil)
        return true
    }
}
