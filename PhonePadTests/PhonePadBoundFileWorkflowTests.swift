import Foundation
import XCTest

@testable import PhonePad
@testable import PhonePadCore

final class PhonePadBoundFileWorkflowTests: XCTestCase {
    func testBoundSavePreservesRepresentativeEncodingsAndLineEndings() async throws {
        let cases: [BoundFileEncodingCase] = [
            BoundFileEncodingCase(
                fileName: "UTF8-BOM-CRLF.txt",
                sourceBytes: Data([0xef, 0xbb, 0xbf, 0x41, 0x0d, 0x0a, 0x42, 0x0d, 0x0a]),
                editedText: "Café\nLine\n",
                expectedBytes: Data([
                    0xef, 0xbb, 0xbf,
                    0x43, 0x61, 0x66, 0xc3, 0xa9,
                    0x0d, 0x0a,
                    0x4c, 0x69, 0x6e, 0x65,
                    0x0d, 0x0a,
                ]),
                expectedEncoding: .utf8WithBOM,
                expectedLineEnding: .crlf
            ),
            BoundFileEncodingCase(
                fileName: "UTF16-LE-CR.txt",
                sourceBytes: Data([
                    0xff, 0xfe,
                    0x41, 0x00,
                    0x0d, 0x00,
                    0x42, 0x00,
                ]),
                editedText: "Snow ☃\nNext",
                expectedBytes: Data([
                    0xff, 0xfe,
                    0x53, 0x00, 0x6e, 0x00, 0x6f, 0x00, 0x77, 0x00, 0x20, 0x00,
                    0x03, 0x26,
                    0x0d, 0x00,
                    0x4e, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00,
                ]),
                expectedEncoding: .utf16LittleEndianWithBOM,
                expectedLineEnding: .cr
            ),
            BoundFileEncodingCase(
                fileName: "UTF16-BE-LF.txt",
                sourceBytes: Data([
                    0xfe, 0xff,
                    0x00, 0x41,
                    0x00, 0x0a,
                    0x00, 0x42,
                ]),
                editedText: "Café\nLine",
                expectedBytes: Data([
                    0xfe, 0xff,
                    0x00, 0x43, 0x00, 0x61, 0x00, 0x66, 0x00, 0xe9,
                    0x00, 0x0a,
                    0x00, 0x4c, 0x00, 0x69, 0x00, 0x6e, 0x00, 0x65,
                ]),
                expectedEncoding: .utf16BigEndianWithBOM,
                expectedLineEnding: .lf
            ),
            BoundFileEncodingCase(
                fileName: "Windows-1252-CR.txt",
                sourceBytes: Data([0x43, 0x61, 0x66, 0xe9, 0x0d, 0x42]),
                editedText: "Euro €\nNext",
                expectedBytes: Data([
                    0x45, 0x75, 0x72, 0x6f, 0x20, 0x80,
                    0x0d,
                    0x4e, 0x65, 0x78, 0x74,
                ]),
                expectedEncoding: .windows1252,
                expectedLineEnding: .cr
            ),
            BoundFileEncodingCase(
                fileName: "ISO-8859-1-LF.txt",
                sourceBytes: Data([0x41, 0x81, 0x0a]),
                editedText: "A\u{0081}\nB",
                expectedBytes: Data([0x41, 0x81, 0x0a, 0x42]),
                expectedEncoding: .iso88591,
                expectedLineEnding: .lf
            ),
        ]

        for fixtureCase in cases {
            let fixture = try makeFixture(
                fileName: fixtureCase.fileName,
                sourceBytes: fixtureCase.sourceBytes
            )
            let connector = FileAccessConnector(fileManager: .default)
            let openedState = try await openState(
                sourceURL: fixture.sourceURL,
                connector: connector
            )
            XCTAssertEqual(
                openedState.activeTab.document.fileBinding?.encoding,
                fixtureCase.expectedEncoding
            )
            XCTAssertEqual(
                openedState.activeTab.document.fileBinding?.lineEnding,
                fixtureCase.expectedLineEnding
            )
            let editedState = try await editActiveDocumentAndCheckpoint(
                state: openedState,
                newText: fixtureCase.editedText,
                editedAt: Date(timeIntervalSince1970: 1_770_100_100),
                recoveryStore: fixture.recoveryStore
            )
            let preparedSave = try prepareBoundFileSave(
                state: editedState,
                recoveryEditedAt: Date(timeIntervalSince1970: 1_770_100_200)
            )

            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixtureCase.sourceBytes)
            XCTAssertEqual(preparedSave.encodedFile.data, fixtureCase.expectedBytes)

            let result = try await savePreparedBoundDocument(
                state: editedState,
                preparedSave: preparedSave,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )

            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixtureCase.expectedBytes)
            XCTAssertEqual(
                result.state.activeTab.document.fileBinding?.encoding,
                fixtureCase.expectedEncoding
            )
            XCTAssertEqual(
                result.state.activeTab.document.fileBinding?.lineEnding,
                fixtureCase.expectedLineEnding
            )
            XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        }
    }

    func testUnrepresentableBoundSaveKeepsOriginalAndProtectedRecovery() async throws {
        let sourceBytes = Data([0x43, 0x61, 0x66, 0xe9, 0x0a])
        let fixture = try makeFixture(
            fileName: "Windows-1252.txt",
            sourceBytes: sourceBytes
        )
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Emoji 😀\n",
            editedAt: Date(timeIntervalSince1970: 1_770_100_300),
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertThrowsError(
            try prepareBoundFileSave(
                state: editedState,
                recoveryEditedAt: Date(timeIntervalSince1970: 1_770_100_400)
            )
        ) { error in
            XCTAssertNotNil(error as? TextFileEncodingError)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), sourceBytes)
        XCTAssertTrue(editedState.activeTab.document.isUnsaved)
        let recovery = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertEqual(recovery?.text, "Emoji 😀\n")
        XCTAssertEqual(recovery?.fileReference?.encoding, .windows1252)
    }

    func testOversizedBoundEncodingKeepsOriginalAndProtectedRecovery() async throws {
        let sourceBytes = Data([0xff, 0xfe, 0x41, 0x00, 0x0a, 0x00])
        let fixture = try makeFixture(
            fileName: "UTF16-LE.txt",
            sourceBytes: sourceBytes
        )
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let validUTF8ButOversizedUTF16 = String(
            repeating: "a",
            count: maximumSupportedTextFileByteCount / 2 + 1
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: validUTF8ButOversizedUTF16,
            editedAt: Date(timeIntervalSince1970: 1_770_100_500),
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertThrowsError(
            try prepareBoundFileSave(
                state: editedState,
                recoveryEditedAt: Date(timeIntervalSince1970: 1_770_100_600)
            )
        ) { error in
            XCTAssertNotNil(error as? TextFileEncodingError)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), sourceBytes)
        XCTAssertTrue(editedState.activeTab.document.isUnsaved)
        let recovery = try await fixture.recoveryStore.load(
            documentID: editedState.activeTab.document.id
        )
        XCTAssertEqual(recovery?.text.count, validUTF8ButOversizedUTF16.count)
        XCTAssertEqual(
            recovery?.fileReference?.encoding,
            .utf16LittleEndianWithBOM
        )
    }

    func testProtectBoundSavePersistsPendingIntentBeforeOriginalFileChanges() async throws {
        let fixture = try makeFixture(originalText: "Original\n")
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Changed\n",
            editedAt: Date(timeIntervalSince1970: 1_770_000_100),
            recoveryStore: fixture.recoveryStore
        )
        let preparedSave = try prepareBoundFileSave(
            state: editedState,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_770_000_200)
        )

        let protectedState = try await protectPreparedBoundFileSave(
            state: editedState,
            preparedSave: preparedSave,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), Data("Original\n".utf8))
        XCTAssertEqual(
            protectedState.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let loadedEnvelope = try await fixture.recoveryStore.load(
            documentID: protectedState.activeTab.document.id
        )
        let envelope = try XCTUnwrap(loadedEnvelope)
        XCTAssertEqual(envelope.text, "Changed\n")
        XCTAssertEqual(
            envelope.fileReference,
            makeRecoveryFileReference(
                fileBinding: try XCTUnwrap(
                    protectedState.activeTab.document.fileBinding
                )
            )
        )
        XCTAssertEqual(
            envelope.pendingSave?.intendedOutputDigest,
            preparedSave.encodedFile.digest
        )
    }

    func testExplicitBoundSaveWritesVerifiedBytesAndTerminatesRecovery() async throws {
        let fixture = try makeFixture(originalText: "Original\n")
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "Saved text\n",
            editedAt: Date(timeIntervalSince1970: 1_770_000_300),
            recoveryStore: fixture.recoveryStore
        )
        let preparedSave = try prepareBoundFileSave(
            state: editedState,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_770_000_400)
        )

        let result = try await savePreparedBoundDocument(
            state: editedState,
            preparedSave: preparedSave,
            fileAccessConnector: connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), Data("Saved text\n".utf8))
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertNotNil(result.state.activeTab.document.fileBinding)
        XCTAssertNil(result.notice)
        let recovery = try await fixture.recoveryStore.load(
            documentID: result.state.activeTab.document.id
        )
        XCTAssertNil(recovery)
    }

    func testExternalChangeBlocksBoundSaveAndRetainsPendingRecovery() async throws {
        let fixture = try makeFixture(originalText: "Original\n")
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: "PhonePad edit\n",
            editedAt: Date(timeIntervalSince1970: 1_770_000_500),
            recoveryStore: fixture.recoveryStore
        )
        let preparedSave = try prepareBoundFileSave(
            state: editedState,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_770_000_600)
        )
        let protectedState = try await protectPreparedBoundFileSave(
            state: editedState,
            preparedSave: preparedSave,
            recoveryStore: fixture.recoveryStore
        )
        let externalBytes = Data("External edit\n".utf8)
        try externalBytes.write(to: fixture.sourceURL, options: .atomic)

        let saveError = await capturedError {
            _ = try await saveProtectedBoundDocument(
                state: protectedState,
                preparedSave: preparedSave,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
        }

        XCTAssertNotNil(saveError)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), externalBytes)
        XCTAssertTrue(protectedState.activeTab.document.isUnsaved)
        let loadedEnvelope = try await fixture.recoveryStore.load(
            documentID: protectedState.activeTab.document.id
        )
        let envelope = try XCTUnwrap(loadedEnvelope)
        XCTAssertEqual(envelope.text, "PhonePad edit\n")
        XCTAssertEqual(
            envelope.pendingSave?.intendedOutputDigest,
            preparedSave.encodedFile.digest
        )
    }

    func testKnownFileConflictBlocksBoundSaveBeforeRecoveryOrFileWrite() async throws {
        let originalBytes = Data("Original\n".utf8)
        let fixture = try makeFixture(
            fileName: "Conflicted.txt",
            sourceBytes: originalBytes
        )
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedState = try beginActiveDocumentEdit(
            state: openedState,
            newText: "Protected local edit\n",
            editedAt: Date(timeIntervalSince1970: 1_770_000_650)
        ).state
        let preparedSave = try prepareBoundFileSave(
            state: editedState,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_770_000_660)
        )
        let conflictedState = try markDocumentFileConflict(
            state: editedState,
            documentID: editedState.activeTab.document.id,
            conflict: .contentChanged
        )

        let saveError = await capturedError {
            _ = try await savePreparedBoundDocument(
                state: conflictedState,
                preparedSave: preparedSave,
                fileAccessConnector: connector,
                recoveryStore: fixture.recoveryStore
            )
        }

        XCTAssertEqual(
            saveError as? SavedDocumentTransitionError,
            .fileConflictRequiresExplicitResolution(.contentChanged)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalBytes)
        let storedRecovery = try await fixture.recoveryStore.load(
            documentID: conflictedState.activeTab.document.id
        )
        XCTAssertNil(storedRecovery)
        XCTAssertEqual(
            conflictedState.activeTab.document.text,
            "Protected local edit\n"
        )
        XCTAssertEqual(
            conflictedState.activeTab.document.fileConflict,
            .contentChanged
        )
    }

    func testRecoveryFailurePreventsBoundFileWrite() async throws {
        let fixture = try makeFixture(originalText: "Original\n")
        let connector = FileAccessConnector(fileManager: .default)
        let openedState = try await openState(
            sourceURL: fixture.sourceURL,
            connector: connector
        )
        let editedTransition = try beginActiveDocumentEdit(
            state: openedState,
            newText: "Must remain protected in memory\n",
            editedAt: Date(timeIntervalSince1970: 1_770_000_700)
        )
        let preparedSave = try prepareBoundFileSave(
            state: editedTransition.state,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_770_000_800)
        )
        let blockedRootURL = fixture.rootURL.appendingPathComponent(
            "recovery-blocker",
            isDirectory: false
        )
        try Data("not a directory".utf8).write(
            to: blockedRootURL,
            options: .withoutOverwriting
        )
        let blockedStore = FileRecoveryStore(
            rootURL: blockedRootURL,
            fileManager: .default
        )

        let saveError = await capturedError {
            _ = try await savePreparedBoundDocument(
                state: editedTransition.state,
                preparedSave: preparedSave,
                fileAccessConnector: connector,
                recoveryStore: blockedStore
            )
        }

        XCTAssertNotNil(saveError)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), Data("Original\n".utf8))
    }

    private func makeFixture(originalText: String) throws -> BoundFileFixture {
        try makeFixture(
            fileName: "Source.txt",
            sourceBytes: Data(originalText.utf8)
        )
    }

    private func makeFixture(
        fileName: String,
        sourceBytes: Data
    ) throws -> BoundFileFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        let sourceURL = rootURL.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        try sourceBytes.write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let recoveryRootURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        return BoundFileFixture(
            rootURL: rootURL,
            sourceURL: sourceURL,
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryRootURL,
                fileManager: .default
            )
        )
    }

    private func openState(
        sourceURL: URL,
        connector: FileAccessConnector
    ) async throws -> PhonePadState {
        let documentID = DocumentID(rawValue: UUID())
        let openedSnapshot = try await connector.openTextFile(
            at: sourceURL,
            documentID: documentID
        )
        return openObservedBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: openedSnapshot.openedFile.text,
            observation: ObservedBoundFile(
                binding: openedSnapshot.openedFile.binding,
                providerConflictVersions: openedSnapshot.providerConflictVersions
            )
        )
    }
}

private struct BoundFileEncodingCase {
    let fileName: String
    let sourceBytes: Data
    let editedText: String
    let expectedBytes: Data
    let expectedEncoding: TextFileEncoding
    let expectedLineEnding: TextLineEnding
}

private struct BoundFileFixture {
    let rootURL: URL
    let sourceURL: URL
    let recoveryStore: FileRecoveryStore
}

private func capturedError(
    _ expression: () async throws -> Void
) async -> Error? {
    do {
        try await expression()
        return nil
    } catch {
        return error
    }
}
