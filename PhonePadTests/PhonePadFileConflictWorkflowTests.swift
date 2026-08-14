import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadFileConflictWorkflowTests: XCTestCase {
    func testReloadReadsCurrentFileBeforeDiscardingRecovery() async throws {
        let fixture = try makeFileConflictFixture()
        let prepared = try await makeProtectedFileConflict(
            fixture: fixture,
            localText: "Local protected edit\n",
            externalText: "External current text\n"
        )
        addTeardownBlock {
            await fixture.connector.stopPresenting(
                documentID: prepared.documentID
            )
        }

        let result = try await reloadCurrentFileAfterDiscardingEdits(
            state: prepared.state,
            documentID: prepared.documentID,
            fileAccessConnector: fixture.connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertEqual(result.state.activeTab.document.text, "External current text\n")
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertNil(result.state.activeTab.document.fileConflict)
        XCTAssertFalse(result.recoveryCleanupPending)
        let recoveryAfterReload = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        XCTAssertNil(recoveryAfterReload)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data("External current text\n".utf8)
        )
    }

    func testReloadReadFailureRetainsEditsAndRecovery() async throws {
        let fixture = try makeFileConflictFixture()
        let prepared = try await makeProtectedFileConflict(
            fixture: fixture,
            localText: "Keep local protected edit\n",
            externalText: "Readable external text\n"
        )
        addTeardownBlock {
            await fixture.connector.stopPresenting(
                documentID: prepared.documentID
            )
        }
        let binaryBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        try replaceFileContents(at: fixture.fileURL, with: binaryBytes)

        do {
            _ = try await reloadCurrentFileAfterDiscardingEdits(
                state: prepared.state,
                documentID: prepared.documentID,
                fileAccessConnector: fixture.connector,
                recoveryStore: fixture.recoveryStore
            )
            XCTFail("Unsupported current bytes must block Reload.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(
                error,
                .textDecodingFailed(.unsupportedContent(.rasterImage))
            )
        }

        XCTAssertEqual(
            prepared.state.activeTab.document.text,
            "Keep local protected edit\n"
        )
        XCTAssertEqual(
            prepared.state.activeTab.document.fileConflict,
            .contentChanged
        )
        let retainedRecovery = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        XCTAssertEqual(retainedRecovery?.text, "Keep local protected edit\n")
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), binaryBytes)
    }

    func testReloadCleanupFailureRetainsEditsAndRealStoredRecovery() async throws {
        let fixture = try makeFileConflictFixture()
        let prepared = try await makeProtectedFileConflict(
            fixture: fixture,
            localText: "Retain when cleanup fails\n",
            externalText: "Validated external current\n"
        )
        addTeardownBlock {
            await fixture.connector.stopPresenting(
                documentID: prepared.documentID
            )
        }
        let failingStore = DiscardFailureRecoveryStore(
            recoveryStore: fixture.recoveryStore
        )

        do {
            _ = try await reloadCurrentFileAfterDiscardingEdits(
                state: prepared.state,
                documentID: prepared.documentID,
                fileAccessConnector: fixture.connector,
                recoveryStore: failingStore
            )
            XCTFail("Recovery cleanup failure must block editor replacement.")
        } catch let error as FileConflictWorkflowError {
            guard case .recoveryCleanupFailed = error else {
                return XCTFail("Unexpected conflict workflow error: \(error)")
            }
        }

        XCTAssertEqual(
            prepared.state.activeTab.document.text,
            "Retain when cleanup fails\n"
        )
        XCTAssertEqual(
            prepared.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertEqual(
            prepared.state.activeTab.document.fileConflict,
            .contentChanged
        )
        let retainedRecovery = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        XCTAssertEqual(retainedRecovery?.text, "Retain when cleanup fails\n")
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data("Validated external current\n".utf8)
        )
    }

    func testCurrentFileSaveAsConflictFailsBeforeRecoveryOrFileMutation() async throws {
        let fixture = try makeFileConflictFixture()
        let prepared = try await makeProtectedFileConflict(
            fixture: fixture,
            localText: "Preserve local conflict edit\n",
            externalText: "External current remains\n"
        )
        addTeardownBlock {
            await fixture.connector.stopPresenting(
                documentID: prepared.documentID
            )
        }
        let preparation = try prepareSaveAs(
            state: prepared.state,
            fileName: fixture.fileURL.lastPathComponent,
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_900_100)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: prepared.state,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.fileURL.deletingLastPathComponent(),
            fileAccessConnector: fixture.connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .currentFile = preflight.target else {
            return XCTFail("Selecting the bound File must use current-File Save As.")
        }
        let recoveryBefore = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        let fileBytesBefore = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try await saveCurrentFilePreparedSaveAs(
                state: prepared.state,
                preflight: preflight,
                fileAccessConnector: fixture.connector,
                recoveryStore: fixture.recoveryStore
            )
            XCTFail("File Conflict must block current-File Save As.")
        } catch let error as SaveAsWorkflowError {
            XCTAssertEqual(
                error,
                .currentFileHasConflict(
                    documentID: prepared.documentID,
                    conflict: .contentChanged
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), fileBytesBefore)
        let recoveryAfterBlockedSave = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        XCTAssertEqual(recoveryAfterBlockedSave, recoveryBefore)
        XCTAssertEqual(
            prepared.state.activeTab.document.text,
            "Preserve local conflict edit\n"
        )
    }

    func testDistinctSaveAsPreservesBothVersionsAndClearsConflict() async throws {
        let fixture = try makeFileConflictFixture()
        let prepared = try await makeProtectedFileConflict(
            fixture: fixture,
            localText: "Preserved PhonePad version\n",
            externalText: "External original version\n"
        )
        addTeardownBlock {
            await fixture.connector.stopPresenting(
                documentID: prepared.documentID
            )
        }
        let preparation = try prepareSaveAs(
            state: prepared.state,
            fileName: "Preserved Version.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_900_200)
        )
        let preflight = try await preflightPreparedSaveAs(
            state: prepared.state,
            preparedSave: preparation,
            selectedDirectoryURL: fixture.fileURL.deletingLastPathComponent(),
            fileAccessConnector: fixture.connector,
            recoveryStore: fixture.recoveryStore
        )
        guard case .ready = preflight.target else {
            return XCTFail("Distinct absent target must be ready for Save As.")
        }

        let result = try await saveReadyPreparedSaveAs(
            state: prepared.state,
            preflight: preflight,
            fileAccessConnector: fixture.connector,
            recoveryStore: fixture.recoveryStore
        )

        XCTAssertNil(result.state.activeTab.document.fileConflict)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            try Data(contentsOf: fixture.fileURL),
            Data("External original version\n".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.fileURL.deletingLastPathComponent()
                    .appendingPathComponent("Preserved Version.txt")
            ),
            Data("Preserved PhonePad version\n".utf8)
        )
        let recoveryAfterSaveAs = try await fixture.recoveryStore.load(
            documentID: prepared.documentID
        )
        XCTAssertNil(recoveryAfterSaveAs)
    }

    private func makeFileConflictFixture() throws -> FileConflictWorkflowFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        let fileURL = filesURL.appendingPathComponent(
            "Conflict.txt",
            isDirectory: false
        )
        try Data("Original baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        return FileConflictWorkflowFixture(
            fileURL: fileURL,
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryURL,
                fileManager: .default
            ),
            connector: FileAccessConnector(fileManager: .default)
        )
    }

    private func makeProtectedFileConflict(
        fixture: FileConflictWorkflowFixture,
        localText: String,
        externalText: String
    ) async throws -> ProtectedFileConflict {
        let documentID = DocumentID(rawValue: UUID())
        let snapshot = try await fixture.connector.openTextFile(
            at: fixture.fileURL,
            documentID: documentID
        )
        let openedState = openObservedBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: documentID,
            tabID: TabID(rawValue: UUID()),
            text: snapshot.openedFile.text,
            observation: ObservedBoundFile(
                binding: snapshot.openedFile.binding,
                providerConflictVersions: snapshot.providerConflictVersions
            )
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: openedState,
            newText: localText,
            editedAt: Date(timeIntervalSince1970: 1_786_900_000),
            recoveryStore: fixture.recoveryStore
        )
        try replaceFileContents(
            at: fixture.fileURL,
            with: Data(externalText.utf8)
        )
        let observation = try await fixture.connector.reconcilePresentedFile(
            documentID: documentID,
            binding: try XCTUnwrap(
                protectedState.activeTab.document.fileBinding
            )
        )
        let conflictedState = try reconcileBoundDocument(
            state: protectedState,
            documentID: documentID,
            observation: observation
        )
        XCTAssertEqual(
            conflictedState.activeTab.document.fileConflict,
            .contentChanged
        )
        return ProtectedFileConflict(
            documentID: documentID,
            state: conflictedState
        )
    }
}

private struct FileConflictWorkflowFixture {
    let fileURL: URL
    let recoveryStore: FileRecoveryStore
    let connector: FileAccessConnector
}

private struct ProtectedFileConflict {
    let documentID: DocumentID
    let state: PhonePadState
}

private actor DiscardFailureRecoveryStore: RecoveryStoring {
    private let recoveryStore: FileRecoveryStore

    init(recoveryStore: FileRecoveryStore) {
        self.recoveryStore = recoveryStore
    }

    func save(envelope: RecoveryEnvelope) async throws {
        try await recoveryStore.save(envelope: envelope)
    }

    func load(documentID: DocumentID) async throws -> RecoveryEnvelope? {
        try await recoveryStore.load(documentID: documentID)
    }

    func verifyCheckpoint(
        documentID: DocumentID
    ) async throws -> RecoveryCheckpointVerification {
        try await recoveryStore.verifyCheckpoint(documentID: documentID)
    }

    func recoveryItems() async throws -> [RecoveryItemSummary] {
        try await recoveryStore.recoveryItems()
    }

    func recoveryFileCollisionClaims(
        excludingDocumentID: DocumentID
    ) async throws -> [FileCollisionClaim] {
        try await recoveryStore.recoveryFileCollisionClaims(
            excludingDocumentID: excludingDocumentID
        )
    }

    func discardRecovery(
        documentID _: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        throw CocoaError(.fileWriteNoPermission)
    }

    func completeRecoveryAfterSave(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try await recoveryStore.completeRecoveryAfterSave(
            documentID: documentID
        )
    }
}

private func replaceFileContents(at url: URL, with data: Data) throws {
    try data.write(to: url, options: [])
}
