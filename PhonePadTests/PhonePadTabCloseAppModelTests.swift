import Foundation
import PhonePadCore
import XCTest
@testable import PhonePad

@MainActor
final class PhonePadTabCloseAppModelTests: XCTestCase {
    func testCleanTabClosesImmediatelyAndPreservesRemainingTab() async throws {
        let fixture = try makeTwoCleanTabFixture()
        let closingTab = fixture.model.state.activeTab
        let remainingTab = fixture.model.state.tabs[1]

        let didRequestClose = await fixture.model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: closingTab.document.text
            )
        )

        XCTAssertTrue(
            didRequestClose,
            fixture.model.tabCloseError ?? "Clean close failed without an error."
        )
        XCTAssertEqual(fixture.model.state.tabs, [remainingTab])
        XCTAssertEqual(fixture.model.state.activeTabID, remainingTab.id)
        XCTAssertNil(fixture.model.pendingTabClosePrompt)
    }

    func testCancelUnsavedCloseLeavesStateAndRecoveryUnchanged() async throws {
        let fixture = try await makeProtectedUnsavedFixture()
        let stateBefore = fixture.model.state
        let document = stateBefore.activeTab.document
        let envelopeBefore = try await fixture.store.load(
            documentID: document.id
        )

        let didRequestClose = await fixture.model.requestCloseTab(
            stateBefore.activeTabID,
            after: CommittedEditorDocument(
                documentID: document.id,
                text: document.text
            )
        )
        fixture.model.cancelPendingTabClose()

        XCTAssertTrue(didRequestClose)
        XCTAssertEqual(fixture.model.state, stateBefore)
        XCTAssertNil(fixture.model.pendingTabClosePrompt)
        let envelopeAfter = try await fixture.store.load(
            documentID: document.id
        )
        XCTAssertEqual(envelopeAfter, envelopeBefore)
    }

    func testDiscardUnsavedFinalTabTerminatesRecoveryBeforeCreatingFreshTab() async throws {
        let fixture = try await makeProtectedUnsavedFixture()
        let closingTab = fixture.model.state.activeTab

        let didRequestClose = await fixture.model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: closingTab.document.text
            )
        )
        let didDiscard = await fixture.model.discardPendingTabClose()

        XCTAssertTrue(didRequestClose)
        XCTAssertTrue(
            didDiscard,
            fixture.model.tabCloseError ?? "Discard close failed without an error."
        )
        XCTAssertEqual(fixture.model.state.tabs.count, 1)
        XCTAssertNotEqual(
            fixture.model.state.activeTab.document.id,
            closingTab.document.id
        )
        XCTAssertNotEqual(fixture.model.state.activeTab.id, closingTab.id)
        XCTAssertEqual(fixture.model.state.activeTab.document.title, "Untitled")
        XCTAssertEqual(fixture.model.state.activeTab.document.text, "")
        XCTAssertFalse(fixture.model.state.activeTab.document.isUnsaved)
        XCTAssertEqual(
            fixture.model.state.activeTab.document.recoveryState,
            .clean
        )
        let discardedEnvelope = try await fixture.store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(discardedEnvelope)
    }

    func testDiscardCleanupFailureKeepsTabReadOnlyUntilExplicitRetry() async throws {
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
        let store = FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default
        )
        let fixture = try await makeProtectedUnsavedFixture(store: store)
        let closingState = fixture.model.state
        let closingTab = closingState.activeTab
        let transactionURL = rootURL.appendingPathComponent(
            ".\(closingTab.document.id.rawValue.uuidString.lowercased()).recovery.transaction",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: false,
            attributes: nil
        )

        let didRequestClose = await fixture.model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: closingTab.document.text
            )
        )
        let didDiscard = await fixture.model.discardPendingTabClose()

        XCTAssertTrue(didRequestClose)
        XCTAssertFalse(didDiscard)
        XCTAssertEqual(fixture.model.state, closingState)
        XCTAssertTrue(fixture.model.tabCloseCleanupRequired)
        XCTAssertFalse(fixture.model.editorInteractionDisabled)
        XCTAssertTrue(fixture.model.editorMutationDisabled)
        XCTAssertNotNil(fixture.model.tabCloseError)

        try FileManager.default.removeItem(at: transactionURL)
        let didRetry = await fixture.model.retryPendingTabCloseCleanup()

        XCTAssertTrue(
            didRetry,
            fixture.model.tabCloseError ?? "Cleanup retry failed without an error."
        )
        XCTAssertFalse(fixture.model.tabCloseCleanupRequired)
        XCTAssertNotEqual(
            fixture.model.state.activeTab.document.id,
            closingTab.document.id
        )
        let discardedEnvelope = try await fixture.store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(discardedEnvelope)
    }

    func testCloseOtherTabsStopsAtUnsavedTabAndCancelLeavesRemainder() async throws {
        let fixture = try await makeCloseOtherTabsFixture()
        let initialTabs = fixture.model.state.tabs
        let cleanTab = initialTabs[0]
        let unsavedTab = initialTabs[1]
        let retainedTab = initialTabs[2]
        let unsavedEnvelopeBefore = try await fixture.store.load(
            documentID: unsavedTab.document.id
        )

        let didRequestClose = await fixture.model.requestCloseOtherTabs(
            keeping: retainedTab.id,
            after: CommittedEditorDocument(
                documentID: retainedTab.document.id,
                text: retainedTab.document.text
            )
        )

        XCTAssertTrue(
            didRequestClose,
            fixture.model.tabCloseError
                ?? "Close Other Tabs failed without an error."
        )
        XCTAssertEqual(
            fixture.model.state.tabs.map(\.id),
            [unsavedTab.id, retainedTab.id]
        )
        XCTAssertEqual(
            fixture.model.pendingTabClosePrompt?.tabID,
            unsavedTab.id
        )
        XCTAssertFalse(
            fixture.model.state.tabs.contains(where: { $0.id == cleanTab.id })
        )

        fixture.model.cancelPendingTabClose()

        XCTAssertEqual(
            fixture.model.state.tabs.map(\.id),
            [unsavedTab.id, retainedTab.id]
        )
        XCTAssertEqual(fixture.model.state.activeTabID, retainedTab.id)
        XCTAssertNil(fixture.model.pendingTabClosePrompt)
        let unsavedEnvelopeAfter = try await fixture.store.load(
            documentID: unsavedTab.document.id
        )
        XCTAssertEqual(unsavedEnvelopeAfter, unsavedEnvelopeBefore)
    }

    func testCheckpointFailureStillAllowsDiscardAfterStoreRepair() async throws {
        let validation = TabCloseRecoveryValidationControl()
        validation.rejectPromotions()
        let store = try makeStore(validation: { promotedURL in
            try validation.validate(promotedURL: promotedURL)
        })
        let model = makeModel(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            store: store
        )
        let closingTab = model.state.activeTab

        XCTAssertTrue(
            model.editDocument(
                documentID: closingTab.document.id,
                text: "Newest in-memory content"
            )
        )
        let didRequestClose = await model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: "Newest in-memory content"
            )
        )

        XCTAssertTrue(didRequestClose)
        XCTAssertEqual(model.pendingTabClosePrompt?.tabID, closingTab.id)
        XCTAssertNotNil(model.recoveryError)
        XCTAssertTrue(model.editorMutationDisabled)

        validation.allowPromotions()
        let didDiscard = await model.discardPendingTabClose()

        XCTAssertTrue(
            didDiscard,
            model.tabCloseError ?? "Discard failed without an error."
        )
        XCTAssertNil(model.recoveryError)
        XCTAssertFalse(model.editorMutationDisabled)
        XCTAssertNotEqual(model.state.activeTab.id, closingTab.id)
        XCTAssertNotEqual(
            model.state.activeTab.document.id,
            closingTab.document.id
        )
    }

    func testFailedCheckpointThenFailedBoundSaveStillAllowsDiscard() async throws {
        let filesURL = try makeTemporaryDirectory()
        let fileURL = filesURL.appendingPathComponent(
            "BoundFailure.txt",
            isDirectory: false
        )
        try Data("Bound baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let validation = TabCloseRecoveryValidationControl()
        let store = try makeStore(validation: { promotedURL in
            try validation.validate(promotedURL: promotedURL)
        })
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = makeModel(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            store: store,
            connector: connector
        )
        let initialDocument = model.state.activeTab.document
        let didOpen = await model.openDocument(
            selectedURL: fileURL,
            after: CommittedEditorDocument(
                documentID: initialDocument.id,
                text: initialDocument.text
            )
        )
        XCTAssertTrue(
            didOpen,
            model.fileSaveError ?? "Open failed without an error."
        )
        let closingTab = model.state.activeTab
        validation.rejectPromotions()
        XCTAssertTrue(
            model.editDocument(
                documentID: closingTab.document.id,
                text: "Protected only after Save retry"
            )
        )
        let didRequestClose = await model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: "Protected only after Save retry"
            )
        )
        XCTAssertTrue(
            didRequestClose,
            model.tabCloseError ?? "Close failed without an error."
        )
        XCTAssertNotNil(model.recoveryError)

        validation.allowPromotions()
        await connector.stopPresenting(documentID: closingTab.document.id)
        let route = await model.savePendingTabClose()

        XCTAssertEqual(route, .failed)
        XCTAssertEqual(
            model.state.activeTab.document.recoveryState,
            .protectedUnsaved
        )
        XCTAssertNotNil(model.pendingTabClosePrompt)
        let didDiscard = await model.discardPendingTabClose()
        XCTAssertTrue(
            didDiscard,
            model.tabCloseError ?? "Discard failed without an error."
        )
        XCTAssertFalse(model.state.tabs.contains(where: {
            $0.id == closingTab.id
        }))
        let recoveryAfterDiscard = try await store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(recoveryAfterDiscard)
    }

    func testDetectedBoundConflictCancellationStillAllowsDiscard() async throws {
        let filesURL = try makeTemporaryDirectory()
        let fileURL = filesURL.appendingPathComponent(
            "BoundConflict.txt",
            isDirectory: false
        )
        try Data("Bound baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let store = try makeStore()
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = makeModel(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            store: store,
            connector: connector
        )
        let initialDocument = model.state.activeTab.document
        let didOpen = await model.openDocument(
            selectedURL: fileURL,
            after: CommittedEditorDocument(
                documentID: initialDocument.id,
                text: initialDocument.text
            )
        )
        XCTAssertTrue(
            didOpen,
            model.fileSaveError ?? "Open failed without an error."
        )
        let closingTab = model.state.activeTab
        XCTAssertTrue(
            model.editDocument(
                documentID: closingTab.document.id,
                text: "Protected local conflict winner"
            )
        )
        let didRequestClose = await model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: "Protected local conflict winner"
            )
        )
        XCTAssertTrue(
            didRequestClose,
            model.tabCloseError ?? "Close failed without an error."
        )
        try Data("External conflict winner\n".utf8).write(
            to: fileURL,
            options: .atomic
        )

        let route = await model.savePendingTabClose()

        XCTAssertEqual(route, .fileConflictRequired(closingTab.document.id))
        XCTAssertNotNil(model.state.activeTab.document.fileConflict)
        XCTAssertNil(model.pendingTabClosePrompt)
        model.cancelFileConflictResolution()
        XCTAssertNotNil(model.pendingTabClosePrompt)
        let didDiscard = await model.discardPendingTabClose()
        XCTAssertTrue(
            didDiscard,
            model.tabCloseError ?? "Discard failed without an error."
        )
        XCTAssertFalse(model.state.tabs.contains(where: {
            $0.id == closingTab.id
        }))
        let recoveryAfterDiscard = try await store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(recoveryAfterDiscard)
    }

    func testUnboundSaveRouteRestoresExactDecisionAfterCancellation() async throws {
        let fixture = try await makeProtectedUnsavedFixture()
        let stateBefore = fixture.model.state
        let closingTab = stateBefore.activeTab
        let recoveryBefore = try await fixture.store.load(
            documentID: closingTab.document.id
        )

        let didRequestClose = await fixture.model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: closingTab.document.text
            )
        )
        XCTAssertTrue(didRequestClose)
        let promptBefore = try XCTUnwrap(
            fixture.model.pendingTabClosePrompt
        )

        let route = await fixture.model.savePendingTabClose()

        XCTAssertEqual(route, .saveAsRequired(closingTab.document.id))
        XCTAssertEqual(fixture.model.pendingTabCloseDocumentID, closingTab.document.id)
        XCTAssertNil(fixture.model.pendingTabClosePrompt)
        XCTAssertEqual(fixture.model.state, stateBefore)
        let recoveryDuringSaveAs = try await fixture.store.load(
            documentID: closingTab.document.id
        )
        XCTAssertEqual(recoveryDuringSaveAs, recoveryBefore)

        XCTAssertTrue(
            fixture.model.restorePendingTabCloseDecisionAfterSaveAsCancellation(
                documentID: closingTab.document.id
            )
        )
        XCTAssertEqual(fixture.model.pendingTabClosePrompt, promptBefore)
        XCTAssertEqual(fixture.model.state, stateBefore)
        let recoveryAfterCancellation = try await fixture.store.load(
            documentID: closingTab.document.id
        )
        XCTAssertEqual(recoveryAfterCancellation, recoveryBefore)
    }

    func testBoundUnsavedSaveWritesExactBytesTerminatesRecoveryAndClosesTab() async throws {
        let filesURL = try makeTemporaryDirectory()
        let fileURL = filesURL.appendingPathComponent(
            "BoundClose.txt",
            isDirectory: false
        )
        try Data("Bound baseline\n".utf8).write(
            to: fileURL,
            options: .withoutOverwriting
        )
        let store = try makeStore()
        let connector = FileAccessConnector(fileManager: .default)
        addTeardownBlock {
            await connector.pausePresenters()
        }
        let model = makeModel(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            store: store,
            connector: connector
        )
        let initialDocument = model.state.activeTab.document
        let didOpen = await model.openDocument(
            selectedURL: fileURL,
            after: CommittedEditorDocument(
                documentID: initialDocument.id,
                text: initialDocument.text
            )
        )
        XCTAssertTrue(
            didOpen,
            model.fileSaveError ?? "Open failed without an error."
        )
        XCTAssertNotNil(model.state.activeTab.document.fileBinding)
        XCTAssertTrue(isPresenterRegistered(
            documentID: model.state.activeTab.document.id
        ))

        let savedText = "Exact bound Close Save bytes\nSecond line\n"
        let closingTab = model.state.activeTab
        XCTAssertTrue(
            model.editDocument(
                documentID: closingTab.document.id,
                text: savedText
            )
        )
        let didRequestClose = await model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: savedText
            )
        )
        XCTAssertTrue(
            didRequestClose,
            model.tabCloseError ?? "Close failed without an error."
        )

        let route = await model.savePendingTabClose()

        XCTAssertEqual(route, .completed)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data(savedText.utf8))
        let recoveryAfterSave = try await store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(recoveryAfterSave)
        XCTAssertFalse(model.state.tabs.contains(where: {
            $0.id == closingTab.id
        }))
        XCTAssertFalse(model.state.tabs.contains(where: {
            $0.document.id == closingTab.document.id
        }))
        XCTAssertNil(model.pendingTabClosePrompt)
        XCTAssertFalse(isPresenterRegistered(documentID: closingTab.document.id))
    }

    func testUnboundSaveAsWritesExactBytesTerminatesRecoveryAndClosesTab() async throws {
        let fixture = try await makeProtectedUnsavedFixture()
        let closingTab = fixture.model.state.activeTab
        let destinationURL = try makeTemporaryDirectory()
        let fileName = "UnboundClose.txt"
        let savedFileURL = destinationURL.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        let didRequestClose = await fixture.model.requestCloseTab(
            closingTab.id,
            after: CommittedEditorDocument(
                documentID: closingTab.document.id,
                text: closingTab.document.text
            )
        )
        XCTAssertTrue(didRequestClose)
        let route = await fixture.model.savePendingTabClose()
        XCTAssertEqual(route, .saveAsRequired(closingTab.document.id))

        let preparation = try fixture.model.prepareDocumentSaveAs(
            fileName: fileName,
            encoding: .utf8
        )
        let optionalPreflight = await fixture.model.preflightDocumentSaveAs(
            preparation: preparation,
            selectedDirectoryURL: destinationURL
        )
        let preflight = try XCTUnwrap(optionalPreflight)
        guard case .ready = preflight.target else {
            return XCTFail("New Save As destination must be ready.")
        }
        let didSave = await fixture.model.completePreflightedSaveAs(preflight)

        XCTAssertTrue(
            didSave,
            fixture.model.fileSaveError ?? "Save As failed without an error."
        )
        XCTAssertEqual(
            try Data(contentsOf: savedFileURL),
            Data(closingTab.document.text.utf8)
        )
        let recoveryAfterSaveAs = try await fixture.store.load(
            documentID: closingTab.document.id
        )
        XCTAssertNil(recoveryAfterSaveAs)
        XCTAssertFalse(fixture.model.state.tabs.contains(where: {
            $0.id == closingTab.id
        }))
        XCTAssertFalse(fixture.model.state.tabs.contains(where: {
            $0.document.id == closingTab.document.id
        }))
        XCTAssertNil(fixture.model.pendingTabClosePrompt)
        XCTAssertNil(fixture.model.pendingTabCloseDocumentID)
        XCTAssertFalse(isPresenterRegistered(documentID: closingTab.document.id))
    }

    private func makeTwoCleanTabFixture() throws -> TabCloseModelFixture {
        let store = try makeStore()
        let firstTabID = tabID(1)
        let secondTabID = tabID(2)
        let twoTabs = try createUntitledTab(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: firstTabID
            ),
            documentID: documentID(2),
            tabID: secondTabID
        )
        let state = try selectTab(state: twoTabs, tabID: firstTabID)
        return TabCloseModelFixture(
            model: makeModel(state: state, store: store),
            store: store
        )
    }

    private func makeProtectedUnsavedFixture() async throws -> TabCloseModelFixture {
        try await makeProtectedUnsavedFixture(validation: { _ in })
    }

    private func makeProtectedUnsavedFixture(
        validation: @escaping FileRecoveryStore.PostPromotionValidation
    ) async throws -> TabCloseModelFixture {
        let store = try makeStore(validation: validation)
        return try await makeProtectedUnsavedFixture(store: store)
    }

    private func makeProtectedUnsavedFixture(
        store: FileRecoveryStore
    ) async throws -> TabCloseModelFixture {
        let state = try await editActiveDocumentAndCheckpoint(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: tabID(1)
            ),
            newText: "Protected close content",
            editedAt: Date(timeIntervalSince1970: 1_787_100_000),
            recoveryStore: store
        )
        return TabCloseModelFixture(
            model: makeModel(state: state, store: store),
            store: store
        )
    }

    private func makeCloseOtherTabsFixture() async throws -> TabCloseModelFixture {
        let store = try makeStore()
        let firstTabID = tabID(1)
        let secondTabID = tabID(2)
        let thirdTabID = tabID(3)
        let twoTabs = try createUntitledTab(
            state: makeInitialPhonePadState(
                documentID: documentID(1),
                tabID: firstTabID
            ),
            documentID: documentID(2),
            tabID: secondTabID
        )
        let protectedSecond = try await editActiveDocumentAndCheckpoint(
            state: twoTabs,
            newText: "Unsaved second Tab",
            editedAt: Date(timeIntervalSince1970: 1_787_100_100),
            recoveryStore: store
        )
        let threeTabs = try createUntitledTab(
            state: protectedSecond,
            documentID: documentID(3),
            tabID: thirdTabID
        )
        return TabCloseModelFixture(
            model: makeModel(state: threeTabs, store: store),
            store: store
        )
    }

    private func makeStore() throws -> FileRecoveryStore {
        try makeStore(validation: { _ in })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    private func makeStore(
        validation: @escaping FileRecoveryStore.PostPromotionValidation
    ) throws -> FileRecoveryStore {
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
        return FileRecoveryStore(
            rootURL: rootURL,
            fileManager: .default,
            postPromotionValidation: validation
        )
    }

    private func makeModel(
        state: PhonePadState,
        store: FileRecoveryStore
    ) -> PhonePadAppModel {
        makeModel(
            state: state,
            store: store,
            connector: FileAccessConnector(fileManager: .default)
        )
    }

    private func makeModel(
        state: PhonePadState,
        store: FileRecoveryStore,
        connector: FileAccessConnector
    ) -> PhonePadAppModel {
        PhonePadAppModel(
            state: state,
            recoveryStore: store,
            fileAccessConnector: connector,
            checkpointQuietPeriod: .seconds(30),
            checkpointMaximumInterval: .seconds(30)
        )
    }

    private func isPresenterRegistered(documentID: DocumentID) -> Bool {
        NSFileCoordinator.filePresenters.contains(where: { presenter in
            guard let presentedFile = presenter as? PresentedFile else {
                return false
            }
            return presentedFile.documentID == documentID
        })
    }

    private func documentID(_ value: UInt8) -> DocumentID {
        DocumentID(rawValue: fixtureUUID(value))
    }

    private func tabID(_ value: UInt8) -> TabID {
        TabID(rawValue: fixtureUUID(value + 32))
    }

    private func fixtureUUID(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, value
        ))
    }
}

private struct TabCloseModelFixture {
    let model: PhonePadAppModel
    let store: FileRecoveryStore
}

private final class TabCloseRecoveryValidationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var rejectsPromotions: Bool = false

    func validate(promotedURL _: URL) throws {
        let shouldReject = lock.withLock { rejectsPromotions }
        if shouldReject {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func rejectPromotions() {
        lock.withLock { rejectsPromotions = true }
    }

    func allowPromotions() {
        lock.withLock { rejectsPromotions = false }
    }
}
