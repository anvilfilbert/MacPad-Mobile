import Foundation
import XCTest
@testable import PhonePadCore

final class FileModelsTests: XCTestCase {
    func testValidatedFileNameAcceptsSinglePathComponent() throws {
        let fileName = try ValidatedFileName(validating: "Shopping List.txt")

        XCTAssertEqual(fileName.value, "Shopping List.txt")
    }

    func testValidatedFileNameAcceptsBackslashAsAnIOSFileNameCharacter() throws {
        let fileName = try ValidatedFileName(validating: "Draft\\August.txt")

        XCTAssertEqual(fileName.value, "Draft\\August.txt")
    }

    func testValidatedFileNameRejectsInvalidComponentsWithSpecificErrors() {
        assertInvalidFileName("", expectedError: .empty)
        assertInvalidFileName(".", expectedError: .reservedComponent("."))
        assertInvalidFileName("..", expectedError: .reservedComponent(".."))
        assertInvalidFileName("Folder/List.txt", expectedError: .multipleComponents)
        assertInvalidFileName("List\0.txt", expectedError: .containsNullByte)
    }

    func testNewTextFileUsesNormalizedLFAndExactUTF8WithoutBOM() throws {
        let encodedFile = try encodeNewTextFile(text: "First\r\nSecond\rThird")

        XCTAssertEqual(encodedFile.text, "First\nSecond\nThird")
        XCTAssertEqual(encodedFile.data, Data("First\nSecond\nThird".utf8))
        XCTAssertEqual(encodedFile.data.prefix(3), Data([0x46, 0x69, 0x72]))
        XCTAssertEqual(encodedFile.digest.bytes, Data([
            0x4d, 0x25, 0xe1, 0x35, 0x45, 0xbd, 0xa8, 0xd7,
            0xfc, 0x50, 0xa9, 0xf5, 0x91, 0xc5, 0x06, 0x99,
            0xb2, 0x19, 0x1d, 0x79, 0x3f, 0x73, 0xfa, 0xad,
            0x2e, 0x0d, 0xb8, 0x44, 0x54, 0xe3, 0x9b, 0x66,
        ]))
        XCTAssertEqual(encodedFile.encoding, .utf8)
        XCTAssertEqual(encodedFile.lineEnding, .lf)
    }

    func testNewTextFileAcceptsExactMaximumByteCount() throws {
        let text = String(repeating: "a", count: maximumSupportedTextFileByteCount)

        let encodedFile = try encodeNewTextFile(text: text)

        XCTAssertEqual(encodedFile.data.count, 25 * 1024 * 1024)
    }

    func testNewTextFileRejectsOneByteAboveMaximum() {
        let byteCount = maximumSupportedTextFileByteCount + 1
        let text = String(repeating: "a", count: byteCount)

        XCTAssertThrowsError(try encodeNewTextFile(text: text)) { error in
            XCTAssertEqual(
                error as? NewTextFileEncodingError,
                .contentTooLarge(
                    actualByteCount: byteCount,
                    maximumByteCount: maximumSupportedTextFileByteCount
                )
            )
        }
    }

    func testFileDigestRequiresExactlyThirtyTwoBytes() throws {
        let digest = try FileDigest(bytes: Data(repeating: 0x7f, count: 32))

        XCTAssertEqual(digest.bytes, Data(repeating: 0x7f, count: 32))
        XCTAssertThrowsError(
            try FileDigest(bytes: Data(repeating: 0x7f, count: 31))
        ) { error in
            XCTAssertEqual(
                error as? FileDigestValidationError,
                .invalidByteCount(actualByteCount: 31, requiredByteCount: 32)
            )
        }
        XCTAssertThrowsError(
            try FileDigest(bytes: Data(repeating: 0x7f, count: 33))
        ) { error in
            XCTAssertEqual(
                error as? FileDigestValidationError,
                .invalidByteCount(actualByteCount: 33, requiredByteCount: 32)
            )
        }
    }

    func testFileBookmarkRequiresNonemptyData() throws {
        let bookmark = try FileBookmark(data: Data([0x01]))

        XCTAssertEqual(bookmark.data, Data([0x01]))
        XCTAssertThrowsError(try FileBookmark(data: Data())) { error in
            XCTAssertEqual(error as? FileBookmarkValidationError, .empty)
        }
    }

    func testBoundSaveProducesCleanFileBackedDocument() throws {
        let state = try makeEditedState(text: "First\r\nSecond")
        let encodedFile = try encodeNewTextFile(text: state.activeTab.document.text)
        let fileName = try ValidatedFileName(validating: "List.txt")
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/tmp/List.txt"),
            bookmark: try FileBookmark(data: Data([0x01, 0x02])),
            displayName: fileName,
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )

        let savedState = try markActiveDocumentSavedToBoundFile(
            state: state,
            encodedFile: encodedFile,
            fileBinding: binding
        )

        XCTAssertEqual(savedState.activeTab.document.title, "List.txt")
        XCTAssertEqual(savedState.activeTab.document.text, "First\nSecond")
        XCTAssertEqual(savedState.activeTab.document.fileBinding, binding)
        XCTAssertFalse(savedState.activeTab.document.isUnsaved)
        XCTAssertEqual(savedState.activeTab.document.recoveryState, .clean)
    }

    func testDetachedSaveProducesCleanDocumentWithoutFileBinding() throws {
        let state = try makeEditedState(text: "Saved output")
        let encodedFile = try encodeNewTextFile(text: state.activeTab.document.text)
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/tmp/Previous.txt"),
            bookmark: try FileBookmark(data: Data([0x03])),
            displayName: try ValidatedFileName(validating: "Previous.txt"),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
        let boundState = try markActiveDocumentSavedToBoundFile(
            state: state,
            encodedFile: encodedFile,
            fileBinding: binding
        )
        let editedBoundState = try beginActiveDocumentEdit(
            state: boundState,
            newText: "Saved output",
            editedAt: Date(timeIntervalSince1970: 1_786_646_500)
        ).state
        let fileName = try ValidatedFileName(validating: "Detached.txt")

        let savedState = try markActiveDocumentSavedToDetachedFile(
            state: editedBoundState,
            encodedFile: encodedFile,
            fileName: fileName
        )

        XCTAssertEqual(savedState.activeTab.document.title, "Detached.txt")
        XCTAssertEqual(savedState.activeTab.document.text, "Saved output")
        XCTAssertNil(savedState.activeTab.document.fileBinding)
        XCTAssertFalse(savedState.activeTab.document.isUnsaved)
        XCTAssertEqual(savedState.activeTab.document.recoveryState, .clean)
    }

    func testEditingBoundDocumentPreservesFileBinding() throws {
        let state = try makeEditedState(text: "First")
        let encodedFile = try encodeNewTextFile(text: state.activeTab.document.text)
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/tmp/Bound.txt"),
            bookmark: try FileBookmark(data: Data([0x02])),
            displayName: try ValidatedFileName(validating: "Bound.txt"),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
        let savedState = try markActiveDocumentSavedToBoundFile(
            state: state,
            encodedFile: encodedFile,
            fileBinding: binding
        )

        let editTransition = try beginActiveDocumentEdit(
            state: savedState,
            newText: "Second",
            editedAt: Date(timeIntervalSince1970: 1_786_646_400)
        )
        let protectedState = try markActiveDocumentRecoveryProtected(
            state: editTransition.state
        )

        XCTAssertEqual(editTransition.state.activeTab.document.fileBinding, binding)
        XCTAssertEqual(protectedState.activeTab.document.fileBinding, binding)
    }

    private func assertInvalidFileName(
        _ value: String,
        expectedError: FileNameValidationError
    ) {
        XCTAssertThrowsError(try ValidatedFileName(validating: value)) { error in
            XCTAssertEqual(error as? FileNameValidationError, expectedError)
        }
    }

    private func makeEditedState(text: String) throws -> PhonePadState {
        let state = makeInitialPhonePadState(
            documentID: DocumentID(
                rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
            ),
            tabID: TabID(
                rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
            )
        )
        return try beginActiveDocumentEdit(
            state: state,
            newText: text,
            editedAt: Date(timeIntervalSince1970: 1_786_646_400)
        ).state
    }
}
