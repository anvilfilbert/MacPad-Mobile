import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadRecoveryReattachmentTests: XCTestCase {
    func testLocateOriginalReattachesRecoveredTextAndMarksChangedFileConflict() async throws {
        let fixture = try await makeFixture(
            selectedText: "Changed outside PhonePad\n",
            includeBoundCollision: false,
            isWritable: true
        )

        let located = await fixture.model.locateOriginal(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(located)
        XCTAssertEqual(fixture.model.state.activeTab.document.id, fixture.recoveredDocumentID)
        XCTAssertEqual(fixture.model.state.activeTab.document.text, "Recovered edits\n")
        XCTAssertNotNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.fileConflict,
            .contentChanged
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let envelope = try await fixture.store.load(
            documentID: fixture.recoveredDocumentID
        )
        XCTAssertEqual(
            envelope?.fileReference,
            fixture.model.state.activeTab.document.recoveryFileReference
        )
        XCTAssertNil(envelope?.pendingSave)
    }

    func testLocateOriginalCollisionActivatesExistingFileTabAndKeepsRecoveredTextDetached() async throws {
        let fixture = try await makeFixture(
            selectedText: "Original\n",
            includeBoundCollision: true,
            isWritable: true
        )

        let located = await fixture.model.locateOriginal(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertTrue(located)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            fixture.boundDocumentID
        )
        let recoveredDocument = try XCTUnwrap(
            fixture.model.state.tabs.first(where: { tab in
                tab.document.id == fixture.recoveredDocumentID
            })?.document
        )
        XCTAssertEqual(recoveredDocument.text, "Recovered edits\n")
        XCTAssertNil(recoveredDocument.fileBinding)
        XCTAssertEqual(recoveredDocument.recoveryState, .protectedUnsaved)
        let retainedEnvelope = try await fixture.store.load(
            documentID: fixture.recoveredDocumentID
        )
        XCTAssertNotNil(retainedEnvelope)
    }

    func testLocateOriginalReadOnlySelectionRetainsProtectedDetachedText() async throws {
        let fixture = try await makeFixture(
            selectedText: "Original\n",
            includeBoundCollision: false,
            isWritable: false
        )

        let located = await fixture.model.locateOriginal(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(located)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            fixture.recoveredDocumentID
        )
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            "Recovered edits\n"
        )
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertTrue(
            fixture.model.fileSaveError?.contains("read-only") == true
        )
        XCTAssertTrue(
            fixture.model.fileSaveError?.contains("Save As") == true
        )
        let retainedEnvelope = try await fixture.store.load(
            documentID: fixture.recoveredDocumentID
        )
        XCTAssertNotNil(retainedEnvelope)
    }

    func testLocateOriginalPendingRecoveryCollisionLeavesRecoveredTextDetached() async throws {
        let fixture = try await makeFixture(
            selectedText: "Original\n",
            includeBoundCollision: false,
            isWritable: true
        )
        let collisionDocumentID = DocumentID(rawValue: UUID())
        let reference = try XCTUnwrap(
            fixture.model.state.activeTab.document.recoveryFileReference
        )
        try await fixture.store.save(
            envelope: try RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: collisionDocumentID,
                title: "Other Recovery.txt",
                text: "Other edits\n",
                editedAt: Date(timeIntervalSince1970: 1_786_800_100),
                fileReference: reference,
                pendingSave: nil
            )
        )

        let located = await fixture.model.locateOriginal(
            selectedURL: fixture.fileURL,
            after: committedActiveDocument(model: fixture.model)
        )

        XCTAssertFalse(located)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.id,
            fixture.recoveredDocumentID
        )
        XCTAssertNil(fixture.model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.text,
            "Recovered edits\n"
        )
        XCTAssertTrue(
            fixture.model.fileSaveError?.contains(
                collisionDocumentID.rawValue.uuidString
            ) == true
        )
        let retainedEnvelope = try await fixture.store.load(
            documentID: fixture.recoveredDocumentID
        )
        XCTAssertNotNil(retainedEnvelope)
    }

    private func makeFixture(
        selectedText: String,
        includeBoundCollision: Bool,
        isWritable: Bool
    ) async throws -> RecoveryReattachmentFixture {
        let rootURL = try makeTemporaryDirectory()
        let recoveryRootURL = try makeTemporaryDirectory()
        let fileURL = rootURL.appendingPathComponent(
            "Original.txt",
            isDirectory: false
        )
        try Data(selectedText.utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let bookmark = try FileBookmark(data: Data(fileURL.path.utf8))
        let recoveredDocumentID = DocumentID(rawValue: UUID())
        let boundDocumentID = DocumentID(rawValue: UUID())
        let reference = RecoveryFileReference(
            bookmark: bookmark,
            identity: nil,
            displayName: try ValidatedFileName(validating: "Original.txt"),
            cleanDigest: try decodedFile(text: "Original\n").digest,
            encoding: .utf8,
            lineEnding: .lf
        )
        let envelope = try RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: recoveredDocumentID,
            title: "Original.txt",
            text: "Recovered edits\n",
            editedAt: Date(timeIntervalSince1970: 1_786_800_000),
            fileReference: reference,
            pendingSave: nil
        )
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        try await store.save(envelope: envelope)

        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let baseState: PhonePadState
        if includeBoundCollision {
            let opened = try decodedFile(text: selectedText)
            baseState = openObservedBoundDocument(
                state: initialState,
                documentID: boundDocumentID,
                tabID: TabID(rawValue: UUID()),
                text: opened.text,
                observation: ObservedBoundFile(
                    binding: FileBinding(
                        locatorURL: fileURL,
                        bookmark: bookmark,
                        identity: nil,
                        displayName: try ValidatedFileName(
                            validating: "Original.txt"
                        ),
                        digest: opened.digest,
                        encoding: opened.encoding,
                        lineEnding: opened.lineEnding
                    ),
                    providerConflictVersions: .none
                )
            )
        } else {
            baseState = initialState
        }
        let recoveredState = recoverDocument(
            state: baseState,
            envelope: envelope,
            tabID: TabID(rawValue: UUID())
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { url in Data(url.path.utf8) },
            bookmarkResolver: { bookmark in
                guard let path = String(data: bookmark.data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return ResolvedFileBookmark(
                    url: URL(fileURLWithPath: path),
                    isStale: false
                )
            },
            identityReader: { _ in nil },
            replacer: { _, _, _ in nil },
            fileWritabilityReader: { _ in isWritable },
            applicationInboxURL: nil
        )
        let model = PhonePadAppModel(
            state: recoveredState,
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        return RecoveryReattachmentFixture(
            model: model,
            store: store,
            fileURL: fileURL,
            recoveredDocumentID: recoveredDocumentID,
            boundDocumentID: boundDocumentID
        )
    }

    private func decodedFile(text: String) throws -> DecodedTextFile {
        try decodeSupportedTextFile(data: Data(text.utf8))
    }

    private func committedActiveDocument(
        model: PhonePadAppModel
    ) -> CommittedEditorDocument {
        CommittedEditorDocument(
            documentID: model.state.activeTab.document.id,
            text: model.state.activeTab.document.text
        )
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

private struct RecoveryReattachmentFixture {
    let model: PhonePadAppModel
    let store: FileRecoveryStore
    let fileURL: URL
    let recoveredDocumentID: DocumentID
    let boundDocumentID: DocumentID
}
