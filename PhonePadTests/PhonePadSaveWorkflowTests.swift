import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadSaveWorkflowTests: XCTestCase {
    func testProtectedNewDocumentSavesExactFileAndTerminatesRecovery() async throws {
        let fixture = try await makeProtectedFixture(text: "First line\r\nSecond line")
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Bound.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )

        let result = try await savePreparedNewDocument(
            state: fixture.state,
            preparedSave: preparedSave,
            selectedFolderURL: fixture.filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: fixture.store
        )

        XCTAssertEqual(result.disposition, .bound)
        XCTAssertNil(result.notice)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertEqual(result.state.activeTab.document.title, "Bound.txt")
        XCTAssertEqual(result.state.activeTab.document.text, "First line\nSecond line")
        XCTAssertEqual(
            result.state.activeTab.document.fileBinding?.displayName,
            preparedSave.fileName
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.filesURL.appendingPathComponent("Bound.txt")),
            Data("First line\nSecond line".utf8)
        )
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.state.activeTab.document.id
        )
        XCTAssertNil(remainingRecovery)
    }

    func testExistingTargetRemainsUnchangedAndCurrentRecoveryRemainsAvailable() async throws {
        let fixture = try await makeProtectedFixture(text: "Preserve this text")
        let targetURL = fixture.filesURL.appendingPathComponent("Existing.txt")
        let existingData = Data("Existing owner content".utf8)
        try existingData.write(to: targetURL, options: .withoutOverwriting)
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Existing.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )

        do {
            _ = try await savePreparedNewDocument(
                state: fixture.state,
                preparedSave: preparedSave,
                selectedFolderURL: fixture.filesURL,
                fileAccessConnector: FileAccessConnector(fileManager: .default),
                recoveryStore: fixture.store
            )
            XCTFail("Expected existing target to reject Save As.")
        } catch let error as FileAccessConnectorError {
            XCTAssertEqual(error, .targetAlreadyExists(.regularFile))
        } catch {
            XCTFail("Expected typed FileAccessConnectorError, received \(error).")
        }

        XCTAssertEqual(try Data(contentsOf: targetURL), existingData)
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.state.activeTab.document.id
        )
        XCTAssertEqual(remainingRecovery?.text, "Preserve this text")
        XCTAssertTrue(fixture.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            fixture.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
    }

    func testBookmarkFailureReturnsCleanDetachedResultAndTerminatesRecovery() async throws {
        let fixture = try await makeProtectedFixture(text: "Detached output")
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Detached.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { _ in
                throw ForcedSaveWorkflowBookmarkError()
            }
        )

        let result = try await savePreparedNewDocument(
            state: fixture.state,
            preparedSave: preparedSave,
            selectedFolderURL: fixture.filesURL,
            fileAccessConnector: connector,
            recoveryStore: fixture.store
        )

        XCTAssertEqual(result.disposition, .verifiedDetached)
        XCTAssertEqual(result.notice, .durableFileAccessUnavailable)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertNil(result.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            try Data(
                contentsOf: fixture.filesURL.appendingPathComponent("Detached.txt")
            ),
            Data("Detached output".utf8)
        )
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.state.activeTab.document.id
        )
        XCTAssertNil(remainingRecovery)
    }

    func testVerifiedOutputWithCorruptRecoveryReturnsCleanupFailureAndRetainsArtifact() async throws {
        let fixture = try await makeProtectedFixture(text: "Output is already durable")
        let documentID = fixture.state.activeTab.document.id
        let recoveryArtifactURL = fixture.recoveryURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json"
        )
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Verified.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )
        let corruptRecoveryData = Data("corrupt recovery".utf8)
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { targetURL in
                try corruptRecoveryData.write(to: recoveryArtifactURL, options: .atomic)
                return try targetURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        )

        do {
            _ = try await savePreparedNewDocument(
                state: fixture.state,
                preparedSave: preparedSave,
                selectedFolderURL: fixture.filesURL,
                fileAccessConnector: connector,
                recoveryStore: fixture.store
            )
            XCTFail("Expected verified output to report recovery cleanup failure.")
        } catch let error as NewDocumentSaveWorkflowError {
            guard case let .outputVerifiedButRecoveryCleanupFailed(
                result,
                cleanupFailure
            ) = error else {
                return XCTFail("Unexpected workflow error: \(error).")
            }
            XCTAssertEqual(result.disposition, .bound)
            XCTAssertFalse(result.state.activeTab.document.isUnsaved)
            XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
            XCTAssertNotNil(result.state.activeTab.document.fileBinding)
            guard case let .fileRecoveryStore(storeError) = cleanupFailure else {
                return XCTFail("Expected structured FileRecoveryStore cleanup failure.")
            }
            guard case .couldNotDecodeCheckpoint = storeError else {
                return XCTFail("Unexpected cleanup store failure: \(storeError).")
            }
            let bridgedStoreError = storeError as NSError
            XCTAssertEqual(cleanupFailure.errorDomain, bridgedStoreError.domain)
            XCTAssertEqual(cleanupFailure.errorCode, bridgedStoreError.code)
            XCTAssertTrue(
                cleanupFailure.userFacingDescription
                    .localizedCaseInsensitiveContains("corrupt")
            )
            XCTAssertFalse(
                cleanupFailure.userFacingDescription.contains(fixture.recoveryURL.path)
            )
            XCTAssertFalse(error.localizedDescription.contains(fixture.recoveryURL.path))
        } catch {
            XCTFail("Expected typed NewDocumentSaveWorkflowError, received \(error).")
        }

        XCTAssertEqual(
            try Data(
                contentsOf: fixture.filesURL.appendingPathComponent("Verified.txt")
            ),
            Data("Output is already durable".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: recoveryArtifactURL), corruptRecoveryData)
        XCTAssertTrue(fixture.state.activeTab.document.isUnsaved)
        XCTAssertEqual(fixture.state.activeTab.document.recoveryState, .protectedUnsaved)
    }

    func testVerifiedMarkerCleanupFailureReturnsCleanSaveAndRetriesOnCatalogAccess() async throws {
        let recoveryURL = try makeTemporaryDirectory()
        let filesURL = try makeTemporaryDirectory()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let canonicalURL = recoveryURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json",
            isDirectory: false
        )
        let terminalRemoval = FailOnceTerminalArtifactRemoval(failingURL: canonicalURL)
        let store = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default,
            postPromotionValidation: { _ in },
            terminalArtifactRemoval: { fileManager, url in
                try terminalRemoval.remove(fileManager: fileManager, url: url)
            }
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "User Content must not remain cataloged",
            editedAt: Date(timeIntervalSince1970: 1_786_646_700),
            recoveryStore: store
        )
        let preparedSave = try prepareNewFileSave(
            state: protectedState,
            fileName: "Terminal.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_800)
        )

        let result = try await savePreparedNewDocument(
            state: protectedState,
            preparedSave: preparedSave,
            selectedFolderURL: filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: store
        )

        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(result.state.activeTab.document.recoveryState, .clean)
        XCTAssertEqual(result.notice, .recoveryCleanupPending)
        XCTAssertEqual(
            try Data(contentsOf: filesURL.appendingPathComponent("Terminal.txt")),
            Data("User Content must not remain cataloged".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        let retainedMarker = try Data(contentsOf: canonicalURL)
        XCTAssertFalse(retainedMarker.contains(Data("User Content".utf8)))
        XCTAssertTrue(
            retainedMarker.contains(Data("phonepad.recovery.cleanup".utf8))
        )

        let recoveryItems = try await store.recoveryItems()
        let loadedRecovery = try await store.load(documentID: documentID)

        XCTAssertTrue(recoveryItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertNil(loadedRecovery)
        XCTAssertEqual(terminalRemoval.attemptCount, 2)
    }

    func testPersistentTerminalMarkerCleanupBlocksNextCheckpointWithoutClaimingRecovery() async throws {
        let recoveryURL = try makeTemporaryDirectory()
        let filesURL = try makeTemporaryDirectory()
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        )
        let canonicalURL = recoveryURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json",
            isDirectory: false
        )
        let terminalRemoval = PersistentTerminalArtifactRemoval(
            failingURL: canonicalURL
        )
        let store = FileRecoveryStore(
            rootURL: recoveryURL,
            fileManager: .default,
            postPromotionValidation: { _ in },
            terminalArtifactRemoval: { fileManager, url in
                try terminalRemoval.remove(fileManager: fileManager, url: url)
            }
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Initial User Content",
            editedAt: Date(timeIntervalSince1970: 1_786_646_900),
            recoveryStore: store
        )
        let preparedSave = try prepareNewFileSave(
            state: protectedState,
            fileName: "Persistent.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_647_000)
        )
        let savedResult = try await savePreparedNewDocument(
            state: protectedState,
            preparedSave: preparedSave,
            selectedFolderURL: filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: store
        )

        XCTAssertFalse(savedResult.state.activeTab.document.isUnsaved)
        XCTAssertEqual(savedResult.notice, .recoveryCleanupPending)

        do {
            _ = try await editActiveDocumentAndCheckpoint(
                state: savedResult.state,
                newText: "Next User Content",
                editedAt: Date(timeIntervalSince1970: 1_786_647_100),
                recoveryStore: store
            )
            XCTFail("Expected persistent terminal cleanup to block checkpointing.")
        } catch let error as FileRecoveryStoreError {
            guard case let .terminalCleanupBlocksCheckpoint(actualDocumentID) = error else {
                return XCTFail("Unexpected recovery error: \(error).")
            }
            XCTAssertEqual(actualDocumentID, documentID)
            XCTAssertFalse(error.localizedDescription.contains(recoveryURL.path))
        } catch {
            XCTFail("Expected typed FileRecoveryStoreError, received \(error).")
        }

        let retainedMarker = try Data(contentsOf: canonicalURL)
        XCTAssertTrue(
            retainedMarker.contains(Data("phonepad.recovery.cleanup".utf8))
        )
        XCTAssertFalse(retainedMarker.contains(Data("Initial User Content".utf8)))
        XCTAssertFalse(retainedMarker.contains(Data("Next User Content".utf8)))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: recoveryURL.path),
            [canonicalURL.lastPathComponent]
        )
        let recoveryItems = try await store.recoveryItems()
        let loadedRecovery = try await store.load(documentID: documentID)
        XCTAssertTrue(recoveryItems.isEmpty)
        XCTAssertNil(loadedRecovery)

        do {
            _ = try await store.verifyCheckpoint(documentID: documentID)
            XCTFail("Expected no recovery checkpoint to be claimed.")
        } catch let error as FileRecoveryStoreError {
            guard case .checkpointNotFound = error else {
                return XCTFail("Unexpected verification error: \(error).")
            }
        } catch {
            XCTFail("Expected typed FileRecoveryStoreError, received \(error).")
        }
    }

    func testChangedTextAfterPreparationFailsBeforeFileCreation() async throws {
        let fixture = try await makeProtectedFixture(text: "Prepared text")
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Stale.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )
        let changedState = try await editActiveDocumentAndCheckpoint(
            state: fixture.state,
            newText: "Current text",
            editedAt: Date(timeIntervalSince1970: 1_786_646_600),
            recoveryStore: fixture.store
        )

        do {
            _ = try await savePreparedNewDocument(
                state: changedState,
                preparedSave: preparedSave,
                selectedFolderURL: fixture.filesURL,
                fileAccessConnector: FileAccessConnector(fileManager: .default),
                recoveryStore: fixture.store
            )
            XCTFail("Expected stale Save As preparation to be rejected.")
        } catch let error as NewDocumentSaveWorkflowError {
            XCTAssertEqual(
                error,
                .activeDocumentTextChangedSincePreparation(
                    fixture.state.activeTab.document.id
                )
            )
        } catch {
            XCTFail("Expected typed NewDocumentSaveWorkflowError, received \(error).")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.filesURL.appendingPathComponent("Stale.txt").path
            )
        )
        let remainingRecovery = try await fixture.store.load(
            documentID: fixture.state.activeTab.document.id
        )
        XCTAssertEqual(remainingRecovery?.text, "Current text")
    }

    func testPendingDocumentIsProtectedBeforeFileCreationCanBegin() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let pendingTransition = try beginActiveDocumentEdit(
            state: initialState,
            newText: "Newest pending text",
            editedAt: Date(timeIntervalSince1970: 1_786_646_600)
        )
        let store = FileRecoveryStore(rootURL: recoveryURL, fileManager: .default)
        let preparedSave = try prepareNewFileSave(
            state: pendingTransition.state,
            fileName: "Pending.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_600)
        )

        let protectedState = try await protectPreparedNewFileSave(
            state: pendingTransition.state,
            preparedSave: preparedSave,
            recoveryStore: store
        )

        XCTAssertEqual(protectedState.activeTab.document.recoveryState, .protectedUnsaved)
        let storedRecovery = try await store.load(
            documentID: pendingTransition.state.activeTab.document.id
        )
        XCTAssertEqual(storedRecovery?.text, "Newest pending text")
    }

    func testProtectionRecreatesMissingArtifactEvenWhenStateWasProtected() async throws {
        let fixture = try await makeProtectedFixture(text: "Must be re-protected")
        let documentID = fixture.state.activeTab.document.id
        let recoveryArtifactURL = fixture.recoveryURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json"
        )
        try FileManager.default.removeItem(at: recoveryArtifactURL)
        let preparedSave = try prepareNewFileSave(
            state: fixture.state,
            fileName: "Reprotected.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_700)
        )

        let protectedState = try await protectPreparedNewFileSave(
            state: fixture.state,
            preparedSave: preparedSave,
            recoveryStore: fixture.store
        )

        XCTAssertEqual(protectedState.activeTab.document.recoveryState, .protectedUnsaved)
        let recreatedRecovery = try await fixture.store.load(documentID: documentID)
        XCTAssertEqual(recreatedRecovery?.text, "Must be re-protected")
        XCTAssertEqual(
            recreatedRecovery?.editedAt,
            Date(timeIntervalSince1970: 1_786_646_700)
        )
    }

    func testRecoveryProtectionFailureStopsBeforeFileCreation() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let blockedRecoveryURL = rootURL.appendingPathComponent(
            "Recovery",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let blockerData = Data("not a directory".utf8)
        try blockerData.write(to: blockedRecoveryURL, options: .withoutOverwriting)
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let pendingTransition = try beginActiveDocumentEdit(
            state: initialState,
            newText: "Do not write before protection",
            editedAt: Date(timeIntervalSince1970: 1_786_646_800)
        )
        let preparedSave = try prepareNewFileSave(
            state: pendingTransition.state,
            fileName: "Blocked.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_800)
        )
        let store = FileRecoveryStore(
            rootURL: blockedRecoveryURL,
            fileManager: .default
        )

        do {
            _ = try await savePreparedNewDocument(
                state: pendingTransition.state,
                preparedSave: preparedSave,
                selectedFolderURL: filesURL,
                fileAccessConnector: FileAccessConnector(fileManager: .default),
                recoveryStore: store
            )
            XCTFail("Expected recovery protection to fail before File creation.")
        } catch let error as FileRecoveryStoreError {
            guard case .couldNotCreateRecoveryDirectory = error else {
                return XCTFail("Unexpected recovery failure: \(error).")
            }
        } catch {
            XCTFail("Expected typed FileRecoveryStoreError, received \(error).")
        }

        XCTAssertEqual(try Data(contentsOf: blockedRecoveryURL), blockerData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: filesURL.appendingPathComponent("Blocked.txt").path
            )
        )
        XCTAssertEqual(
            pendingTransition.state.activeTab.document.recoveryState,
            .checkpointPending
        )
    }

    func testFreshEmptyDocumentSavesWithoutAccessingRecoveryStorage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesURL = rootURL.appendingPathComponent("Files", isDirectory: true)
        let recoveryURL = rootURL.appendingPathComponent("Recovery", isDirectory: false)
        try FileManager.default.createDirectory(
            at: filesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let blockedRecoveryData = Data("not a directory".utf8)
        try blockedRecoveryData.write(
            to: recoveryURL,
            options: .withoutOverwriting
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }
        let state = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let store = FileRecoveryStore(rootURL: recoveryURL, fileManager: .default)
        let preparedSave = try prepareNewFileSave(
            state: state,
            fileName: "Empty.txt",
            encoding: .utf8,
            recoveryEditedAt: Date(timeIntervalSince1970: 1_786_646_500)
        )

        let result = try await savePreparedNewDocument(
            state: state,
            preparedSave: preparedSave,
            selectedFolderURL: filesURL,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            recoveryStore: store
        )

        XCTAssertEqual(result.disposition, .bound)
        XCTAssertFalse(result.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            try Data(contentsOf: filesURL.appendingPathComponent("Empty.txt")),
            Data()
        )
        XCTAssertEqual(try Data(contentsOf: recoveryURL), blockedRecoveryData)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    private func makeProtectedFixture(text: String) async throws -> SaveWorkflowFixture {
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

        let state = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let store = FileRecoveryStore(rootURL: recoveryURL, fileManager: .default)
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: state,
            newText: text,
            editedAt: Date(timeIntervalSince1970: 1_786_646_400),
            recoveryStore: store
        )
        return SaveWorkflowFixture(
            filesURL: filesURL,
            recoveryURL: recoveryURL,
            state: protectedState,
            store: store
        )
    }
}

private struct SaveWorkflowFixture {
    let filesURL: URL
    let recoveryURL: URL
    let state: PhonePadState
    let store: FileRecoveryStore
}

private struct ForcedSaveWorkflowBookmarkError: Error, Sendable {}

private final class FailOnceTerminalArtifactRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private let failingURL: URL
    private var remainingFailures: Int
    private var recordedAttemptCount: Int

    init(failingURL: URL) {
        self.failingURL = failingURL.standardizedFileURL
        remainingFailures = 1
        recordedAttemptCount = 0
    }

    var attemptCount: Int {
        lock.withLock { recordedAttemptCount }
    }

    func remove(fileManager: FileManager, url: URL) throws {
        let shouldFail = lock.withLock {
            guard url.standardizedFileURL == failingURL else {
                return false
            }
            recordedAttemptCount += 1
            guard remainingFailures > 0 else {
                return false
            }
            remainingFailures -= 1
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.removeItem(at: url)
    }
}

private final class PersistentTerminalArtifactRemoval: @unchecked Sendable {
    private let failingURL: URL

    init(failingURL: URL) {
        self.failingURL = failingURL.standardizedFileURL
    }

    func remove(fileManager: FileManager, url: URL) throws {
        guard url.standardizedFileURL == failingURL else {
            try fileManager.removeItem(at: url)
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
