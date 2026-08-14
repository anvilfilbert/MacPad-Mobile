import Foundation
import XCTest

@testable import PhonePad
@testable import PhonePadCore

final class PhonePadBoundFileWorkflowTests: XCTestCase {
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
            "Source.txt",
            isDirectory: false
        )
        try Data(originalText.utf8).write(
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
        let openedFile = try await connector.openUTF8File(at: sourceURL)
        return openBoundDocument(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID()),
            text: openedFile.text,
            fileBinding: openedFile.binding
        )
    }
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
