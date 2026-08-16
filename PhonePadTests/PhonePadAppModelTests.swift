import Foundation
import XCTest
@testable import PhonePad
import PhonePadCore

@MainActor
final class PhonePadAppModelTests: XCTestCase {
    func testApplicationUsesMacPadMobileDisplayName() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String,
            "MacPad Mobile"
        )
    }

    func testBoundEditRejectsTextWithoutAnySupportedFileRepresentation() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let sourceRootURL = try makeModelRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Bound.txt",
            isDirectory: false
        )
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: sourceURL, options: .withoutOverwriting)
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let initialState = makeInitialPhonePadState(
            documentID: DocumentID(rawValue: UUID()),
            tabID: TabID(rawValue: UUID())
        )
        let model = PhonePadAppModel(
            state: initialState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: sourceURL)
        XCTAssertTrue(didOpen)
        let openedState = model.state
        let oversizedText = String(
            repeating: "a",
            count: maximumSupportedTextFileByteCount + 1
        )

        model.editActiveDocument(text: oversizedText)

        XCTAssertEqual(model.state, openedState)
        XCTAssertEqual(model.activeText, "Original\n")
        XCTAssertNotNil(model.recoveryError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        let recovery = try await store.load(
            documentID: openedState.activeTab.document.id
        )
        XCTAssertNil(recovery)
    }

    func testOpenRejectsCommittedEditorTextModelDidNotAccept() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let sourceRootURL = try makeModelRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Open.txt",
            isDirectory: false
        )
        try Data("External text\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: FileRecoveryStore(
                rootURL: recoveryRootURL,
                fileManager: .default
            )
        )
        let initialState = model.state

        let didOpen = await model.openDocument(
            selectedURL: sourceURL,
            after: CommittedEditorDocument(
                documentID: initialState.activeTab.document.id,
                text: "Rejected\0editor text"
            )
        )

        XCTAssertFalse(didOpen)
        XCTAssertEqual(model.state, initialState)
        XCTAssertNotNil(model.fileSaveError)
    }

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

        let didRecover = await model.recoverTestRecovery(
            documentID: preservedDocumentID
        )

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

    func testRecoverRejectsCommittedEditorTextModelDidNotAccept() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(rawValue: UUID())
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: preservedDocumentID,
            title: "Preserved",
            text: "Preserved content",
            editedAt: Date(timeIntervalSince1970: 1_760_000_150)
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
        let initialState = model.state

        let didRecover = await model.recoverRecovery(
            documentID: preservedDocumentID,
            after: CommittedEditorDocument(
                documentID: initialState.activeTab.document.id,
                text: "Rejected\0editor text"
            )
        )

        XCTAssertFalse(didRecover)
        XCTAssertEqual(model.state, initialState)
        XCTAssertEqual(model.recoveryItems.map(\.documentID), [preservedDocumentID])
        let retainedEnvelope = try await store.load(
            documentID: preservedDocumentID
        )
        XCTAssertEqual(retainedEnvelope, envelope)
        XCTAssertNotNil(model.recoveryCatalogError)
    }

    func testRecoverCheckpointFailureKeepsCurrentAndPreservedWork() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let setupStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let preservedDocumentID = DocumentID(rawValue: UUID())
        let envelope = RecoveryEnvelope(
            formatVersion: RecoveryEnvelope.currentFormatVersion,
            documentID: preservedDocumentID,
            title: "Preserved",
            text: "Preserved content",
            editedAt: Date(timeIntervalSince1970: 1_760_000_175)
        )
        try await setupStore.save(envelope: envelope)
        let validationGate = CheckpointValidationGate()
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: validationGate.validate
        )
        let currentDocumentID = DocumentID(rawValue: UUID())
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: currentDocumentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        await model.refreshRecoveryItems()
        model.editActiveDocument(text: "Current unsaved content")

        let didRecover = await model.recoverRecovery(
            documentID: preservedDocumentID,
            after: CommittedEditorDocument(
                documentID: currentDocumentID,
                text: "Current unsaved content"
            )
        )

        XCTAssertFalse(didRecover)
        XCTAssertEqual(model.state.tabs.count, 1)
        XCTAssertEqual(model.state.activeTab.document.id, currentDocumentID)
        XCTAssertEqual(model.activeText, "Current unsaved content")
        XCTAssertEqual(model.recoveryItems.map(\.documentID), [preservedDocumentID])
        let retainedEnvelope = try await store.load(
            documentID: preservedDocumentID
        )
        XCTAssertEqual(retainedEnvelope, envelope)
        XCTAssertNotNil(model.recoveryCatalogError)
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

        let didRecover = await model.recoverTestRecovery(
            documentID: preservedDocumentID
        )

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

    func testRecoverRejectsQueuedEditorCallbackWhileLoadingPreservedWork() async throws {
        let rootURL = try makeModelRecoveryRoot()
        let baseStore = FileRecoveryStore(rootURL: rootURL, fileManager: .default)
        let currentDocumentID = DocumentID(rawValue: UUID())
        let preservedDocumentID = DocumentID(rawValue: UUID())
        try await baseStore.save(
            envelope: RecoveryEnvelope(
                formatVersion: RecoveryEnvelope.currentFormatVersion,
                documentID: preservedDocumentID,
                title: "Preserved",
                text: "Preserved content",
                editedAt: Date(timeIntervalSince1970: 1_760_000_325)
            )
        )
        let store = BlockingRecoveryLoadStore(
            baseStore: baseStore,
            blockedDocumentID: preservedDocumentID
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: currentDocumentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store
        )
        await model.refreshRecoveryItems()
        let committedDocument = CommittedEditorDocument(
            documentID: currentDocumentID,
            text: ""
        )
        let recover = Task {
            await model.recoverRecovery(
                documentID: preservedDocumentID,
                after: committedDocument
            )
        }
        await store.waitUntilLoadEntered()
        let stateBeforeCallback = model.state

        let didEdit = model.editDocument(
            documentID: currentDocumentID,
            text: "Queued editor callback"
        )

        XCTAssertFalse(didEdit)
        XCTAssertEqual(model.state, stateBeforeCallback)
        await store.resumeLoad()
        let didRecover = await recover.value
        XCTAssertTrue(didRecover)
        XCTAssertEqual(model.state.activeTab.document.id, preservedDocumentID)
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

    func testFailedCheckpointLocksEditsAndExplicitSaveAsRetriesAfterRepair() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let validationGate = CheckpointValidationGate()
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default,
            postPromotionValidation: { promotedURL in
                try validationGate.validate(promotedURL: promotedURL)
            }
        )
        let documentID = DocumentID(rawValue: UUID())
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let newestUnprotectedText = "Newest in-memory text\n"

        model.editActiveDocument(text: newestUnprotectedText)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNotNil(model.recoveryError)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .recoveryUnavailable
        )
        XCTAssertTrue(model.editorMutationDisabled)
        XCTAssertEqual(validationGate.attemptCount, 1)
        model.editActiveDocument(text: "Rejected after recovery failure\n")
        XCTAssertEqual(model.activeText, newestUnprotectedText)

        validationGate.repair()
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Recovered.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .ready = preflight.target else {
            return XCTFail("Absent target must be ready without confirmation.")
        }

        let didSave = await model.completePreflightedSaveAs(preflight)

        XCTAssertTrue(didSave)
        XCTAssertNil(model.recoveryError)
        XCTAssertNil(model.fileSaveError)
        XCTAssertFalse(model.editorMutationDisabled)
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .clean)
        XCTAssertEqual(
            try Data(
                contentsOf: destinationFolderURL.appendingPathComponent(
                    "Recovered.txt",
                    isDirectory: false
                )
            ),
            Data(newestUnprotectedText.utf8)
        )
        let remainingRecovery = try await store.load(documentID: documentID)
        XCTAssertNil(remainingRecovery)
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
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Notes.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .ready = preflight.target else {
            return XCTFail("Absent target must be ready without confirmation.")
        }
        let didSave = await model.completePreflightedSaveAs(preflight)

        XCTAssertTrue(
            didSave,
            model.fileSaveError
                ?? model.recoveryError
                ?? "Save returned false without a published error."
        )
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

    func testSaveAsPreflightPublishesOneReplacementTokenAndCancelIsPure() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let destinationFolderURL = try makeModelRecoveryRoot()
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(rawValue: UUID())
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Protected replacement\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_200),
            recoveryStore: store
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let targetURL = destinationFolderURL.appendingPathComponent(
            "Existing.txt",
            isDirectory: false
        )
        let originalTargetBytes = Data("Existing owner\n".utf8)
        try originalTargetBytes.write(to: targetURL, options: .withoutOverwriting)
        let recoveryBefore = try await store.load(documentID: documentID)
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Existing.txt",
            encoding: .utf8
        )

        let preflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )

        let replacement = try XCTUnwrap(preflight)
        guard case .replacementRequired = replacement.target else {
            return XCTFail("Existing target must publish replacement consent.")
        }
        XCTAssertEqual(model.pendingSaveAsReplacement, replacement)
        XCTAssertEqual(model.state, protectedState)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)

        model.cancelSaveAsReplacement()

        let recoveryAfter = try await store.load(documentID: documentID)
        XCTAssertNil(model.pendingSaveAsReplacement)
        XCTAssertEqual(model.state, protectedState)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalTargetBytes)
        XCTAssertEqual(recoveryAfter, recoveryBefore)
    }

    func testCurrentFileSaveAsCommitsSelectedEncodingWithoutReplacementToken() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let filesURL = try makeModelRecoveryRoot()
        let sourceURL = filesURL.appendingPathComponent(
            "Current.txt",
            isDirectory: false
        )
        try Data("Original\r\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: sourceURL)
        XCTAssertTrue(didOpen)
        model.editActiveDocument(text: "Selected\nencoding\n")
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Current.txt",
            encoding: .utf16BigEndianWithBOM
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: filesURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .currentFile = preflight.target else {
            return XCTFail("Current target must route without replacement consent.")
        }

        let didSave = await model.completePreflightedSaveAs(preflight)

        XCTAssertTrue(didSave)
        XCTAssertNil(model.pendingSaveAsReplacement)
        XCTAssertNil(model.fileSaveError)
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding?.encoding,
            .utf16BigEndianWithBOM
        )
        XCTAssertEqual(
            model.state.activeTab.document.fileBinding?.lineEnding,
            .crlf
        )
        XCTAssertEqual(
            try Data(contentsOf: sourceURL),
            Data([
                0xfe, 0xff,
                0x00, 0x53, 0x00, 0x65, 0x00, 0x6c, 0x00, 0x65,
                0x00, 0x63, 0x00, 0x74, 0x00, 0x65, 0x00, 0x64,
                0x00, 0x0d, 0x00, 0x0a,
                0x00, 0x65, 0x00, 0x6e, 0x00, 0x63, 0x00, 0x6f,
                0x00, 0x64, 0x00, 0x69, 0x00, 0x6e, 0x00, 0x67,
                0x00, 0x0d, 0x00, 0x0a,
            ])
        )
    }

    func testConfirmedSaveAsReplacementClearsDecisionAfterTargetRace() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let filesURL = try makeModelRecoveryRoot()
        let targetURL = filesURL.appendingPathComponent(
            "Race.txt",
            isDirectory: false
        )
        try Data("Initial owner\n".utf8).write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(rawValue: UUID())
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            newText: "PhonePad replacement\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_300),
            recoveryStore: store
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Race.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: filesURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require replacement consent.")
        }
        let racedBytes = Data("External change\n".utf8)
        try racedBytes.write(to: targetURL, options: .atomic)

        let didSave = await model.confirmReplacementAndCompleteSaveAs()

        XCTAssertFalse(didSave)
        XCTAssertNil(model.pendingSaveAsReplacement)
        XCTAssertNotNil(model.fileSaveError)
        XCTAssertEqual(try Data(contentsOf: targetURL), racedBytes)
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .protectedUnsaved)
        let recovery = try await store.load(documentID: documentID)
        XCTAssertEqual(recovery?.text, "PhonePad replacement\n")
        XCTAssertEqual(
            recovery?.pendingSave?.destination,
            .saveAs(
                RecoverySaveAsDestination(
                    directoryBookmark: preflight.target.plan.directoryBookmark,
                    fileName: preflight.target.plan.fileName
                )
            )
        )
    }

    func testConfirmedSaveAsReplacementCommitsAndTerminatesRecovery() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let filesURL = try makeModelRecoveryRoot()
        let targetURL = filesURL.appendingPathComponent(
            "Replace.txt",
            isDirectory: false
        )
        try Data("Existing\n".utf8).write(
            to: targetURL,
            options: .withoutOverwriting
        )
        let store = FileRecoveryStore(rootURL: recoveryRootURL, fileManager: .default)
        let documentID = DocumentID(rawValue: UUID())
        let protectedState = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: documentID,
                tabID: TabID(rawValue: UUID())
            ),
            newText: "Confirmed replacement\n",
            editedAt: Date(timeIntervalSince1970: 1_786_801_400),
            recoveryStore: store
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Replace.txt",
            encoding: .utf8WithBOM
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: filesURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require replacement consent.")
        }

        let didSave = await model.confirmReplacementAndCompleteSaveAs()

        XCTAssertTrue(didSave)
        XCTAssertNil(model.pendingSaveAsReplacement)
        XCTAssertNil(model.fileSaveError)
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            try Data(contentsOf: targetURL),
            Data([0xef, 0xbb, 0xbf]) + Data("Confirmed replacement\n".utf8)
        )
        let remainingRecovery = try await store.load(documentID: documentID)
        XCTAssertNil(remainingRecovery)
    }

    func testExistingSaveAsTargetWaitsForExplicitReplacement() async throws {
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
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        model.editActiveDocument(text: "Latest protected text")
        try await Task.sleep(for: .milliseconds(250))
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Existing.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .replacementRequired = preflight.target else {
            return XCTFail("Existing target must require explicit replacement.")
        }

        XCTAssertEqual(model.state.activeTab.document.text, "Latest protected text")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            DocumentRecoveryState.protectedUnsaved
        )
        XCTAssertNil(model.state.activeTab.document.fileBinding)
        XCTAssertNil(model.fileSaveError)
        XCTAssertNil(model.fileSaveNotice)
        XCTAssertFalse(model.fileSaveInProgress)
        XCTAssertEqual(model.pendingSaveAsReplacement, preflight)
        XCTAssertEqual(try Data(contentsOf: targetURL), originalBytes)
        let envelope = try await store.load(documentID: documentID)
        XCTAssertEqual(envelope?.text, "Latest protected text")
        XCTAssertNil(envelope?.pendingSave)
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
                if targetURL.standardizedFileURL
                    != destinationFolderURL.standardizedFileURL {
                    try Data("corrupt recovery".utf8).write(
                        to: recoveryArtifactURL,
                        options: .atomic
                    )
                }
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
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "Verified.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .ready = preflight.target else {
            return XCTFail("Absent target must be ready without confirmation.")
        }
        let didSave = await model.completePreflightedSaveAs(preflight)

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
                if targetURL.standardizedFileURL
                    == destinationFolderURL.standardizedFileURL {
                    return try targetURL.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }
                return try gate.createBookmark(afterEnteringFor: targetURL)
            }
        )
        let model = PhonePadAppModel(
            state: protectedState,
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let preparation = try model.prepareDocumentSaveAs(
            fileName: "InFlight.txt",
            encoding: .utf8
        )
        let returnedPreflight = await model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationFolderURL
        )
        let preflight = try XCTUnwrap(returnedPreflight)
        guard case .ready = preflight.target else {
            return XCTFail("Absent target must be ready without confirmation.")
        }

        let saveTask = Task { @MainActor in
            await model.completePreflightedSaveAs(preflight)
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

    func testOpenDuplicateEditAndExplicitSaveNeverAutosaveOriginal() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let sourceRootURL = try makeModelRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Manual Open.txt",
            isDirectory: false
        )
        let originalBytes = Data("Original\n".utf8)
        try originalBytes.write(to: sourceURL, options: .withoutOverwriting)
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )

        let firstOpen = await model.openTestDocument(selectedURL: sourceURL)
        let duplicateOpen = await model.openTestDocument(selectedURL: sourceURL)

        XCTAssertTrue(firstOpen)
        XCTAssertTrue(duplicateOpen)
        XCTAssertEqual(model.state.tabs.count, 1)
        XCTAssertEqual(model.activeText, "Original\n")
        XCTAssertNotNil(model.state.activeTab.document.fileBinding)

        model.editActiveDocument(text: "PhonePad edit\n")
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        let loadedProtectedEnvelope = try await store.load(
            documentID: model.state.activeTab.document.id
        )
        let protectedEnvelope = try XCTUnwrap(loadedProtectedEnvelope)
        XCTAssertNotNil(protectedEnvelope.fileReference)
        XCTAssertNil(protectedEnvelope.pendingSave)

        let didSave = await model.saveActiveDocument()

        XCTAssertTrue(didSave)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("PhonePad edit\n".utf8))
        XCTAssertFalse(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(model.state.activeTab.document.recoveryState, .clean)
        XCTAssertNil(model.fileSaveError)
        let removedRecovery = try await store.load(
            documentID: model.state.activeTab.document.id
        )
        XCTAssertNil(removedRecovery)
    }

    func testBoundSaveConflictKeepsExternalBytesAndProtectedRecovery() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let sourceRootURL = try makeModelRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Conflict.txt",
            isDirectory: false
        )
        try Data("Original\n".utf8).write(
            to: sourceURL,
            options: .withoutOverwriting
        )
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
        let didOpen = await model.openTestDocument(selectedURL: sourceURL)
        XCTAssertTrue(didOpen)
        model.editActiveDocument(text: "Unsaved PhonePad text\n")
        let externalBytes = Data("External text\n".utf8)
        try externalBytes.write(to: sourceURL, options: .atomic)

        let didSave = await model.saveActiveDocument()

        XCTAssertFalse(didSave)
        XCTAssertEqual(try Data(contentsOf: sourceURL), externalBytes)
        XCTAssertEqual(model.activeText, "Unsaved PhonePad text\n")
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertEqual(model.activeFileConflict, .contentChanged)
        XCTAssertTrue(model.fileConflictResolutionIsPresented)
        XCTAssertNil(model.fileSaveError)
        let loadedRecovery = try await store.load(
            documentID: model.state.activeTab.document.id
        )
        let recovery = try XCTUnwrap(loadedRecovery)
        XCTAssertEqual(recovery.text, "Unsaved PhonePad text\n")
        XCTAssertNotNil(recovery.pendingSave)
    }

    func testUnrepresentableBoundSaveKeepsNewestScheduledRecovery() async throws {
        let recoveryRootURL = try makeModelRecoveryRoot()
        let sourceRootURL = try makeModelRecoveryRoot()
        let sourceURL = sourceRootURL.appendingPathComponent(
            "Windows-1252.txt",
            isDirectory: false
        )
        let originalBytes = Data([0x43, 0x61, 0x66, 0xe9, 0x0a])
        try originalBytes.write(to: sourceURL, options: .withoutOverwriting)
        let store = FileRecoveryStore(
            rootURL: recoveryRootURL,
            fileManager: .default
        )
        let model = PhonePadAppModel(
            state: makeInitialPhonePadState(
                documentID: DocumentID(rawValue: UUID()),
                tabID: TabID(rawValue: UUID())
            ),
            recoveryStore: store,
            fileAccessConnector: FileAccessConnector(fileManager: .default),
            checkpointQuietPeriod: .milliseconds(20),
            checkpointMaximumInterval: .milliseconds(100)
        )
        let didOpen = await model.openTestDocument(selectedURL: sourceURL)
        XCTAssertTrue(didOpen)
        model.editActiveDocument(text: "Café first edit\n")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )

        let newestText = "Emoji 😀\n"
        model.editActiveDocument(text: newestText)
        let didSave = await model.saveActiveDocument()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(didSave)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(model.activeText, newestText)
        XCTAssertTrue(model.state.activeTab.document.isUnsaved)
        XCTAssertNotNil(model.fileSaveError)
        let recovery = try await store.load(
            documentID: model.state.activeTab.document.id
        )
        XCTAssertEqual(recovery?.text, newestText)
        XCTAssertNil(recovery?.pendingSave)
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

private extension PhonePadAppModel {
    func openTestDocument(selectedURL: URL) async -> Bool {
        let document = state.activeTab.document
        return await openDocument(
            selectedURL: selectedURL,
            after: CommittedEditorDocument(
                documentID: document.id,
                text: document.text
            )
        )
    }

    func recoverTestRecovery(documentID: DocumentID) async -> Bool {
        let document = state.activeTab.document
        return await recoverRecovery(
            documentID: documentID,
            after: CommittedEditorDocument(
                documentID: document.id,
                text: document.text
            )
        )
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

private struct BlockingRecoveryLoadStore: RecoveryStoring {
    private let baseStore: FileRecoveryStore
    private let blockedDocumentID: DocumentID
    private let gate: BlockingRecoveryLoadGate

    init(baseStore: FileRecoveryStore, blockedDocumentID: DocumentID) {
        self.baseStore = baseStore
        self.blockedDocumentID = blockedDocumentID
        gate = BlockingRecoveryLoadGate()
    }

    func save(envelope: RecoveryEnvelope) async throws {
        try await baseStore.save(envelope: envelope)
    }

    func load(documentID: DocumentID) async throws -> RecoveryEnvelope? {
        if documentID == blockedDocumentID {
            await gate.block()
        }
        return try await baseStore.load(documentID: documentID)
    }

    func verifyCheckpoint(
        documentID: DocumentID
    ) async throws -> RecoveryCheckpointVerification {
        try await baseStore.verifyCheckpoint(documentID: documentID)
    }

    func recoveryItems() async throws -> [RecoveryItemSummary] {
        try await baseStore.recoveryItems()
    }

    func recoveryFileCollisionClaims(
        excludingDocumentID: DocumentID
    ) async throws -> [FileCollisionClaim] {
        try await baseStore.recoveryFileCollisionClaims(
            excludingDocumentID: excludingDocumentID
        )
    }

    func discardRecovery(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try await baseStore.discardRecovery(documentID: documentID)
    }

    func completeRecoveryAfterSave(
        documentID: DocumentID
    ) async throws -> RecoveryTerminalOutcome {
        try await baseStore.completeRecoveryAfterSave(documentID: documentID)
    }

    func waitUntilLoadEntered() async {
        await gate.waitUntilEntered()
    }

    func resumeLoad() async {
        await gate.resume()
    }
}

private actor BlockingRecoveryLoadGate {
    private var didEnter: Bool = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        didEnter = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            precondition(releaseContinuation == nil)
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if didEnter {
            return
        }
        await withCheckedContinuation { continuation in
            precondition(entryContinuation == nil)
            entryContinuation = continuation
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class CheckpointValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail: Bool = true
    private var recordedAttemptCount: Int = 0

    var attemptCount: Int {
        lock.withLock { recordedAttemptCount }
    }

    func validate(promotedURL _: URL) throws {
        let mustFail = lock.withLock {
            recordedAttemptCount += 1
            return shouldFail
        }
        guard mustFail else {
            return
        }
        throw CocoaError(.fileWriteUnknown)
    }

    func repair() {
        lock.withLock {
            shouldFail = false
        }
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
