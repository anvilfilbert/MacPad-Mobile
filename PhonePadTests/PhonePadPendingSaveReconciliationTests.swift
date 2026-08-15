import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadPendingSaveReconciliationTests: XCTestCase {
    func testIntendedBoundOutputCompletesAuthorizedRecoveryCleanup() async throws {
        let fixture = try await makePendingSaveFixture(
            cleanText: "Original\n",
            intendedText: "Saved edits\n",
            observedText: "Saved edits\n"
        )

        let items = try await reconcilePendingSaveRecoveryItems(
            recoveryStore: fixture.store,
            fileAccessConnector: fixture.connector
        )

        XCTAssertEqual(items, [])
        let storedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNil(storedEnvelope)
    }

    func testCleanBoundOutputRemainsRecoverable() async throws {
        let fixture = try await makePendingSaveFixture(
            cleanText: "Original\n",
            intendedText: "Unsaved edits\n",
            observedText: "Original\n"
        )

        let items = try await reconcilePendingSaveRecoveryItems(
            recoveryStore: fixture.store,
            fileAccessConnector: fixture.connector
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].documentID, fixture.documentID)
        XCTAssertEqual(items[0].status, .recoverable)
        let storedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNotNil(storedEnvelope)
    }

    func testUnexpectedBoundOutputRemainsVisibleAsUnresolved() async throws {
        let fixture = try await makePendingSaveFixture(
            cleanText: "Original\n",
            intendedText: "Unsaved edits\n",
            observedText: "Provider replacement\n"
        )

        let items = try await reconcilePendingSaveRecoveryItems(
            recoveryStore: fixture.store,
            fileAccessConnector: fixture.connector
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].documentID, fixture.documentID)
        XCTAssertEqual(items[0].status, .saveResultUnresolved)
        let storedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNotNil(storedEnvelope)
    }

    func testUnresolvedSaveResultCanBeExplicitlyRecovered() async throws {
        let fixture = try await makePendingSaveFixture(
            cleanText: "Original\n",
            intendedText: "Unsaved edits\n",
            observedText: "Provider replacement\n"
        )
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let model = PhonePadAppModel(
            state: initialState,
            recoveryStore: fixture.store,
            fileAccessConnector: fixture.connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        await model.refreshRecoveryItems()
        let recovered = await model.recoverRecovery(
            documentID: fixture.documentID,
            after: CommittedEditorDocument(
                documentID: initialState.activeTab.document.id,
                text: initialState.activeTab.document.text
            )
        )

        XCTAssertEqual(model.recoveryItems, [])
        XCTAssertTrue(recovered)
        XCTAssertEqual(model.state.activeTab.document.id, fixture.documentID)
        XCTAssertEqual(model.state.activeTab.document.text, "Unsaved edits\n")
        let storedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNotNil(storedEnvelope?.pendingSave)
    }

    func testUnavailablePendingDestinationRemainsVisibleForRetry() async throws {
        let fixture = try await makePendingSaveFixture(
            cleanText: "Original\n",
            intendedText: "Unsaved edits\n",
            observedText: "Unsaved edits\n"
        )
        let unavailableConnector = makeConnector(bookmarkLocations: [:])

        let items = try await reconcilePendingSaveRecoveryItems(
            recoveryStore: fixture.store,
            fileAccessConnector: unavailableConnector
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].documentID, fixture.documentID)
        XCTAssertEqual(items[0].status, .unavailable)
        let storedEnvelope = try await fixture.store.load(
            documentID: fixture.documentID
        )
        XCTAssertNotNil(storedEnvelope)
    }

    func testIntendedSaveAsOutputCompletesAuthorizedRecoveryCleanup() async throws {
        let recoveryRootURL = try makeTemporaryDirectory()
        let destinationRootURL = try makeTemporaryDirectory()
        let targetURL = destinationRootURL.appendingPathComponent(
            "Saved.txt",
            isDirectory: false
        )
        let intendedFile = try encodeTextFile(
            text: "Saved through Save As\n",
            encoding: .utf8,
            lineEnding: .lf
        )
        try intendedFile.data.write(to: targetURL, options: .withoutOverwriting)
        let sourceBookmark = try FileBookmark(data: Data("source".utf8))
        let directoryBookmark = try FileBookmark(data: Data("directory".utf8))
        let documentID = DocumentID(rawValue: UUID())
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        try await store.save(
            envelope: try RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: documentID,
                title: "Saved.txt",
                text: "Saved through Save As\n",
                editedAt: Date(timeIntervalSince1970: 1_786_700_000),
                fileReference: RecoveryFileReference(
                    bookmark: sourceBookmark,
                    identity: nil,
                    displayName: try ValidatedFileName(validating: "Source.txt"),
                    cleanDigest: try digest(text: "Original\n"),
                    encoding: .utf8,
                    lineEnding: .lf
                ),
                pendingSave: RecoveryPendingSave(
                    intendedOutputDigest: intendedFile.digest,
                    destination: .saveAs(
                        RecoverySaveAsDestination(
                            directoryBookmark: directoryBookmark,
                            fileName: try ValidatedFileName(
                                validating: "Saved.txt"
                            )
                        )
                    )
                )
            )
        )
        let connector = makeConnector(
            bookmarkLocations: [directoryBookmark: destinationRootURL]
        )

        let items = try await reconcilePendingSaveRecoveryItems(
            recoveryStore: store,
            fileAccessConnector: connector
        )

        XCTAssertEqual(items, [])
        let storedEnvelope = try await store.load(documentID: documentID)
        XCTAssertNil(storedEnvelope)
    }

    private func makePendingSaveFixture(
        cleanText: String,
        intendedText: String,
        observedText: String
    ) async throws -> PendingSaveFixture {
        let recoveryRootURL = try makeTemporaryDirectory()
        let fileRootURL = try makeTemporaryDirectory()
        let fileURL = fileRootURL.appendingPathComponent(
            "Bound.txt",
            isDirectory: false
        )
        let observedFile = try encodeTextFile(
            text: observedText,
            encoding: .utf8,
            lineEnding: .lf
        )
        try observedFile.data.write(to: fileURL, options: .withoutOverwriting)
        let bookmark = try FileBookmark(data: Data(UUID().uuidString.utf8))
        let documentID = DocumentID(rawValue: UUID())
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: documentID,
            title: "Bound.txt",
            text: intendedText,
            editedAt: Date(timeIntervalSince1970: 1_786_700_000),
            fileReference: RecoveryFileReference(
                bookmark: bookmark,
                identity: nil,
                displayName: try ValidatedFileName(validating: "Bound.txt"),
                cleanDigest: try digest(text: cleanText),
                encoding: .utf8,
                lineEnding: .lf
            ),
            pendingSave: RecoveryPendingSave(
                intendedOutputDigest: try digest(text: intendedText)
            )
        )
        try await store.save(envelope: envelope)
        return PendingSaveFixture(
            store: store,
            connector: makeConnector(bookmarkLocations: [bookmark: fileURL]),
            documentID: documentID
        )
    }

    private func makeConnector(
        bookmarkLocations: [FileBookmark: URL]
    ) -> FileAccessConnector {
        FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { url in Data(url.path.utf8) },
            bookmarkResolver: { bookmark in
                guard let url = bookmarkLocations[bookmark] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return ResolvedFileBookmark(url: url, isStale: false)
            },
            identityReader: { _ in nil },
            replacer: { _, _, _ in nil }
        )
    }

    private func digest(text: String) throws -> FileDigest {
        try encodeTextFile(
            text: text,
            encoding: .utf8,
            lineEnding: .lf
        ).digest
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private struct PendingSaveFixture {
    let store: FileRecoveryStore
    let connector: FileAccessConnector
    let documentID: DocumentID
}
