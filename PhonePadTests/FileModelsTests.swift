import Foundation
import XCTest
@testable import PhonePadCore

final class FileModelsTests: XCTestCase {
    func testFileIdentityRoundTripsThroughJSONWithoutLosingStableProviderValues() throws {
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 42
        )

        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(FileIdentity.self, from: encoded)

        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(Set([decoded, identity]).count, 1)
    }

    func testFileIdentityRejectsMalformedPersistedValues() {
        let malformedUUID = Data(
            #"{"volumeUUID":"not-a-uuid","documentIdentifier":42}"#.utf8
        )
        let nonintegralIdentifier = Data(
            #"{"volumeUUID":"51000000-0000-0000-0000-000000000001","documentIdentifier":4.2}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(FileIdentity.self, from: malformedUUID)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(FileIdentity.self, from: nonintegralIdentifier)
        )
    }

    func testRecoveryFileReferenceRoundTripsWithoutPersistingRawLocator() throws {
        let encodedFile = try encodeNewTextFile(text: "Bound content")
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "52000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 73
        )
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/private/provider/Folder/Plan.txt"),
            bookmark: try FileBookmark(data: Data([0x01, 0x02, 0x03])),
            identity: identity,
            displayName: try ValidatedFileName(validating: "Plan.txt"),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )

        let reference = makeRecoveryFileReference(fileBinding: binding)
        let persistedData = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(
            RecoveryFileReference.self,
            from: persistedData
        )
        let persistedJSON = String(decoding: persistedData, as: UTF8.self)

        XCTAssertEqual(decoded, reference)
        XCTAssertEqual(reference.bookmark, binding.bookmark)
        XCTAssertEqual(reference.identity, identity)
        XCTAssertEqual(reference.displayName, binding.displayName)
        XCTAssertEqual(reference.cleanDigest, encodedFile.digest)
        XCTAssertEqual(reference.encoding, .utf8)
        XCTAssertEqual(reference.lineEnding, .lf)
        XCTAssertFalse(persistedJSON.contains("locatorURL"))
        XCTAssertFalse(persistedJSON.contains("/private/provider"))
    }

    func testLegacyRecoveryEnvelopeDecodesWithoutBoundFileMetadata() throws {
        let legacyData = Data(
            #"{"formatVersion":1,"documentID":{"rawValue":"58000000-0000-0000-0000-000000000001"},"title":"Legacy Draft","text":"Preserved legacy content","editedAt":0}"#.utf8
        )

        let envelope = try JSONDecoder().decode(
            RecoveryEnvelope.self,
            from: legacyData
        )

        XCTAssertEqual(
            envelope.documentID,
            DocumentID(
                rawValue: UUID(uuidString: "58000000-0000-0000-0000-000000000001")!
            )
        )
        XCTAssertEqual(envelope.title, "Legacy Draft")
        XCTAssertEqual(envelope.text, "Preserved legacy content")
        XCTAssertNil(envelope.fileReference)
        XCTAssertNil(envelope.pendingSave)
    }

    func testPendingBoundSaveRoundTripsWithIntendedDigestAndDurableDestination() throws {
        let binding = try makeBinding(
            path: "/private/provider/Plan.txt",
            bookmarkByte: 0x61,
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "59000000-0000-0000-0000-000000000001")!,
                documentIdentifier: 139
            ),
            text: "Clean content"
        )
        let intendedOutput = try encodeNewTextFile(text: "Intended output")
        let reference = makeRecoveryFileReference(fileBinding: binding)
        let pendingSave = RecoveryPendingSave(
            intendedOutputDigest: intendedOutput.digest
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: DocumentID(rawValue: UUID()),
            title: "Plan.txt",
            text: intendedOutput.text,
            editedAt: Date(timeIntervalSince1970: 1_786_646_700),
            fileReference: reference,
            pendingSave: pendingSave
        )

        let persistedData = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            RecoveryEnvelope.self,
            from: persistedData
        )

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.fileReference, reference)
        XCTAssertEqual(
            decoded.pendingSave?.intendedOutputDigest,
            intendedOutput.digest
        )
        XCTAssertFalse(
            String(decoding: persistedData, as: UTF8.self)
                .contains("/private/provider")
        )
    }

    func testPendingSaveWithoutDurableFileReferenceIsRejected() throws {
        let pendingSave = RecoveryPendingSave(
            intendedOutputDigest: try encodeNewTextFile(text: "Intended output").digest
        )

        XCTAssertThrowsError(
            try RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: DocumentID(rawValue: UUID()),
                title: "Plan.txt",
                text: "Intended output",
                editedAt: Date(timeIntervalSince1970: 1_786_646_700),
                fileReference: nil,
                pendingSave: pendingSave
            )
        ) { error in
            XCTAssertEqual(
                error as? RecoveryEnvelopeValidationError,
                .pendingSaveRequiresFileReference
            )
        }
    }

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
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ValidatedFileName.self,
                from: JSONEncoder().encode("Folder/List.txt")
            )
        ) { error in
            XCTAssertEqual(error as? FileNameValidationError, .multipleComponents)
        }
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

    func testEditNormalizesLineEndingsInStateAndRecoveryCheckpoint() throws {
        let state = makeInitialPhonePadState(
            documentID: DocumentID(
                rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000011")!
            ),
            tabID: TabID(
                rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000012")!
            )
        )

        let transition = try beginActiveDocumentEdit(
            state: state,
            newText: "One\r\nTwo\rThree",
            editedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )

        XCTAssertEqual(transition.state.activeTab.document.text, "One\nTwo\nThree")
        XCTAssertEqual(transition.envelope.text, "One\nTwo\nThree")
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
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FileDigest.self,
                from: JSONEncoder().encode(Data(repeating: 0x7f, count: 31))
            )
        ) { error in
            XCTAssertEqual(
                error as? FileDigestValidationError,
                .invalidByteCount(actualByteCount: 31, requiredByteCount: 32)
            )
        }
    }

    func testFileBookmarkRequiresNonemptyData() throws {
        let bookmark = try FileBookmark(data: Data([0x01]))

        XCTAssertEqual(bookmark.data, Data([0x01]))
        XCTAssertThrowsError(try FileBookmark(data: Data())) { error in
            XCTAssertEqual(error as? FileBookmarkValidationError, .empty)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FileBookmark.self,
                from: JSONEncoder().encode(Data())
            )
        ) { error in
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

    func testFirstBoundFileEditCheckpointsDurableReferenceWithoutPendingSave() throws {
        let state = try makeEditedState(text: "Clean content")
        let encodedFile = try encodeNewTextFile(text: state.activeTab.document.text)
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/private/provider/Bound.txt"),
            bookmark: try FileBookmark(data: Data([0x71, 0x72])),
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "53000000-0000-0000-0000-000000000001")!,
                documentIdentifier: 84
            ),
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

        let transition = try beginActiveDocumentEdit(
            state: savedState,
            newText: "Unsaved content",
            editedAt: Date(timeIntervalSince1970: 1_786_646_600)
        )
        let expectedReference = makeRecoveryFileReference(fileBinding: binding)

        XCTAssertEqual(
            transition.state.activeTab.document.recoveryFileReference,
            expectedReference
        )
        XCTAssertEqual(transition.envelope.fileReference, expectedReference)
        XCTAssertNil(transition.envelope.pendingSave)
    }

    func testRecoveredBoundEditRetainsDurableReferenceWithoutAssumingLocator() throws {
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let binding = try makeBinding(
            path: "/private/provider/Plan.txt",
            bookmarkByte: 0x75,
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "53500000-0000-0000-0000-000000000001")!,
                documentIdentifier: 89
            ),
            text: "Clean content"
        )
        let reference = makeRecoveryFileReference(fileBinding: binding)
        let recoveredDocumentID = DocumentID(rawValue: UUID())
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: recoveredDocumentID,
            title: "Plan.txt",
            text: "Unsaved recovered content",
            editedAt: Date(timeIntervalSince1970: 1_786_646_650),
            fileReference: reference,
            pendingSave: nil
        )

        let recoveredState = recoverDocument(
            state: initialState,
            envelope: envelope,
            tabID: TabID(rawValue: UUID())
        )

        XCTAssertEqual(recoveredState.activeTab.document.id, recoveredDocumentID)
        XCTAssertNil(recoveredState.activeTab.document.fileBinding)
        XCTAssertEqual(
            recoveredState.activeTab.document.recoveryFileReference,
            reference
        )
    }

    func testManualOpenReplacesOnlyPristineUntitledWithCleanBoundDocument() throws {
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(
                rawValue: UUID(uuidString: "54000000-0000-0000-0000-000000000001")!
            ),
            tabID: TabID(
                rawValue: UUID(uuidString: "54000000-0000-0000-0000-000000000002")!
            )
        )
        let openedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "54000000-0000-0000-0000-000000000003")!
        )
        let openedTabID = TabID(
            rawValue: UUID(uuidString: "54000000-0000-0000-0000-000000000004")!
        )
        let encodedFile = try encodeNewTextFile(text: "Opened content")
        let binding = FileBinding(
            locatorURL: URL(fileURLWithPath: "/private/provider/Opened.txt"),
            bookmark: try FileBookmark(data: Data([0x81])),
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "54000000-0000-0000-0000-000000000005")!,
                documentIdentifier: 95
            ),
            displayName: try ValidatedFileName(validating: "Opened.txt"),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )

        let openedState = openBoundDocument(
            state: initialState,
            documentID: openedDocumentID,
            tabID: openedTabID,
            text: encodedFile.text,
            fileBinding: binding
        )

        XCTAssertEqual(openedState.tabs.count, 1)
        XCTAssertEqual(openedState.activeTabID, openedTabID)
        XCTAssertEqual(openedState.activeTab.document.id, openedDocumentID)
        XCTAssertEqual(openedState.activeTab.document.title, "Opened.txt")
        XCTAssertEqual(openedState.activeTab.document.text, "Opened content")
        XCTAssertEqual(openedState.activeTab.document.fileBinding, binding)
        XCTAssertEqual(
            openedState.activeTab.document.recoveryFileReference,
            makeRecoveryFileReference(fileBinding: binding)
        )
        XCTAssertFalse(openedState.activeTab.document.isUnsaved)
        XCTAssertEqual(openedState.activeTab.document.recoveryState, .clean)
    }

    func testManualOpenActivatesExistingTabForSameStableFileIdentity() throws {
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let sharedIdentity = FileIdentity(
            volumeUUID: UUID(uuidString: "55000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 106
        )
        let firstBinding = try makeBinding(
            path: "/private/provider/Original.txt",
            bookmarkByte: 0x91,
            identity: sharedIdentity,
            text: "Original tab"
        )
        let firstTabID = TabID(
            rawValue: UUID(uuidString: "55000000-0000-0000-0000-000000000002")!
        )
        let firstOpen = openBoundDocument(
            state: initialState,
            documentID: DocumentID(rawValue: UUID()),
            tabID: firstTabID,
            text: "Original tab",
            fileBinding: firstBinding
        )
        let secondBinding = try makeBinding(
            path: "/private/provider/Other.txt",
            bookmarkByte: 0x92,
            identity: FileIdentity(
                volumeUUID: sharedIdentity.volumeUUID,
                documentIdentifier: 107
            ),
            text: "Other tab"
        )
        let secondOpen = openBoundDocument(
            state: firstOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Other tab",
            fileBinding: secondBinding
        )
        let movedBinding = try makeBinding(
            path: "/private/provider/Moved.txt",
            bookmarkByte: 0x93,
            identity: sharedIdentity,
            text: "Changed external content must not replace open state"
        )

        let duplicateOpen = openBoundDocument(
            state: secondOpen,
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: "Changed external content must not replace open state",
            fileBinding: movedBinding
        )

        XCTAssertEqual(duplicateOpen.tabs.count, 2)
        XCTAssertEqual(duplicateOpen.activeTabID, firstTabID)
        XCTAssertEqual(duplicateOpen.activeTab.document.text, "Original tab")
        XCTAssertEqual(duplicateOpen.activeTab.document.fileBinding, firstBinding)
    }

    func testBoundFileMatchingUsesStableIdentityAcrossLocatorMove() throws {
        let identity = FileIdentity(
            volumeUUID: UUID(uuidString: "56000000-0000-0000-0000-000000000001")!,
            documentIdentifier: 117
        )
        let original = try makeBinding(
            path: "/private/provider/Original.txt",
            bookmarkByte: 0xa1,
            identity: identity,
            text: "Clean content"
        )
        let moved = try makeBinding(
            path: "/private/provider/Moved.txt",
            bookmarkByte: 0xa2,
            identity: identity,
            text: "Clean content"
        )

        XCTAssertTrue(
            fileBindingsReferToSameFile(existing: original, candidate: moved)
        )
    }

    func testBoundFileMatchingUsesStandardizedLocatorWhenBothIdentitiesAreAbsent() throws {
        let existing = try makeBinding(
            path: "/private/provider/Folder/../Plan.txt",
            bookmarkByte: 0xb1,
            identity: nil,
            text: "Clean content"
        )
        let candidate = try makeBinding(
            path: "/private/provider/Plan.txt",
            bookmarkByte: 0xb2,
            identity: nil,
            text: "Clean content"
        )

        XCTAssertTrue(
            fileBindingsReferToSameFile(existing: existing, candidate: candidate)
        )
    }

    func testBoundFileMatchingRejectsOneSidedIdentityEvenAtSameLocator() throws {
        let path = "/private/provider/Plan.txt"
        let identified = try makeBinding(
            path: path,
            bookmarkByte: 0xc1,
            identity: FileIdentity(
                volumeUUID: UUID(uuidString: "57000000-0000-0000-0000-000000000001")!,
                documentIdentifier: 128
            ),
            text: "Clean content"
        )
        let unidentified = try makeBinding(
            path: path,
            bookmarkByte: 0xc2,
            identity: nil,
            text: "Clean content"
        )

        XCTAssertFalse(
            fileBindingsReferToSameFile(existing: identified, candidate: unidentified)
        )
        XCTAssertFalse(
            fileBindingsReferToSameFile(existing: unidentified, candidate: identified)
        )
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

    private func makeBinding(
        path: String,
        bookmarkByte: UInt8,
        identity: FileIdentity?,
        text: String
    ) throws -> FileBinding {
        let encodedFile = try encodeNewTextFile(text: text)
        return FileBinding(
            locatorURL: URL(fileURLWithPath: path),
            bookmark: try FileBookmark(data: Data([bookmarkByte])),
            identity: identity,
            displayName: try ValidatedFileName(
                validating: URL(fileURLWithPath: path).lastPathComponent
            ),
            digest: encodedFile.digest,
            encoding: encodedFile.encoding,
            lineEnding: encodedFile.lineEnding
        )
    }
}
