import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadAppModelTests: XCTestCase {
    func testRecoveryCatalogDoesNotRestorePreservedWorkAtLaunch() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        )
        let editedAt = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Untitled 4",
                text: "Private preserved content",
                editedAt: editedAt
            )
        )
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let model = PhonePadAppModel(state: initialState, recoveryStore: store)

        await model.refreshRecoveryItems()

        XCTAssertEqual(model.state, initialState)
        XCTAssertEqual(model.state.tabs.count, 1)
        XCTAssertEqual(model.state.activeTab.document.title, "Untitled")
        XCTAssertEqual(model.recoveryItems.count, 1)
        XCTAssertEqual(model.recoveryItems[0].documentID, preservedDocumentID)
        XCTAssertEqual(model.recoveryItems[0].title, "Untitled 4")
        XCTAssertEqual(model.recoveryItems[0].lastEdited, .available(editedAt))
        XCTAssertEqual(model.recoveryItems[0].status, .recoverable)
    }

    func testRecoveryCatalogFailureClearsPreviouslyLoadedItems() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: DocumentID(rawValue: UUID()),
                title: "Preserved",
                text: "Private content",
                editedAt: Date(timeIntervalSince1970: 1_760_000_000)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()
        XCTAssertEqual(model.recoveryItems.count, 1)
        try FileManager.default.removeItem(at: rootURL)
        try Data("not a directory".utf8).write(to: rootURL)

        await model.refreshRecoveryItems()

        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertNotNil(model.recoveryCatalogError)
    }

    func testRecoverCreatesNormalUnsavedTabAndRetainsCheckpoint() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        )
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: preservedDocumentID,
            title: "Untitled 2",
            text: "Recovered content",
            editedAt: Date(timeIntervalSince1970: 1_760_000_100)
        )
        try await store.save(envelope: envelope)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()

        let didRecover = await model.recoverRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.state.tabs.count, 2)
        XCTAssertEqual(model.state.activeTab.document.id, preservedDocumentID)
        XCTAssertEqual(model.state.activeTab.document.text, "Recovered content")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
        XCTAssertTrue(model.recoveryItems.isEmpty)
        let retainedEnvelope = try await store.load(documentID: preservedDocumentID)
        XCTAssertEqual(retainedEnvelope, envelope)
    }

    func testRecoverWaitsForCurrentCheckpointWithoutLosingEitherTab() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let currentDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        )
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Preserved",
                text: "Preserved content",
                editedAt: Date(timeIntervalSince1970: 1_760_000_300)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: currentDocumentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()
        model.editActiveDocument(text: "Current unsaved content")

        let didRecover = await model.recoverRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.state.tabs.count, 2)
        XCTAssertEqual(model.state.tabs[0].document.id, currentDocumentID)
        XCTAssertEqual(model.state.tabs[0].document.text, "Current unsaved content")
        XCTAssertEqual(
            model.state.tabs[0].document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertEqual(model.state.activeTab.document.id, preservedDocumentID)
        let currentEnvelope = try await store.load(documentID: currentDocumentID)
        XCTAssertEqual(currentEnvelope?.text, "Current unsaved content")
    }

    func testDiscardRecoveryRemovesCatalogItemOnlyAfterTerminalStoreTransition() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Untitled 3",
                text: "Discard me",
                editedAt: Date(timeIntervalSince1970: 1_760_000_200)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()

        let didDiscard = await model.discardRecovery(documentID: preservedDocumentID)

        XCTAssertTrue(didDiscard)
        XCTAssertTrue(model.recoveryItems.isEmpty)
        let discardedEnvelope = try await store.load(documentID: preservedDocumentID)
        XCTAssertNil(discardedEnvelope)
    }

    func testDiscardResidualCleanupIsNonblockingAndRetriesOnCatalogRefresh() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let preservedDocumentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000210")!
        )
        let canonicalURL = rootURL.appendingPathComponent(
            preservedDocumentID.rawValue.uuidString.lowercased() + ".recovery.json",
            isDirectory: false
        )
        let removalGate = DiscardTerminalRemovalGate(failingURL: canonicalURL)
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: { _ in },
            terminalArtifactRemoval: { fileManager, url in
                try removalGate.remove(fileManager: fileManager, url: url)
            }
        )
        try await store.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Discard residual",
                text: "User Content is terminal after marker verification",
                editedAt: Date(timeIntervalSince1970: 1_760_000_250)
            )
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()

        let didDiscard = await model.discardRecovery(
            documentID: preservedDocumentID
        )

        XCTAssertTrue(didDiscard)
        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertNil(model.recoveryCatalogError)
        XCTAssertNotNil(model.fileSaveNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(
            try Data(contentsOf: canonicalURL)
                .contains(Data("User Content".utf8))
        )

        await model.refreshRecoveryItems()

        XCTAssertTrue(model.recoveryItems.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(removalGate.attemptCount, 2)
    }

    func testRapidEditsCheckpointLatestGenerationWithoutSerializingEveryEdit() async throws {
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

        let documentID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let tabID = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(documentID: documentID, tabID: tabID),
            recoveryStore: store,
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        for generation in 1 ... 160 {
            model.editActiveDocument(text: "Generation \(generation)")
        }

        try await Task.sleep(for: .milliseconds(250))

        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.text, "Generation 160")
        XCTAssertEqual(model.activeText, "Generation 160")
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
    }

    func testSaveNewDocumentForcesLatestCheckpointAndReturnsCleanBoundFile() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Earlier text",
            editedAt: Date(timeIntervalSince1970: 1_760_000_400),
            recoveryStore: store
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        model.editActiveDocument(text: "Latest\r\ntext")
        let preparation = try model.prepareNewDocumentSave(
            fileName: "Notes.txt",
            encoding: .utf8
        )

        let didSave = await model.saveNewDocument(
            preparation: preparation,
            selectedFolderURL: destinationFolderURL
        )

        XCTAssertTrue(didSave)
        XCTAssertEqual(model.state.activeTab.document.title, "Notes.txt")
        XCTAssertEqual(model.state.activeTab.document.text, "Latest\ntext")
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            DocumentRecoveryState.clean
        )
        XCTAssertNotNil(model.state.activeTab.document.fileBinding)
        XCTAssertNil(model.fileSaveError)
        XCTAssertNil(model.fileSaveNotice)
        XCTAssertFalse(model.fileSaveInProgress)
        let targetURL = destinationFolderURL.appendingPathComponent(
            "Notes.txt",
            isDirectory: false
        )
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("Latest\ntext".utf8))
        let removedRecovery = try await store.load(documentID: documentID)
        XCTAssertNil(removedRecovery)
    }

    func testSaveNewDocumentFailureKeepsLatestTextAndRecoveryProtected() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let targetURL = destinationFolderURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        let originalBytes = Data("Existing content".utf8)
        try originalBytes.write(to: targetURL, options: .withoutOverwriting)
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Earlier text",
            editedAt: Date(timeIntervalSince1970: 1_760_000_500),
            recoveryStore: store
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        model.editActiveDocument(text: "Latest protected text")
        let preparation = try model.prepareNewDocumentSave(
            fileName: "Existing.txt",
            encoding: .utf8
        )

        let didSave = await model.saveNewDocument(
            preparation: preparation,
            selectedFolderURL: destinationFolderURL
        )

        XCTAssertFalse(didSave)
        XCTAssertEqual(model.state.activeTab.document.text, "Latest protected text")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            DocumentRecoveryState.protectedUnsaved
        )
        XCTAssertNil(model.state.activeTab.document.fileBinding)
        XCTAssertNotNil(model.fileSaveError)
        XCTAssertNil(model.fileSaveNotice)
        XCTAssertFalse(model.fileSaveInProgress)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalBytes)
        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.text, "Latest protected text")
    }

    func testVerifiedSaveCleanupFailureBlocksMutationUntilRetrySucceeds() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Protected text",
            editedAt: Date(timeIntervalSince1970: 1_760_000_600),
            recoveryStore: store
        )
        let recoveryArtifactURL = recoveryRootURL.appendingPathComponent(
            documentID.rawValue.uuidString.lowercased() + ".recovery.json",
            isDirectory: false
        )
        let loadedRecoveryEnvelope = try await store.load(documentID: documentID)
        let recoveryEnvelope = try XCTUnwrap(loadedRecoveryEnvelope)
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { targetURL in
                try Data("corrupt recovery".utf8).write(
                    to: recoveryArtifactURL,
                    options: .atomic
                )
                return try targetURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let preparation = try model.prepareNewDocumentSave(
            fileName: "Verified.txt",
            encoding: .utf8
        )

        let didSave = await model.saveNewDocument(
            preparation: preparation,
            selectedFolderURL: destinationFolderURL
        )

        XCTAssertFalse(didSave)
        XCTAssertTrue(model.fileSaveCleanupRequired)
        XCTAssertTrue(model.fileMutationDisabled)
        let cleanupError = try XCTUnwrap(model.fileSaveError)
        XCTAssertTrue(cleanupError.contains("Retry Cleanup"))
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
        XCTAssertNil(model.state.activeTab.document.fileBinding)
        XCTAssertEqual(
            try Data(
                contentsOf: destinationFolderURL.appendingPathComponent(
                    "Verified.txt",
                    isDirectory: false
                )
            ),
            Data("Protected text".utf8)
        )

        model.editActiveDocument(text: "Blocked mutation")
        model.clearFileSaveFeedback()

        XCTAssertEqual(model.activeText, "Protected text")
        XCTAssertTrue(model.fileSaveCleanupRequired)
        XCTAssertEqual(model.fileSaveError, cleanupError)

        let failedRetry = await model.retryFileSaveCleanup()

        XCTAssertFalse(failedRetry)
        XCTAssertTrue(model.fileSaveCleanupRequired)
        XCTAssertTrue(model.fileMutationDisabled)
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)

        try FileManager.default.removeItem(at: recoveryArtifactURL)
        try await store.save(envelope: recoveryEnvelope)

        let didRetry = await model.retryFileSaveCleanup()

        XCTAssertTrue(didRetry)
        XCTAssertFalse(model.fileSaveCleanupRequired)
        XCTAssertFalse(model.fileMutationDisabled)
        XCTAssertNil(model.fileSaveError)
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .clean)
        XCTAssertNotNil(model.state.activeTab.document.fileBinding)
        let remainingRecovery = try await store.load(documentID: documentID)
        XCTAssertNil(remainingRecovery)
    }

    func testEditDuringInFlightSaveIsRejectedWithVisibleTypedError() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000209")!
        )
        let initialState = makeInitialPhonePadState(
            documentID: documentID,
            tabID: TabID(rawValue: UUID())
        )
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: initialState,
            newText: "Protected before Save",
            editedAt: Date(timeIntervalSince1970: 1_760_000_700),
            recoveryStore: store
        )
        let gate = BlockingBookmarkGate()
        let connector = FileAccessConnector(
            fileManager: .default,
            bookmarkCreator: { targetURL in
                try gate.createBookmark(afterEnteringFor: targetURL)
            }
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let preparation = try model.prepareNewDocumentSave(
            fileName: "InFlight.txt",
            encoding: .utf8
        )

        let saveTask = Task { @MainActor in
            await model.saveNewDocument(
                preparation: preparation,
                selectedFolderURL: destinationFolderURL
            )
        }
        await gate.waitUntilEntered()

        model.editActiveDocument(text: "Must be rejected")

        XCTAssertTrue(model.fileSaveInProgress)
        XCTAssertEqual(model.activeText, "Protected before Save")
        let actionError = try XCTUnwrap(model.fileSaveError)
        XCTAssertTrue(actionError.localizedCaseInsensitiveContains("still running"))

        gate.resume()
        let didSave = await saveTask.value

        XCTAssertTrue(didSave)
        XCTAssertFalse(model.fileSaveInProgress)
        XCTAssertNil(model.fileSaveError)
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            try Data(
                contentsOf: destinationFolderURL.appendingPathComponent(
                    "InFlight.txt",
                    isDirectory: false
                )
            ),
            Data("Protected before Save".utf8)
        )
    }

    private func makeModelRecoveryRoot() throws -> URL {
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
        return rootURL
    }
}

private final class BlockingBookmarkGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func createBookmark(afterEnteringFor url: URL) throws -> Data {
        let continuation = lock.withLock {
            didEnter = true
            let continuation = entryContinuation
            entryContinuation = nil
            return continuation
        }
        continuation?.resume()
        release.wait()
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if didEnter {
                    return true
                }
                precondition(entryContinuation == nil)
                entryContinuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}

private final class DiscardTerminalRemovalGate: @unchecked Sendable {
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
